#!/bin/sh
set -ex

# Setup networking
ip route flush table main
ip addr flush dev eth0

sleep 3 # Waiting DHCP server to be up

# Request an IP from DHCP server
udhcpc -i eth0 -s /usr/share/udhcpc/default.script

# Execute CMD arguments
exec /bin/sh
