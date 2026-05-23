# Problemas encontrados y soluciones aplicadas

Registro de los errores detectados al poner en marcha el laboratorio de redes
Docker (rama `s2`) y las correcciones que se aplicaron para resolverlos.

---

## Problema 1 — MariaDB no escuchaba en ningún puerto TCP

### Síntoma
Al intentar conectarse desde el contenedor `proxy` al puerto 3306 de `mysql`,
la conexión fallaba con `Connection refused` o `TimeoutError`. El log de
arranque de MariaDB mostraba `port: 0`:

```
Version: '11.4.10-MariaDB'  socket: '/run/mysqld/mysqld.sock'  port: 0
```

### Causa
Alpine Linux incluye en su paquete `mariadb` un fichero de configuración
`/etc/my.cnf.d/mariadb-server.cnf` con la directiva `skip-networking`
activada por defecto. Esto hace que MariaDB arranque solo con socket Unix
local y nunca abra el puerto TCP 3306.

### Solución
Se añadió en `Dockerfile.mysql` un paso de build que comenta esa directiva
antes de copiar los scripts:

```dockerfile
RUN sed -i 's/^skip-networking/# skip-networking/' /etc/my.cnf.d/mariadb-server.cnf
```

Tras reconstruir la imagen, MariaDB arrancó escuchando en `0.0.0.0:3306`
y `:::3306` (IPv4 e IPv6).

### Fichero modificado
`Dockerfile.mysql`

---

## Problema 2 — syslog-ng no recibía mensajes enviados por IPv6

### Síntoma
El contenedor `syslog` solo aparecía en `netstat` con `0.0.0.0:514` (UDP
IPv4). Los mensajes enviados desde otros contenedores usando un socket
`AF_INET6` nunca llegaban al fichero de log.

### Causa
La fuente UDP en `syslog-ng.conf` solo especificaba `ip("0.0.0.0")`, que
equivale a escuchar exclusivamente en IPv4. syslog-ng no hace dual-stack
automático como ocurre con algunos sockets del kernel.

### Solución
Se añadió una segunda fuente en `scripts/syslog-ng.conf` ligada a `::` con
`ip-protocol(6)`, y se conectó esa fuente al mismo destino de ficheros:

```
source s_udp6 {
    network(
        transport("udp")
        port(514)
        ip("::")
        ip-protocol(6)
    );
};

log { source(s_udp6); destination(d_remote); };
```

Como `scripts/` es un volumen montado (no forma parte de la imagen), bastó
con reiniciar el contenedor sin reconstruir: `docker compose restart syslog`.

### Fichero modificado
`scripts/syslog-ng.conf`

---

## Problema 3 — Herramientas no disponibles en contenedores Alpine

Los contenedores Alpine (node, http, proxy, mysql, syslog) usan BusyBox y
no incluyen las mismas utilidades que Ubuntu. Esto afectó a varios comandos
de diagnóstico y test.

### 3a — `ss` no disponible

| Síntoma | `ss -ulnp` devuelve *command not found* |
|---|---|
| Causa | Alpine no instala `iproute2` con `ss` de serie |
| Solución | Usar `netstat -ulnp` (disponible vía `net-tools`, que instala el paquete `syslog-ng` como dependencia en ese contenedor) |

### 3b — `logger` de BusyBox no soporta envío remoto

| Síntoma | `logger -n 192.168.4.132 -P 514 --udp "msg"` → *unrecognized option: n* |
|---|---|
| Causa | BusyBox implementa un `logger` simplificado que solo escribe en el syslog local, sin opción de host remoto |
| Solución | Enviar el mensaje UDP directamente con Python (disponible en todos los contenedores Alpine del laboratorio): |

```python
import socket, time
msg = b'<14>' + time.strftime('%b %e %H:%M:%S').encode() + b' http mensaje-de-prueba'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(msg, ('192.168.4.132', 514))
s.close()
```

### 3c — Comando `mysql` deprecado en MariaDB 11.x

| Síntoma | `mysql -u root -e "..."` → *Deprecated program name. Use /usr/bin/mariadb* |
|---|---|
| Causa | Desde MariaDB 10.5+ el binario canónico es `mariadb`; `mysql` sigue funcionando pero emite advertencias y en versiones futuras se eliminará |
| Solución | Usar `mariadb` en lugar de `mysql` en todos los comandos y scripts |

### 3d — `wget` de BusyBox no soporta URLs con dirección IPv6

| Síntoma | `wget http://[fd00:4::130]/` → *no matches found: http://[fd00:4::130]/*, la shell interpreta los corchetes antes de pasárselos a wget |
|---|---|
| Causa | BusyBox wget no reconoce la notación `http://[addr]:port/` de RFC 2732 |
| Solución | Usar Python para peticiones HTTP sobre IPv6: |

```python
import urllib.request
print(urllib.request.urlopen('http://[fd00:4::130]/').read().decode())
```

---

## Problema 4 — PID file obsoleto impide reiniciar el servidor DHCP

### Síntoma
Al reiniciar el contenedor `router_a` (necesario para recargar la nueva
configuración de DHCP), el proceso `dhcpd` no arrancaba y alice y bob dejaban
de obtener IP:

```
There's already a DHCP server running.
exiting.
```

### Causa
Docker con `restart: always` reutiliza la capa de escritura del contenedor
entre reinicios. El fichero `/var/run/dhcpd.pid` del proceso anterior seguía
presente, y `dhcpd` lo interpretaba como que ya había otro servidor en marcha.

### Solución
Añadir `rm -f /var/run/dhcpd.pid` justo antes de lanzar `dhcpd` en
`router_a-config.sh`:

