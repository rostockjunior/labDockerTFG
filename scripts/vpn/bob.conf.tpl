[Interface]
PrivateKey = ${BOB_PRIVKEY}
Address = 10.8.0.3/24

[Peer]
PublicKey = ${SERVER_PUBKEY}
AllowedIPs = 10.8.0.0/24
Endpoint = 192.168.3.3:51820
PersistentKeepalive = 25
