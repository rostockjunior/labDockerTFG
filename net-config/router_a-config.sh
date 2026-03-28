#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.1.0/24 dev eth0 scope link src 192.168.1.1
ip route add 192.168.5.0/27 dev eth1 scope link src 192.168.5.1

# Configure NAT
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o eth1 -j MASQUERADE

# DHCP server setup
# Tell isc-dhcp-server to listen only on eth0 (network1 side)
echo 'INTERFACESv4="eth0"' >/etc/default/isc-dhcp-server

cp /scripts/router_a-dhcpd.conf /etc/dhcp/dhcpd.conf
mkdir -p /var/lib/dhcp
touch /var/lib/dhcp/dhcpd.leases

# Start the DHCP server
/usr/sbin/dhcpd -4 -cf /etc/dhcp/dhcpd.conf -lf /var/lib/dhcp/dhcpd.leases eth0

/usr/local/bin/net-config/dynamic-routing.sh

# Execute CMD arguments
exec /bin/sh
