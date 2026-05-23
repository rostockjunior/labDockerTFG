#!/bin/sh
set -ex

# Setup networking
ip route flush table main
ip route add 192.168.4.64/26 dev eth0 scope link src 192.168.4.66

# Route to internal servers via firewall_intern
ip route add 192.168.4.128/26 via 192.168.4.67 dev eth0
ip route add default via 192.168.4.65 dev eth0

# Setup nginx
mkdir -p /var/log/nginx
cp /scripts/nginx.conf /etc/nginx/nginx.conf

# Start nginx in the foreground
nginx -g "daemon off;" &

# Execute CMD arguments
exec /bin/sh
