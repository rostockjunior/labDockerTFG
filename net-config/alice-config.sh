#!/bin/sh
set -ex

# Setup networking
ip route flush table main
ip addr flush dev eth0

sleep 3 # Waiting DHCP server to be up

# Request an IP from DHCP server
udhcpc -i eth0 -s /usr/share/udhcpc/default.script

printf "nameserver 192.168.3.2\noptions single-request\n" >/etc/resolv.conf

# Wait up to 60 s for the VPN server to generate Alice's config
i=0
while [ ! -f /scripts/vpn/alice.conf ] && [ $i -lt 30 ]; do
  sleep 2
  i=$((i + 1))
done

if [ -f /scripts/vpn/alice.conf ]; then
  modprobe wireguard 2>/dev/null || true
  mkdir -p /etc/wireguard
  cp /scripts/vpn/alice.conf /etc/wireguard/wg0.conf
  wg-quick up wg0
fi

exec /bin/sh