```sh
rm -f /var/run/dhcpd.pid
/usr/sbin/dhcpd -4 -cf /etc/dhcp/dhcpd.conf -lf /var/lib/dhcp/dhcpd.leases $ETH_LAN
```

### Fichero modificado
`net-config/router_a-config.sh`

---

## Problema 5 — Docker sobreescribe `/etc/resolv.conf` y udhcpc no puede modificarlo

### Síntoma
Después de añadir la opción `domain-name-servers` al servidor DHCP y
reiniciar alice, el fichero `/etc/resolv.conf` dentro del contenedor seguía
mostrando `nameserver 127.0.0.11` (el resolver interno de Docker) en lugar
del servidor DNS del laboratorio.

### Causa
En versiones modernas de Docker Engine, `/etc/resolv.conf` es un fichero
gestionado por Docker que se regenera en cada arranque del contenedor.
El script de udhcpc (`/usr/share/udhcpc/default.script`) intenta reemplazarlo
de forma atómica con `mv`, pero Docker tiene el fichero en uso y la operación
falla silenciosamente con `Resource busy`.

### Solución
Escribir explícitamente el fichero **después** de que udhcpc termine, mediante
una redirección directa (que sí funciona aunque `mv` falle):

```sh
udhcpc -i eth0 -s /usr/share/udhcpc/default.script
printf "nameserver 192.168.3.2\noptions single-request\n" > /etc/resolv.conf
```

El flag `single-request` es importante: indica al resolver que envíe las
queries A y AAAA de forma secuencial en lugar de en paralelo, evitando
problemas con la query AAAA (ver Problema 6).

Para john, que usa IP estática y no ejecuta udhcpc, se escribe directamente:

```sh
printf "nameserver 192.168.3.2\noptions single-request\n" > /etc/resolv.conf
```

### Ficheros modificados
`net-config/alice-config.sh`, `net-config/bob-config.sh`, `net-config/john-config.sh`

---

## Problema 6 — dnsmasq devuelve `REFUSED` en queries AAAA y rompe `getaddrinfo`

### Síntoma
La resolución DNS funcionaba con `socket.gethostbyname()` pero fallaba con
`socket.getaddrinfo()`, con `wget` y con cualquier otro cliente que use la
llamada estándar del sistema. El error era `[Errno -3] Try again` (EAI_AGAIN).
Con `nslookup` se veía claramente:

```
Name:    WebDelLaboratorio.com
Address: 192.168.4.2          ← query A: OK

** server can't find WebDelLaboratorio.com: REFUSED   ← query AAAA: falla
```

### Causa
`getaddrinfo()` (usada por wget, curl, y la mayoría de aplicaciones) envía dos
queries simultáneas: una de tipo A (IPv4) y otra de tipo AAAA (IPv6). La query
A tenía respuesta correcta, pero la query AAAA recibía `REFUSED` porque dnsmasq
no tenía registro AAAA ni servidor upstream al que reenviarla.

musl libc (la libc de Alpine) interpreta `REFUSED` como un error temporal y
devuelve `EAI_AGAIN` aunque la query A haya tenido éxito, impidiendo la
resolución.

### Solución
Declarar dnsmasq como autoritativo para el dominio del laboratorio con la
directiva `local=`. Con esto, dnsmasq responde `NXDOMAIN` (en lugar de
`REFUSED`) para tipos de registro no definidos (como AAAA), y musl acepta
ese resultado como definitivo y devuelve la dirección IPv4:

```
local=/WebDelLaboratorio.com/
address=/WebDelLaboratorio.com/192.168.4.2
```

### Fichero modificado
`scripts/dnsmasq.conf`

---

## Resumen de ficheros modificados

| Fichero | Tipo de cambio |
|---|---|
| `Dockerfile.mysql` | Añadida línea `RUN sed -i` para comentar `skip-networking` |
| `scripts/syslog-ng.conf` | Añadida fuente UDP IPv6 (`s_udp6`) y su `log { }` correspondiente |
| `net-config/router_a-config.sh` | Añadido `rm -f /var/run/dhcpd.pid` antes de lanzar dhcpd |
| `net-config/alice-config.sh` | Escribe `/etc/resolv.conf` con DNS y `single-request` tras udhcpc |
| `net-config/bob-config.sh` | Igual que alice-config.sh |
| `net-config/john-config.sh` | Escribe `/etc/resolv.conf` con DNS y `single-request` (IP estática) |
| `scripts/dnsmasq.conf` | Añadido `local=/WebDelLaboratorio.com/` para evitar REFUSED en queries AAAA |
| `docker-compose.yml` | Añadido servicio `dns` en network3 (192.168.3.2) |
| `Dockerfile.dns` | Nuevo: Alpine con dnsmasq |
| `net-config/dns-config.sh` | Nuevo: configura rutas y lanza dnsmasq |
| `scripts/router_a-dhcpd.conf` | Añadida opción `domain-name-servers 192.168.3.2` |

---

## Arquitectura de red — referencia rápida

```
[alice/bob]──network1──[router_a]──network5──[router_e]──network7──[router_d]──network4_ext──[firewall_extern]
[john]───────network2──[router_b]──network6──[router_c]──network9──╯                 │
                                                                               network4_dmz
                                                                            [proxy / nginx]
                                                                               │
                                                                         [firewall_intern]
                                                                               │
                                                                         network4_int (IPv4 + IPv6)
                                                                    [http] [mysql] [syslog]
```

- **network4\_ext** `192.168.4.0/26` — zona exterior, router\_d y firewall\_extern
- **network4\_dmz** `192.168.4.64/26` — DMZ, solo el proxy
- **network4\_int** `192.168.4.128/26` / `fd00:4::/64` — zona interna, servidores
