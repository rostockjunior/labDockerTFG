#!/bin/sh
set -ex

# Setup setworking
ip route flush table main

# Configure network routes.
ip route add 192.168.4.0/26 dev eth0 scope link src 192.168.4.2
ip route add 192.168.4.64/26 dev eth1 scope link src 192.168.4.65
ip route add default via 192.168.4.1 dev eth0

# --- Firewall rules ---

# Redirect incoming HTTP requests on eth0 to the proxy in the DMZ
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 -j DNAT --to-destination 192.168.4.66:80
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 443 -j DNAT --to-destination 192.168.4.66:443

# Masquerade traffic going into the DMZ so the proxy sees firewall_extern as the source
# this is the same as we do in N1 when we apply NAT.
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE

# Drop everything by default on the FORWARD chain
iptables -P FORWARD DROP

# Allow already established connections through (return traffic)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow HTTP and HTTPS traffic coming from outside toward the proxy
iptables -A FORWARD -i eth0 -o eth1 -p tcp --dport 80 -d 192.168.4.66 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -p tcp --dport 443 -d 192.168.4.66 -j ACCEPT

# Allow ICMP for testing and diagnostics
iptables -A FORWARD -p icmp -j ACCEPT

# Log dropped packets so we can see what is being blocked
iptables -A FORWARD -j LOG --log-prefix "FW1_DROP: " --log-level 4

# Execute CMD arguments
exec /bin/sh
