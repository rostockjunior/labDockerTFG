#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.5.64/27 dev eth1 scope link src 192.168.5.66
ip route add 192.168.5.128/27 dev eth2 scope link src 192.168.5.129
ip route add 192.168.4.0/26 dev eth0 scope link src 192.168.4.1

/usr/local/bin/net-config/dynamic-routing.sh

# Execute CMD arguments
exec /bin/sh
