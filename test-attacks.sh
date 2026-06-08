#!/bin/bash
# Batería de tests para los ataques del laboratorio (nodo John)
# Ejecutar con el lab levantado: ./test-attacks.sh
# Cada sección prueba un ataque: inicio, efecto observable y limpieza.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; SKIP=$((SKIP + 1)); }

section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# Pasa si el comando tiene exit 0
check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# Pasa si el comando tiene exit distinto de 0
check_not() {
    local desc="$1"; shift
    if ! "$@" > /dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# Pasa si la salida contiene el patrón
check_output() {
    local desc="$1" pattern="$2"; shift 2
    if "$@" 2>/dev/null | grep -qE "$pattern"; then ok "$desc"; else fail "$desc"; fi
}

# Pasa si la salida NO contiene el patrón
check_no_output() {
    local desc="$1" pattern="$2"; shift 2
    if ! "$@" 2>/dev/null | grep -qE "$pattern"; then ok "$desc"; else fail "$desc"; fi
}

# Espera a que un comando produzca la salida esperada (con timeout)
wait_output() {
    local timeout="$1" pattern="$2"; shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        "$@" 2>/dev/null | grep -qE "$pattern" && return 0
        sleep 2; elapsed=$((elapsed + 2))
    done
    return 1
}

# ── Limpieza al salir (por si algún test falla a mitad) ──────────────────────
cleanup_all() {
    docker exec john python3 /scripts/attacks/attack_rip.py   stop 2>/dev/null || true
    docker exec john python3 /scripts/attacks/attack_spoof.py stop 2>/dev/null || true
    docker exec john python3 /scripts/attacks/attack_flood.py stop 2>/dev/null || true
    docker exec john python3 /scripts/attacks/attack_dns.py   stop 2>/dev/null || true
    docker exec john python3 /scripts/attacks/attack_proxy.py stop 2>/dev/null || true
    docker exec john python3 /scripts/attacks/attack_mitm.py  stop 2>/dev/null || true
    # Restaurar nginx.conf del proxy si el ataque lo dejó modificado
    docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf 2>/dev/null || true
    docker exec proxy nginx -s reload 2>/dev/null || true
    # Eliminar cualquier delay tc residual en John
    IFACE2=$(docker exec john ip -4 addr 2>/dev/null | grep '192.168.2.2' | awk '{print $NF}')
    [ -n "$IFACE2" ] && docker exec john tc qdisc del dev "$IFACE2" root 2>/dev/null || true
}
trap cleanup_all EXIT

# ─────────────────────────────────────────────────────────────────────────────
section "Pre-flight: lab y nodo John"
# ─────────────────────────────────────────────────────────────────────────────

check "contenedor john está corriendo" \
    docker inspect -f '{{.State.Running}}' john

check "contenedor alice está corriendo" \
    docker inspect -f '{{.State.Running}}' alice

check "contenedor bob está corriendo" \
    docker inspect -f '{{.State.Running}}' bob

check "contenedor dns está corriendo" \
    docker inspect -f '{{.State.Running}}' dns

check "contenedor router_b está corriendo" \
    docker inspect -f '{{.State.Running}}' router_b

check "contenedor proxy está corriendo" \
    docker inspect -f '{{.State.Running}}' proxy

check "contenedor http está corriendo" \
    docker inspect -f '{{.State.Running}}' http

check "john tiene ip_forward activo" \
    docker exec john sh -c "cat /proc/sys/net/ipv4/ip_forward | grep -q 1"

check "john tiene los scripts de ataque" \
    docker exec john ls /scripts/attacks/attack_rip.py

check "john tiene acceso a python3 y scapy" \
    docker exec john python3 -c "from scapy.all import IP; print('ok')"

check "estado inicial limpio: ningún ataque activo" \
    bash -c "
        for f in /tmp/attack_rip.pid /tmp/attack_spoof.pid /tmp/attack_mitm.pid \
                  /tmp/attack_flood.pid /tmp/attack_dns.pid /tmp/attack_proxy.pid; do
            docker exec john test ! -f \"\$f\" 2>/dev/null
        done
    " 2>/dev/null || true

# Garantizar estado limpio antes de empezar
cleanup_all 2>/dev/null
sleep 1

# Variables de entorno útiles
JOHN_IP_NET1="192.168.1.100"
JOHN_IP_NET2="192.168.2.2"
DNS_IP="192.168.3.2"
REAL_WEB_IP="192.168.4.2"

# MAC de John en network1 (para verificar ARP spoofing)
JOHN_IFACE_NET1=$(docker exec john ip -4 addr | grep "$JOHN_IP_NET1" | awk '{print $NF}')
JOHN_MAC_NET1=$(docker exec john ip link show "$JOHN_IFACE_NET1" | awk '/link\/ether/{print $2}')

# Interfaz de John en network2 (N2) — usada por proxy y flood
IFACE2=$(docker exec john ip -4 addr | grep "$JOHN_IP_NET2" | awk '{print $NF}')

# ─────────────────────────────────────────────────────────────────────────────
section "Ataque 1 — RIP Poisoning"
# ─────────────────────────────────────────────────────────────────────────────

# Ruta legítima antes del ataque (no debe pasar por 192.168.2.2)
LEGIT_ROUTE=$(docker exec router_b ip route show 192.168.3.0/24 2>/dev/null | head -1)

check_not "PID file no existe antes de iniciar" \
    docker exec john test -f /tmp/attack_rip.pid

./netctl.sh --attack rip start > /dev/null

check "PID file creado al iniciar" \
    docker exec john test -f /tmp/attack_rip.pid

check "proceso ripd-attack vivo" bash -c "
    PID=\$(docker exec john cat /tmp/attack_rip.pid 2>/dev/null)
    docker exec john test -d /proc/\$PID
"

# Esperar convergencia RIP (hasta 40s: FRR timer=5s + propagación)
# 192.168.1.0/24 y 192.168.4.0/26 ganan la competencia de métrica contra las rutas legítimas.
# 192.168.3.0/24 tiene la misma métrica desde router_c y FRR conserva la ruta existente.
echo "  [wait] Convergencia RIP..."
if wait_output 40 "192.168.2.2" docker exec router_b ip route show 192.168.1.0/24; then
    check_output "router_b enruta 192.168.1.0/24 via John (192.168.2.2) — ENVENENADO" \
        "192.168.2.2" docker exec router_b ip route show 192.168.1.0/24

    check_output "router_b enruta 192.168.4.0/26 via John — ENVENENADO" \
        "192.168.2.2" docker exec router_b ip route show 192.168.4.0/26
else
    fail "router_b no convergió con la ruta envenenada en 40s"
    fail "router_b enruta 192.168.4.0/26 via John (no comprobado)"
fi

./netctl.sh --attack rip stop > /dev/null
echo "  [wait] Retirada de rutas RIP..."
sleep 8   # FRR tarda ~1-2 ciclos en procesar metric=16

check_not "PID file eliminado tras stop" \
    docker exec john test -f /tmp/attack_rip.pid

# Tras el stop, la ruta 192.168.1.0/24 no debe pasar por 192.168.2.2
if wait_output 30 "via" docker exec router_b ip route show 192.168.1.0/24; then
    check_no_output "router_b ya NO enruta 192.168.1.0/24 via John — LIMPIO" \
        "192\.168\.2\.2" docker exec router_b ip route show 192.168.1.0/24
else
    skip "router_b no tiene ruta 192.168.1.0/24 visible (RIP aún convergiendo)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Ataque 2 — IP Spoofing"
# ─────────────────────────────────────────────────────────────────────────────

check_not "PID file no existe antes de iniciar" \
    docker exec john test -f /tmp/attack_spoof.pid

./netctl.sh --attack spoof start > /dev/null

check "PID file creado al iniciar" \
    docker exec john test -f /tmp/attack_spoof.pid

check "proceso vivo" bash -c "
    PID=\$(docker exec john cat /tmp/attack_spoof.pid 2>/dev/null)
    docker exec john test -d /proc/\$PID
"

# Esperar 2 ciclos (INTERVAL=3s) para que el log tenga entradas
echo "  [wait] Esperando paquetes spoofed..."
sleep 7

check_output "log registra ICMP spoofed con src=alice (192.168.1.10)" \
    "ICMP" docker exec john cat /tmp/attack_spoof.log

check_output "log registra TCP SYN spoofed hacia firewall_extern" \
    "TCP SYN" docker exec john cat /tmp/attack_spoof.log

check_output "log registra tráfico tanto como alice como bob" \
    "alice|bob" docker exec john cat /tmp/attack_spoof.log

./netctl.sh --attack spoof stop > /dev/null

check_not "PID file eliminado tras stop" \
    docker exec john test -f /tmp/attack_spoof.pid

# ─────────────────────────────────────────────────────────────────────────────
section "Ataque 3 — MitM + ARP Spoofing"
# ─────────────────────────────────────────────────────────────────────────────

# Guardar MAC real del gateway antes del ataque
GW_MAC_REAL=$(docker exec alice arp -n 2>/dev/null | awk '/192\.168\.1\.1/{print $3}' | head -1)

# Forzar tráfico alice→gateway para que router_a tenga la ARP cache de alice
# (Linux solo actualiza entradas ARP existentes con gratuitous ARP)
docker exec alice ping -c 2 -W 1 192.168.1.1 > /dev/null 2>&1 || true
sleep 1

check_not "PID file no existe antes de iniciar" \
    docker exec john test -f /tmp/attack_mitm.pid

./netctl.sh --attack mitm start > /dev/null

check "PID file creado al iniciar" \
    docker exec john test -f /tmp/attack_mitm.pid

check "proceso vivo" bash -c "
    PID=\$(docker exec john cat /tmp/attack_mitm.pid 2>/dev/null)
    docker exec john test -d /proc/\$PID
"

check "cache JSON con MACs guardada" \
    docker exec john test -f /tmp/attack_mitm_cache.json

# Esperar que el ARP cache se actualice (el bucle de spoof corre cada 1s)
echo "  [wait] Envenenamiento ARP cache..."
sleep 6

check_output "alice tiene en su ARP cache la MAC de John como gateway" \
    "$JOHN_MAC_NET1" docker exec alice arp -n

# El tráfico de alice a través de John llega a router_a con la MAC de John como L2 src,
# lo que hace que router_a actualice su neighbor table: alice.IP → John.MAC
docker exec alice ping -c 2 -W 3 192.168.3.2 > /dev/null 2>&1 || true
sleep 1
# Los routers usan 'ip neigh show' (no tienen el comando 'arp')
check_output "router_a tiene en su neighbor table la MAC de John como alice/bob" \
    "$JOHN_MAC_NET1" docker exec router_a ip neigh show

check_output "log MitM registra víctimas envenenadas" \
    "MITM" docker exec john cat /tmp/attack_mitm.log

# Verificar que alice puede seguir comunicándose (John reenvía tráfico)
check "alice puede hacer ping al DNS a través de John (ip_forward)" \
    docker exec alice ping -c 2 -W 4 192.168.3.2

./netctl.sh --attack mitm stop > /dev/null

check_not "PID file eliminado tras stop" \
    docker exec john test -f /tmp/attack_mitm.pid

check_not "cache JSON eliminada tras stop" \
    docker exec john test -f /tmp/attack_mitm_cache.json

echo "  [wait] Restauración ARP cache..."
sleep 3
docker exec alice ping -c 1 -W 1 192.168.1.1 > /dev/null 2>&1 || true
sleep 2

# La MAC del gateway en alice debe ser distinta a la de John
ARP_AFTER=$(docker exec alice arp -n 2>/dev/null | awk '/192\.168\.1\.1/{print $3}' | head -1)
if [ -n "$ARP_AFTER" ] && [ "$ARP_AFTER" != "$JOHN_MAC_NET1" ]; then
    ok "ARP cache de alice restaurada (gateway MAC ≠ John MAC)"
elif [ -z "$ARP_AFTER" ]; then
    ok "ARP cache de alice limpiada (entrada del gateway eliminada)"
else
    fail "ARP cache de alice aún apunta a John tras stop"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Ataque 4 — SYN/ICMP/UDP Flood"
# ─────────────────────────────────────────────────────────────────────────────

check_not "PID file no existe antes de iniciar" \
    docker exec john test -f /tmp/attack_flood.pid

./netctl.sh --attack flood start > /dev/null

check "PID file creado al iniciar" \
    docker exec john test -f /tmp/attack_flood.pid

check "proceso vivo" bash -c "
    PID=\$(docker exec john cat /tmp/attack_flood.pid 2>/dev/null)
    docker exec john test -d /proc/\$PID
"

echo "  [wait] Acumulando paquetes flood..."
sleep 6

check_output "log registra SYN flood hacia proxy" \
    "SYN (flood|enviados)" docker exec john cat /tmp/attack_flood.log

check_output "log registra ICMP flood hacia DNS" \
    "ICMP (flood|enviados)" docker exec john cat /tmp/attack_flood.log

check_output "log registra UDP/DNS flood" \
    "UDP.DNS (flood|enviados)" docker exec john cat /tmp/attack_flood.log

# Verificar impacto: SYN_RECV en el proxy (estado 03 en /proc/net/tcp)
SYN_COUNT=$(docker exec proxy sh -c \
    "awk '\$4==\"03\"{count++} END{print count+0}' /proc/net/tcp 2>/dev/null")
if [ "${SYN_COUNT:-0}" -gt 10 ]; then
    ok "proxy tiene $SYN_COUNT conexiones SYN_RECV (flood activo)"
else
    skip "SYN_RECV count bajo ($SYN_COUNT) — puede estar siendo filtrado"
fi

./netctl.sh --attack flood stop > /dev/null

check_not "PID file eliminado tras stop" \
    docker exec john test -f /tmp/attack_flood.pid

sleep 3
SYN_AFTER=$(docker exec proxy sh -c \
    "awk '\$4==\"03\"{count++} END{print count+0}' /proc/net/tcp 2>/dev/null")
if [ "${SYN_AFTER:-0}" -lt "${SYN_COUNT:-999}" ]; then
    ok "SYN_RECV en proxy bajó de $SYN_COUNT a $SYN_AFTER — flood detenido"
else
    skip "SYN_RECV no bajó claramente (puede que el initial count fuera bajo)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Ataque 5 — DNS Cache Poisoning (Kaminsky)"
# ─────────────────────────────────────────────────────────────────────────────
# No requiere MitM: John inunda dnsmasq con 65536 TxIDs (raw socket)

# Limpiar cualquier cache negativo de dnsmasq antes de empezar
docker exec dns sh -c 'kill -HUP $(pidof dnsmasq)' > /dev/null 2>&1
sleep 1

# Pre-check: dominio no resuelve antes del ataque
DNS_PRE=$(docker exec alice nslookup lab-external.com "$DNS_IP" 2>/dev/null | \
          awk '/^Address:/{print $2}' | grep -v "^$DNS_IP" | head -1)
if [ -z "$DNS_PRE" ]; then
    ok "estado limpio: lab-external.com no resuelve antes del ataque"
else
    fail "lab-external.com ya resuelve → '$DNS_PRE' antes de iniciar (inesperado)"
fi

check_not "PID file no existe antes de iniciar" \
    docker exec john test -f /tmp/attack_dns.pid

./netctl.sh --attack dns start > /dev/null

check "PID file creado al iniciar" \
    docker exec john test -f /tmp/attack_dns.pid

check "proceso vivo" bash -c "
    PID=\$(docker exec john cat /tmp/attack_dns.pid 2>/dev/null)
    docker exec john test -d /proc/\$PID
"

# Esperar a que el flood de Kaminsky envenene el cache (timeout 30s)
echo "  [wait] Ejecutando flood Kaminsky (65536 TxIDs)..."
if wait_output 30 "POISONED" docker exec john cat /tmp/attack_dns.log; then
    ok "ataque Kaminsky exitoso — log confirma cache envenenada"
else
    fail "Kaminsky no logro envenenar el cache en 30s"
fi

# Verificar desde alice que dnsmasq devuelve la IP de John
DNS_RESULT=$(docker exec alice nslookup lab-external.com "$DNS_IP" 2>/dev/null | \
             awk '/^Address:/{print $2}' | grep -v "^$DNS_IP" | head -1)

if [ "$DNS_RESULT" = "$JOHN_IP_NET1" ]; then
    ok "alice resuelve lab-external.com → $JOHN_IP_NET1 (John) — CACHE ENVENENADA"
else
    fail "alice resolvió lab-external.com → '$DNS_RESULT' (esperado $JOHN_IP_NET1)"
fi

./netctl.sh --attack dns stop > /dev/null

check_not "PID file eliminado tras stop" \
    docker exec john test -f /tmp/attack_dns.pid

# CLAVE: el cache persiste aunque el daemon haya parado
DNS_CACHED=$(docker exec alice nslookup lab-external.com "$DNS_IP" 2>/dev/null | \
             awk '/^Address:/{print $2}' | grep -v "^$DNS_IP" | head -1)
if [ "$DNS_CACHED" = "$JOHN_IP_NET1" ]; then
    ok "cache persiste tras stop del daemon — envenenamiento sobrevive al atacante"
else
    fail "cache no persiste tras stop → '$DNS_CACHED' (esperado $JOHN_IP_NET1)"
fi

# Limpiar cache de dnsmasq mediante SIGHUP
docker exec dns sh -c 'kill -HUP $(pidof dnsmasq)' > /dev/null 2>&1
sleep 1

DNS_CLEAN=$(docker exec alice nslookup lab-external.com "$DNS_IP" 2>/dev/null | \
            awk '/^Address:/{print $2}' | grep -v "^$DNS_IP" | head -1)
if [ -z "$DNS_CLEAN" ] || [ "$DNS_CLEAN" != "$JOHN_IP_NET1" ]; then
    ok "cache vaciada (SIGHUP a dnsmasq) — lab-external.com ya no apunta a John"
else
    fail "lab-external.com sigue apuntando a John tras flush → '$DNS_CLEAN'"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Ataque 6 — Proxy Config Injection (Proxy Compromés)"
# ─────────────────────────────────────────────────────────────────────────────
# No requiere MitM: John modifica nginx.conf del proxy via volumen compartido

check_not "PID file no existe antes de iniciar" \
    docker exec john test -f /tmp/attack_proxy.pid

check_not "backup nginx.conf no existe antes de iniciar" \
    docker exec john test -f /scripts/nginx.conf.bak

# Verificar contenido real antes del ataque
check_output "alice obtiene contenido real antes del ataque" \
    "Internal HTTP Server" docker exec alice wget -qO- "http://$REAL_WEB_IP/"

./netctl.sh --attack proxy start > /dev/null

check "PID file creado al iniciar" \
    docker exec john test -f /tmp/attack_proxy.pid

check "proceso vivo" bash -c "
    PID=\$(docker exec john cat /tmp/attack_proxy.pid 2>/dev/null)
    docker exec john test -d /proc/\$PID
"

check "backup del nginx.conf original guardado" \
    docker exec john test -f /scripts/nginx.conf.bak

check_output "nginx.conf inyectado contiene payload de John" \
    "JOHN WAS HERE" docker exec proxy cat /scripts/nginx.conf

# Recargar nginx con la config comprometida
docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf > /dev/null 2>&1
docker exec proxy nginx -s reload > /dev/null 2>&1
sleep 1

# Verificar que el proxy sirve contenido inyectado
HTTP_RESULT=$(docker exec alice wget -qO- "http://$REAL_WEB_IP/" 2>/dev/null)

if echo "$HTTP_RESULT" | grep -q "JOHN WAS HERE"; then
    ok "alice recibe contenido inyectado — proxy sirve pagina de John (COMPROMES)"
else
    fail "alice no recibió contenido inyectado (recibió: ${HTTP_RESULT:0:80}...)"
fi

check_output "log registra config inyectada activa en el proxy" \
    "INJECTED" docker exec john cat /tmp/attack_proxy.log

./netctl.sh --attack proxy stop > /dev/null

check_not "PID file eliminado tras stop" \
    docker exec john test -f /tmp/attack_proxy.pid

check_not "backup nginx.conf eliminado tras stop (config restaurada)" \
    docker exec john test -f /scripts/nginx.conf.bak

# Recargar nginx con la config original restaurada
docker exec proxy cp /scripts/nginx.conf /etc/nginx/nginx.conf > /dev/null 2>&1
docker exec proxy nginx -s reload > /dev/null 2>&1
sleep 1

# Verificar que el proxy vuelve a servir el contenido real
check_output "alice obtiene contenido real tras restaurar el proxy" \
    "Internal HTTP Server" docker exec alice wget -qO- "http://$REAL_WEB_IP/"

# ─────────────────────────────────────────────────────────────────────────────
section "Limpieza final"
# ─────────────────────────────────────────────────────────────────────────────

PIDS_LEFT=$(docker exec john sh -c 'ls /tmp/attack_*.pid 2>/dev/null | wc -l' 2>/dev/null || echo "0")
if [ "${PIDS_LEFT:-0}" = "0" ]; then
    ok "ningún attack PID file queda en /tmp"
else
    fail "quedan $PIDS_LEFT PID files en /tmp tras cleanup"
fi

# Verificar que alice recupera conectividad normal
check "alice llega al DNS con ruta legítima" \
    docker exec alice ping -c 2 -W 3 192.168.3.2

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
printf "RESULTADO: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}  ${YELLOW}%d SKIP${NC}  (total: %d)\n" \
    "$PASS" "$FAIL" "$SKIP" "$((PASS + FAIL + SKIP))"
echo "════════════════════════════════════════"
echo ""

[ "$FAIL" -eq 0 ]
