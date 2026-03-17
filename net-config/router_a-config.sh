#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.1.0/24 dev eth0 scope link src 192.168.1.1
ip route add 192.168.5.0/27 dev eth1 scope link src 192.168.5.1

/usr/local/bin/net-config/dynamic-routing.sh

# Execute CMD arguments
exec /bin/sh
