#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Detect interfaces by IP (Docker may assign eth names in any order)
ETH_NET2=$(ip -4 addr | grep '192.168.2.2' | awk '{print $NF}')
ETH_NET1=$(ip -4 addr | grep '192.168.1.100' | awk '{print $NF}')

ip route add 192.168.2.0/24 dev $ETH_NET2 scope link src 192.168.2.2
ip route add default via 192.168.2.1 dev $ETH_NET2
ip route add 192.168.1.0/24 dev $ETH_NET1 scope link src 192.168.1.100

printf "nameserver 192.168.3.2\noptions single-request\n" > /etc/resolv.conf

# Ensure attack scripts directory exists
mkdir -p /scripts/attacks

exec /bin/sh

