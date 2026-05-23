#!/bin/bash
# Batería de tests para el laboratorio de redes Docker

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASS=0
FAIL=0

ok()   { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }

check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# Versión negada: pasa si el comando falla (para tests de seguridad)
check_not() {
    local desc="$1"; shift
    if ! "$@" > /dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# Pasa si la salida del comando contiene el patrón esperado
check_output() {
    local desc="$1"; local pattern="$2"; shift 2
    if "$@" 2>/dev/null | grep -q "$pattern"; then ok "$desc"; else fail "$desc"; fi
}

# ── Contenedores ──────────────────────────────────────────────────────────────
echo ""
echo "=== Estado de los contenedores ==="
for c in alice bob john dns vpn router_a router_b router_c router_d router_e \
          firewall_extern firewall_intern proxy http mysql syslog; do
    check "$c está corriendo" docker inspect -f '{{.State.Running}}' "$c"
done

# ── DHCP ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== DHCP ==="
check_output "alice obtuvo IP del servidor DHCP" "192.168.1." \
    docker exec alice ip -4 addr show eth0

check_output "bob obtuvo IP del servidor DHCP" "192.168.1." \
    docker exec bob ip -4 addr show eth0

# ── Enrutamiento RIP ──────────────────────────────────────────────────────────
echo ""
echo "=== Enrutamiento dinámico (RIP) ==="
check "ripd corre en router_a" docker exec router_a pgrep -x ripd
check "ripd corre en router_b" docker exec router_b pgrep -x ripd

check_output "router_a conoce la red de john (192.168.2.0/24) por RIP" "rip" \
    docker exec router_a ip route show 192.168.2.0/24

check_output "router_b conoce la red de alice (192.168.1.0/24) por RIP" "rip" \
    docker exec router_b ip route show 192.168.1.0/24

check "Ping alice → john (atraviesa el backbone)" \
    docker exec alice ping -c 2 -W 3 192.168.2.2

# ── Enrutamiento OSPF (prueba puntual, se restaura RIP al terminar) ───────────
echo ""
echo "=== Enrutamiento dinámico (OSPF) ==="

# Cambiar router_d y router_e a OSPF
docker exec router_d bash -c "pkill -x ripd 2>/dev/null; pkill -x zebra 2>/dev/null; sleep 2; /usr/local/bin/net-config/dynamic-routing.sh 1 ospf" >/dev/null 2>&1
docker exec router_e bash -c "pkill -x ripd 2>/dev/null; pkill -x zebra 2>/dev/null; sleep 2; /usr/local/bin/net-config/dynamic-routing.sh 1 ospf" >/dev/null 2>&1

# Esperar convergencia OSPF (máx 60 s)
for i in $(seq 1 30); do
    docker exec router_d ip route show proto ospf 2>/dev/null | grep -q '.' && \
    docker exec router_e ip route show proto ospf 2>/dev/null | grep -q '.' && break
    sleep 2
done

check "ospfd corre en router_d" docker exec router_d pgrep -x ospfd
check "ospfd corre en router_e" docker exec router_e pgrep -x ospfd

check_output "router_d aprendió 192.168.5.0/27 por OSPF" "ospf" \
    docker exec router_d ip route show 192.168.5.0/27

check_output "router_e aprendió 192.168.4.0/26 por OSPF" "ospf" \
    docker exec router_e ip route show 192.168.4.0/26

# Restaurar RIP en router_d y router_e
docker exec router_d bash -c "pkill -x ospfd 2>/dev/null; pkill -x zebra 2>/dev/null; sleep 2; /usr/local/bin/net-config/dynamic-routing.sh" >/dev/null 2>&1
docker exec router_e bash -c "pkill -x ospfd 2>/dev/null; pkill -x zebra 2>/dev/null; sleep 2; /usr/local/bin/net-config/dynamic-routing.sh" >/dev/null 2>&1

# Esperar reconvergencia RIP completa: router_d debe haber reaprendido
# 192.168.1.0/24 (red de alice) via RIP, que requiere propagación completa
for i in $(seq 1 40); do
    docker exec router_d ip route show 192.168.1.0/24 2>/dev/null | grep -q 'rip' && break
    sleep 2
done

check_output "router_d restaurado a RIP tras la prueba OSPF" "rip" \
    docker exec router_d ip route show 192.168.1.0/24

# Espera a que RIP reconverja en toda la red tras la prueba OSPF
sleep 20

# ── DNS ───────────────────────────────────────────────────────────────────────
echo ""
echo "=== DNS ==="
check "dnsmasq está corriendo" docker exec dns pgrep dnsmasq

check_output "WebDelLaboratorio.com resuelve a 192.168.4.2" "192.168.4.2" \
    docker exec alice python3 -c "import socket; print(socket.gethostbyname('WebDelLaboratorio.com'))"

check_output "alice accede a la web por nombre de dominio" "Internal HTTP Server" \
    docker exec alice wget -q -O - http://WebDelLaboratorio.com/

check_output "john accede a la web por nombre de dominio" "Internal HTTP Server" \
    docker exec john wget -q -O - http://WebDelLaboratorio.com/

check_output "bob accede a la web por nombre de dominio" "Internal HTTP Server" \
    docker exec bob wget -q -O - http://WebDelLaboratorio.com/

check_output "vpn.WebDelLaboratorio.com resuelve a 192.168.3.3 (desde alice)" "192.168.3.3" \
    docker exec alice python3 -c "import socket; print(socket.gethostbyname('vpn.WebDelLaboratorio.com'))"

check_output "vpn.WebDelLaboratorio.com resuelve a 192.168.3.3 (desde bob)" "192.168.3.3" \
    docker exec bob python3 -c "import socket; print(socket.gethostbyname('vpn.WebDelLaboratorio.com'))"

# ── NAT ───────────────────────────────────────────────────────────────────────
echo ""
echo "=== NAT ==="
check "alice puede alcanzar el firewall externo (192.168.4.2)" \
    docker exec alice ping -c 2 -W 3 192.168.4.2

check_output "el tráfico de alice sale con IP de router_a (NAT funcionando)" "192.168.5." \
    docker exec alice traceroute -n -m 4 192.168.4.2

# ── Flujo HTTP ────────────────────────────────────────────────────────────────
echo ""
echo "=== Flujo HTTP completo (cliente -> FW_ext -> proxy -> FW_int -> http) ==="
check_output "alice accede a la web a través del firewall" "Internal HTTP Server" \
    docker exec alice wget -q -O - http://192.168.4.2/

check_output "bob accede a la web a través del firewall" "Internal HTTP Server" \
    docker exec bob wget -q -O - http://192.168.4.2/

check_output "john accede a la web a través del firewall" "Internal HTTP Server" \
    docker exec john wget -q -O - http://192.168.4.2/

# ── Seguridad ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Seguridad: la red interna no es accesible desde fuera ==="
check_not "alice NO puede hacer ping al proxy (192.168.4.66)" \
    docker exec alice ping -c 1 -W 2 192.168.4.66

check_not "alice NO puede hacer ping al servidor HTTP (192.168.4.130)" \
    docker exec alice ping -c 1 -W 2 192.168.4.130

check_not "alice NO puede hacer ping a MySQL (192.168.4.131)" \
    docker exec alice ping -c 1 -W 2 192.168.4.131

check_not "john NO puede acceder al HTTP interno directamente" \
    docker exec john wget -q -O - --timeout=2 http://192.168.4.130/

# ── Servicios ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Servicios internos ==="
check "Apache httpd está corriendo"  docker exec http  pgrep httpd
check "nginx está corriendo"         docker exec proxy pgrep nginx
check "MariaDB está corriendo"       docker exec mysql pgrep mariadbd
check "syslog-ng está corriendo"     docker exec syslog pgrep syslog-ng

check_output "MariaDB escucha en TCP 3306" "3306" \
    docker exec mysql netstat -tlnp

check_output "syslog-ng escucha en UDP 514 (IPv4)" "0.0.0.0:514" \
    docker exec syslog netstat -ulnp

check_output "syslog-ng escucha en UDP 514 (IPv6)" ":::514" \
    docker exec syslog netstat -ulnp

# ── MySQL ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== MySQL ==="
check_output "la base de datos 'webapp' existe" "webapp" \
    docker exec mysql mariadb -u root -e "SHOW DATABASES;"

check_output "la tabla 'visits' existe" "visits" \
    docker exec mysql mariadb -u root -e "USE webapp; SHOW TABLES;"

check "el proxy puede conectarse a MySQL (puerto 3306)" \
    docker exec proxy python3 -c "
import socket
s = socket.socket(); s.settimeout(5)
s.connect(('192.168.4.131', 3306)); s.recv(10); s.close()
"

# ── Syslog ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Syslog ==="
check "el servidor http puede enviar logs a syslog por IPv4" \
    docker exec http python3 -c "
import socket, time
msg = b'<14>' + time.strftime('%b %e %H:%M:%S').encode() + b' http test-ipv4'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(msg, ('192.168.4.132', 514)); s.close()
"

check "el servidor http puede enviar logs a syslog por IPv6" \
    docker exec http python3 -c "
import socket, time
msg = b'<14>' + time.strftime('%b %e %H:%M:%S').encode() + b' http test-ipv6'
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.sendto(msg, ('fd00:4::132', 514, 0, 0)); s.close()
"

# ── IPv6 ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== IPv6 en la red interna (fd00:4::/64) ==="
check_output "http tiene dirección fd00:4::130"   "fd00:4::130" docker exec http  ip -6 addr show eth0
check_output "mysql tiene dirección fd00:4::131"  "fd00:4::131" docker exec mysql ip -6 addr show eth0
check_output "syslog tiene dirección fd00:4::132" "fd00:4::132" docker exec syslog ip -6 addr show eth0

check "ping6 entre servicios internos (http -> mysql)" \
    docker exec http ping6 -c 2 -W 3 fd00:4::131

check_output "HTTP accesible por IPv6" "Internal HTTP Server" \
    docker exec mysql python3 -c "
import urllib.request
print(urllib.request.urlopen('http://[fd00:4::130]/').read().decode())
"

check "MySQL accesible por IPv6" \
    docker exec http python3 -c "
import socket
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(5)
s.connect(('fd00:4::131', 3306, 0, 0)); s.recv(10); s.close()
"

# ── VPN WireGuard ─────────────────────────────────────────────────────────────
echo ""
echo "=== VPN WireGuard ==="

# — Interfaces y direcciones —
check "interfaz wg0 existe y está UP en el servidor VPN" \
    docker exec vpn ip link show wg0

check_output "servidor VPN tiene IP 10.8.0.1 en wg0" "10.8.0.1" \
    docker exec vpn ip addr show wg0

check_output "alice tiene IP 10.8.0.2 en wg0" "10.8.0.2" \
    docker exec alice ip addr show wg0

check_output "bob tiene IP 10.8.0.3 en wg0" "10.8.0.3" \
    docker exec bob ip addr show wg0

# — Configuración de peers —
check_output "servidor VPN tiene exactamente 2 peers configurados" "2" \
    docker exec vpn sh -c "wg show wg0 peers | wc -l"

check_output "alice tiene exactamente 1 peer (el servidor) configurado" "1" \
    docker exec alice sh -c "wg show wg0 peers | wc -l"

check_output "bob tiene exactamente 1 peer (el servidor) configurado" "1" \
    docker exec bob sh -c "wg show wg0 peers | wc -l"

# — Rutas —
check_output "ruta 10.8.0.0/24 de alice usa interfaz wg0" "wg0" \
    docker exec alice ip route get 10.8.0.3

check_output "ruta 10.8.0.0/24 de bob usa interfaz wg0" "wg0" \
    docker exec bob ip route get 10.8.0.2

# — Conectividad a través del túnel —
check "alice hace ping al servidor VPN por el túnel (10.8.0.1)" \
    docker exec alice ping -c 2 -W 3 10.8.0.1

check "bob hace ping al servidor VPN por el túnel (10.8.0.1)" \
    docker exec bob ping -c 2 -W 3 10.8.0.1

check "alice hace ping a bob a través del túnel VPN cifrado (10.8.0.3)" \
    docker exec alice ping -c 2 -W 3 10.8.0.3

check "bob hace ping a alice a través del túnel VPN cifrado (10.8.0.2)" \
    docker exec bob ping -c 2 -W 3 10.8.0.2

# — Handshakes criptográficos (confirman que el túnel está cifrado y activo) —
check_output "alice tiene handshake WireGuard activo con el servidor" "[1-9]" \
    docker exec alice sh -c "wg show wg0 latest-handshakes | awk '{print \$2}'"

check_output "bob tiene handshake WireGuard activo con el servidor" "[1-9]" \
    docker exec bob sh -c "wg show wg0 latest-handshakes | awk '{print \$2}'"

check_output "servidor VPN tiene handshake activo con alice" "[1-9]" \
    docker exec vpn sh -c "wg show wg0 latest-handshakes | awk 'NR==1{print \$2}'"

check_output "servidor VPN tiene handshake activo con bob" "[1-9]" \
    docker exec vpn sh -c "wg show wg0 latest-handshakes | awk 'NR==2{print \$2}'"

# — Aislamiento: tráfico VPN NO sale por eth0 —
check_output "tráfico alice→bob NO sale por eth0 (sale por wg0)" "wg0" \
    docker exec alice ip route get 10.8.0.3

check_not "alice NO puede alcanzar la IP de túnel de bob por eth0 (sin VPN)" \
    docker exec alice ping -c 1 -W 2 -I eth0 10.8.0.3

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "=================================="
echo -e "RESULTADO: ${GREEN}$PASS PASS${NC}  ${RED}$FAIL FAIL${NC}  (total: $((PASS + FAIL)))"
echo "=================================="
echo ""

[ "$FAIL" -eq 0 ]
