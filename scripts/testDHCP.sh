#!/bin/bash

# test-dhcp.sh
# Shows how alice and bob get their IPs from router_a's DHCP server.
# Also demonstrates what happens when a lease is released and renewed.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
result() { echo -e "${BLUE}[OUTPUT]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${RED}[!]${NC} $1"; }
divider() { echo -e "${BOLD}--------------------------------------------------${NC}"; }

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}   DHCP — router_a                 ${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# --- PHASE 1: check current leases on router_a ---
divider
echo -e "${BOLD}PHASE 1 — Current leases on router_a${NC}"
divider

info "Active leases in /var/lib/dhcp/dhcpd.leases:"
echo ""
docker exec router_a cat /var/lib/dhcp/dhcpd.leases | grep -A6 "^lease" | while read line; do
  result "$line"
done

echo ""
ALICE_IP=$(docker exec alice ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1)
BOB_IP=$(docker exec bob ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1)

if [[ "$ALICE_IP" == 192.168.1.* ]]; then
  success "Alice has IP: ${BOLD}$ALICE_IP${NC} (assigned by DHCP)"
else
  warning "Alice has no valid IP in network1"
fi

if [[ "$BOB_IP" == 192.168.1.* ]]; then
  success "Bob has IP: ${BOLD}$BOB_IP${NC} (assigned by DHCP)"
else
  warning "Bob has no valid IP in network1"
fi

# --- PHASE 2: release and renew alice's lease ---
echo ""
divider
echo -e "${BOLD}PHASE 2 — Release and renew alice's lease${NC}"
divider

info "Releasing alice's current IP ($ALICE_IP)..."
docker exec alice udhcpc -i eth0 -R -q >/dev/null 2>&1 || true
sleep 1

ALICE_IP_AFTER_RELEASE=$(docker exec alice ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1)
if [[ -z "$ALICE_IP_AFTER_RELEASE" ]]; then
  success "Alice has no IP after release — lease was given back to the pool"
else
  result "Alice still has IP: $ALICE_IP_AFTER_RELEASE"
fi

echo ""
info "Requesting a new IP for alice..."
docker exec alice udhcpc -i eth0 -s /usr/share/udhcpc/default.script >/dev/null 2>&1
sleep 1

ALICE_NEW_IP=$(docker exec alice ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1)
if [[ "$ALICE_NEW_IP" == 192.168.1.* ]]; then
  success "Alice got a new IP: ${BOLD}$ALICE_NEW_IP${NC}"
else
  warning "Alice could not get a new IP"
fi

# --- PHASE 3: check connectivity after renewal ---
echo ""
divider
echo -e "${BOLD}PHASE 3 — Connectivity check after renewal${NC}"
divider

info "Ping from alice ($ALICE_NEW_IP) to bob ($BOB_IP)..."
docker exec alice ping -c2 -W2 $BOB_IP >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  success "Alice can reach bob — same network, no issues after renewal"
else
  warning "Alice cannot reach bob after renewal"
fi

info "Ping from alice to john (192.168.2.2) through NAT..."
docker exec alice ping -c2 -W2 192.168.2.2 >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  success "Alice can reach john — routing and NAT still working after renewal"
else
  warning "Alice cannot reach john after renewal"
fi

# --- summary ---
echo ""
divider
echo -e "${BOLD}SUMMARY${NC}"
divider
echo -e "  DHCP server  : ${GREEN}router_a (192.168.1.1)${NC}"
echo -e "  Lease range  : ${YELLOW}192.168.1.10 - 192.168.1.100${NC}"
echo -e "  Alice IP     : ${GREEN}${BOLD}$ALICE_NEW_IP${NC}"
echo -e "  Bob IP       : ${GREEN}${BOLD}$BOB_IP${NC}"
echo ""
echo -e "  IPs are assigned dynamically — they may change on restart."
divider
echo ""
