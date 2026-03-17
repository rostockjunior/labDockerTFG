#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.4.0/24 dev eth0 scope link src 192.168.4.3
ip route add default via 192.168.4.1 dev eth0

# Execute CMD arguments
exec /bin/sh

