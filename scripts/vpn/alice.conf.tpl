[Interface]
PrivateKey = ${ALICE_PRIVKEY}
Address = 10.8.0.2/24

[Peer]
PublicKey = ${SERVER_PUBKEY}
AllowedIPs = 10.8.0.0/24
Endpoint = 192.168.3.3:51820
PersistentKeepalive = 25
