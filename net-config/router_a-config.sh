#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Detect interfaces dynamically — Docker may assign eth names in any order
ETH_LAN=$(ip -4 addr | grep '192.168.1.1' | awk '{print $NF}')
ETH_BACKBONE=$(ip -4 addr | grep '192.168.5.1' | awk '{print $NF}')

ip route add 192.168.1.0/24 dev $ETH_LAN scope link src 192.168.1.1
ip route add 192.168.5.0/27 dev $ETH_BACKBONE scope link src 192.168.5.1

# NAT: traffic from network1 goes out with router_a's IP
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o $ETH_BACKBONE -j MASQUERADE

# DHCP server setup
echo 'INTERFACESv4="'$ETH_LAN'"' >/etc/default/isc-dhcp-server
cp /scripts/router_a-dhcpd.conf /etc/dhcp/dhcpd.conf
mkdir -p /var/lib/dhcp
touch /var/lib/dhcp/dhcpd.leases
rm -f /var/run/dhcpd.pid
/usr/sbin/dhcpd -4 -cf /etc/dhcp/dhcpd.conf -lf /var/lib/dhcp/dhcpd.leases $ETH_LAN

/usr/local/bin/net-config/dynamic-routing.sh

exec /bin/sh
