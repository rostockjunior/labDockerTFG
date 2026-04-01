#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.4.128/26 dev eth0 scope link src 192.168.4.130
ip route add default via 192.168.4.129 dev eth0

# Setup apache
apk add --no-cache apache2
p /scripts/http/index.html /var/www/localhost/htdocs/index.html

# Start apache in the foreground
httpd -D FOREGROUND &

# Execute CMD arguments
exec /bin/sh
