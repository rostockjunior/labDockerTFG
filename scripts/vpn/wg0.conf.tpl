[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = 10.8.0.1/24
ListenPort = 51820

[Peer]
# alice
PublicKey = ${ALICE_PUBKEY}
AllowedIPs = 10.8.0.2/32

[Peer]
# bob
PublicKey = ${BOB_PUBKEY}
AllowedIPs = 10.8.0.3/32
