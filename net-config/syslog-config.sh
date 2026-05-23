#!/bin/sh
set -ex

# Setup networking
ip route flush table main
ip route add 192.168.4.128/26 dev eth0 scope link src 192.168.4.132
ip route add default via 192.168.4.129 dev eth0

# Create log directories
mkdir -p /var/log/remote
mkdir -p /var/log/syslog-ng

# Copy config from the mounted volume
cp /scripts/syslog-ng.conf /etc/syslog-ng/syslog-ng.conf

# Start syslog-ng in the foreground
syslog-ng -F &

# Execute CMD arguments
exec /bin/sh
