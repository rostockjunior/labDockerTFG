#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.4.64/26 dev eth0 scope link src 192.168.4.66
ip route add default via 192.168.4.65 dev eth0

# Install Nginx proxy and configure it.
apk add --no-cache nginx
mkdir -p /var/log/nginx
cp /scripts/nginx.conf /etc/nginx/nginx.conf

# Start nginx in the foreground
nginx -g "daemon off;" &

# Execute CMD arguments
exec /bin/sh
