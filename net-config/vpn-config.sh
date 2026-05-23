#!/bin/sh
set -ex

# Setup networking
ip route flush table main
ip route add 192.168.3.0/24 dev eth0 scope link src 192.168.3.3
ip route add default via 192.168.3.1 dev eth0

# Shared directory where client configs will be placed
mkdir -p /scripts/vpn

# Key pairs generation for each VPN client
SERVER_PRIVKEY=$(wg genkey)
SERVER_PUBKEY=$(printf '%s' "$SERVER_PRIVKEY" | wg pubkey)

ALICE_PRIVKEY=$(wg genkey)
ALICE_PUBKEY=$(printf '%s' "$ALICE_PRIVKEY" | wg pubkey)

BOB_PRIVKEY=$(wg genkey)
BOB_PUBKEY=$(printf '%s' "$BOB_PRIVKEY" | wg pubkey)

export SERVER_PRIVKEY SERVER_PUBKEY ALICE_PRIVKEY ALICE_PUBKEY BOB_PRIVKEY BOB_PUBKEY

# Server config
mkdir -p /etc/wireguard
envsubst < /scripts/vpn/wg0.conf.tpl > /etc/wireguard/wg0.conf

# Alice client config
envsubst < /scripts/vpn/alice.conf.tpl > /scripts/vpn/alice.conf

# Bob client config
envsubst < /scripts/vpn/bob.conf.tpl > /scripts/vpn/bob.conf

# Start server
modprobe wireguard 2>/dev/null || true
wg-quick up wg0

exec /bin/sh
