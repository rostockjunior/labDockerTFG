#!/bin/sh
set -ex

# Setup netwirking
ip route flush table main

# Dynamic obtention of interfaces IP's
ETH_DMZ=$(ip -4 addr | grep '192.168.4.67' | awk '{print $NF}')
ETH_INT=$(ip -4 addr | grep '192.168.4.129' | awk '{print $NF}')

ip route add 192.168.4.64/26 dev $ETH_DMZ scope link src 192.168.4.67
ip route add 192.168.4.128/26 dev $ETH_INT scope link src 192.168.4.129
ip route add default via 192.168.4.65 dev $ETH_DMZ

# Drop everything by default on the FORWARD chain
iptables -P FORWARD DROP

# Allow already established connections through (return traffic)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Only the proxy can reach the HTTP server on port 80
iptables -A FORWARD -i $ETH_DMZ -o $ETH_INT -p tcp --dport 80 -s 192.168.4.66 -d 192.168.4.130 -j ACCEPT

# Only the proxy can reach MySQL on port 3306
iptables -A FORWARD -i $ETH_DMZ -o $ETH_INT -p tcp --dport 3306 -s 192.168.4.66 -d 192.168.4.131 -j ACCEPT

# Any DMZ node can send logs to syslog on UDP 514
iptables -A FORWARD -i $ETH_DMZ -o $ETH_INT -p udp --dport 514 -d 192.168.4.132 -j ACCEPT

# Allow ICMP for testing and diagnostics
iptables -A FORWARD -p icmp -j ACCEPT

# Log dropped packets
iptables -A FORWARD -j LOG --log-prefix "FW2_DROP: " --log-level 4

exec /bin/sh
