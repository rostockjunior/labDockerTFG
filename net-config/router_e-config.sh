#!/bin/sh
set -ex

# Setup networking
ip route flush table main

ETH_NET5=$(ip -4 addr | grep '192.168.5.2' | awk '{print $NF}')
ETH_NET7=$(ip -4 addr | grep '192.168.5.65' | awk '{print $NF}')
ETH_NET8=$(ip -4 addr | grep '192.168.5.97' | awk '{print $NF}')

ip route add 192.168.5.0/27 dev $ETH_NET5 scope link src 192.168.5.2
ip route add 192.168.5.64/27 dev $ETH_NET7 scope link src 192.168.5.65
ip route add 192.168.5.96/27 dev $ETH_NET8 scope link src 192.168.5.97

/usr/local/bin/net-config/dynamic-routing.sh

exec /bin/sh
