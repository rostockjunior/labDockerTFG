#!/bin/sh
set -ex

# Setup networking
ip route flush table main

ETH_EXT=$(ip -4 addr | grep '192.168.4.1' | awk '{print $NF}')
ETH_NET7=$(ip -4 addr | grep '192.168.5.66' | awk '{print $NF}')
ETH_NET9=$(ip -4 addr | grep '192.168.5.129' | awk '{print $NF}')

ip route add 192.168.4.0/26 dev $ETH_EXT scope link src 192.168.4.1
ip route add 192.168.5.64/27 dev $ETH_NET7 scope link src 192.168.5.66
ip route add 192.168.5.128/27 dev $ETH_NET9 scope link src 192.168.5.129

# Static routes toward DMZ and internal network via firewall_extern
ip route add 192.168.4.64/26 via 192.168.4.2 dev $ETH_EXT
ip route add 192.168.4.128/26 via 192.168.4.2 dev $ETH_EXT

/usr/local/bin/net-config/dynamic-routing.sh

exec /bin/sh
