#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.2.0/24 dev eth0 scope link src 192.168.2.1
ip route add 192.168.5.96/27 dev eth2 scope link src 192.168.5.98
ip route add 192.168.5.32/27 dev eth1 scope link src 192.168.5.33

/usr/local/bin/net-config/dynamic-routing.sh

# Execute CMD arguments
exec /bin/sh
