#!/bin/sh
set -ex

ip route flush table main

ip route add 192.168.4.64/26 dev eth0 scope link src 192.168.4.67
ip route add 192.168.4.128/26 dev eth1 scope link src 192.168.4.129
ip route add default via 192.168.4.65 dev eth0

# --- Firewall rules ---

# Drop everything by default on the FORWARD chain
iptables -P FORWARD DROP

# Allow already established connections through (return traffic)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Only the proxy can reach the HTTP(p80) / MySQL(p3306)
iptables -A FORWARD -i eth0 -o eth1 -p tcp --dport 80 -s 192.168.4.66 -d 192.168.4.130 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -p tcp --dport 3306 -s 192.168.4.66 -d 192.168.4.131 -j ACCEPT

# Any DMZ node can send logs to syslog on UDP 514
iptables -A FORWARD -i eth0 -o eth1 -p udp --dport 514 -d 192.168.4.132 -j ACCEPT

# Allow ICMP for testing and diagnostics
iptables -A FORWARD -p icmp -j ACCEPT

# Log dropped packets so we can see what is being blocked
iptables -A FORWARD -j LOG --log-prefix "FW2_DROP: " --log-level 4

# Execute CMD arguments
exec /bin/sh
