#!/bin/sh
set -ex

# Setup networking
ip route flush table main

ETH_LAN=$(ip -4 addr | grep '192.168.3.1' | awk '{print $NF}')
ETH_NET6=$(ip -4 addr | grep '192.168.5.34' | awk '{print $NF}')
ETH_NET9=$(ip -4 addr | grep '192.168.5.130' | awk '{print $NF}')

ip route add 192.168.3.0/24 dev $ETH_LAN scope link src 192.168.3.1
ip route add 192.168.5.32/27 dev $ETH_NET6 scope link src 192.168.5.34
ip route add 192.168.5.128/27 dev $ETH_NET9 scope link src 192.168.5.130

/usr/local/bin/net-config/dynamic-routing.sh

exec /bin/sh
