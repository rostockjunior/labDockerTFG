#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Dynamic obtention of interfaces IP's
ETH_EXT=$(ip -4 addr | grep '192.168.4.2' | awk '{print $NF}')
ETH_DMZ=$(ip -4 addr | grep '192.168.4.65' | awk '{print $NF}')

ip route add 192.168.4.0/26 dev $ETH_EXT scope link src 192.168.4.2
ip route add 192.168.4.64/26 dev $ETH_DMZ scope link src 192.168.4.65
ip route add default via 192.168.4.1 dev $ETH_EXT

# Drop everything by default on the FORWARD chain
iptables -P FORWARD DROP

# Allow already established connections through (return traffic)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Redirect incoming HTTP and HTTPS to the proxy in the DMZ
iptables -t nat -A PREROUTING -i $ETH_EXT -p tcp --dport 80 -j DNAT --to-destination 192.168.4.66:80
iptables -t nat -A PREROUTING -i $ETH_EXT -p tcp --dport 443 -j DNAT --to-destination 192.168.4.66:443

# Masquerade traffic going into the DMZ
iptables -t nat -A POSTROUTING -o $ETH_DMZ -j MASQUERADE

# Allow HTTP and HTTPS toward the proxy
iptables -A FORWARD -i $ETH_EXT -o $ETH_DMZ -p tcp --dport 80 -d 192.168.4.66 -j ACCEPT
iptables -A FORWARD -i $ETH_EXT -o $ETH_DMZ -p tcp --dport 443 -d 192.168.4.66 -j ACCEPT

# Allow ICMP for testing and diagnostics
iptables -A FORWARD -p icmp -j ACCEPT

# Log dropped packets
iptables -A FORWARD -j LOG --log-prefix "FW1_DROP: " --log-level 4

exec /bin/sh
