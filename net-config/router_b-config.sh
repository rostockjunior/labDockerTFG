#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Detect interfaces dynamically — Docker may assign eth names in any order
ETH_LAN=$(ip -4 addr | grep '192.168.2.1' | awk '{print $NF}')
ETH_NET6=$(ip -4 addr | grep '192.168.5.33' | awk '{print $NF}')
ETH_NET8=$(ip -4 addr | grep '192.168.5.98' | awk '{print $NF}')

ip route add 192.168.2.0/24 dev $ETH_LAN scope link src 192.168.2.1
ip route add 192.168.5.32/27 dev $ETH_NET6 scope link src 192.168.5.33
ip route add 192.168.5.96/27 dev $ETH_NET8 scope link src 192.168.5.98

/usr/local/bin/net-config/dynamic-routing.sh

exec /bin/sh
