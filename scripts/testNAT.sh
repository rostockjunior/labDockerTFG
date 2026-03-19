#!/bin/bash

# testNAT.sh
# This script shows the difference between having NAT enabled or disabled on router_a.
# Without NAT, john can see alice's real IP. With NAT, john only sees router_a's IP.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
result() { echo -e "${BLUE}[CAPTURE]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${RED}[!]${NC} $1"; }
divider() { echo -e "${BOLD}--------------------------------------------------${NC}"; }

# Get alice's current IP from her interface
ALICE_IP=$(docker exec alice ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1)
ROUTER_A_ETH1="192.168.5.1"
TARGET="192.168.2.2" # john

capture_source_ip() {
  # Start tcpdump on router_a's external interface, then ping from alice
  # We wait a bit before pinging so tcpdump has time to start
  docker exec router_a timeout 3 tcpdump -n -i eth1 icmp 2>/dev/null &
  TCPDUMP_PID=$!
  sleep 0.5
  docker exec alice ping -c2 -W2 $TARGET >/dev/null 2>&1
  wait $TCPDUMP_PID 2>/dev/null
}

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}   NAT demo — router_a                  ${NC}"
echo -e "${BOLD}========================================${NC}"
echo -e "  Alice IP   : ${YELLOW}$ALICE_IP${NC}"
echo -e "  Router eth1 : ${YELLOW}$ROUTER_A_ETH1${NC}"
echo -e "  Target      : ${YELLOW}$TARGET (john)${NC}"
echo ""

# --- PHASE 1: no NAT rule ---
divider
echo -e "${BOLD}PHASE 1 — Without NAT${NC}"
divider

# Remove the rule if it exists, ignore error if it was already missing
docker exec router_a iptables -t nat -D POSTROUTING -s 192.168.1.0/24 -o eth1 -j MASQUERADE 2>/dev/null || true

info "MASQUERADE rule removed"
info "Capturing traffic on router_a eth1 while alice pings john..."
echo ""

CAPTURE=$(capture_source_ip)
echo "$CAPTURE" | grep "ICMP echo request" | head -3 | while read line; do
  result "$line"
done

echo ""
if echo "$CAPTURE" | grep -q "$ALICE_IP > $TARGET"; then
  warning "Source IP seen by john: ${BOLD}$ALICE_IP${NC} — alice's real IP is exposed"
else
  warning "No traffic captured — check connectivity"
fi

# --- PHASE 2: with NAT rule ---
echo ""
divider
echo -e "${BOLD}PHASE 2 — With NAT (MASQUERADE)${NC}"
divider

# Add the MASQUERADE rule so traffic from network1 goes out with router_a's IP
docker exec router_a iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o eth1 -j MASQUERADE
info "MASQUERADE rule added"
info "Capturing traffic on router_a eth1 while alice pings john..."
echo ""

CAPTURE=$(capture_source_ip)
echo "$CAPTURE" | grep "ICMP echo request" | head -3 | while read line; do
  result "$line"
done

echo ""
if echo "$CAPTURE" | grep -q "$ROUTER_A_ETH1 > $TARGET"; then
  success "Source IP seen by john: ${BOLD}$ROUTER_A_ETH1${NC} — alice's IP is hidden behind router_a"
else
  warning "No traffic captured with router_a's IP — is NAT working?"
fi

# --- summary ---
echo ""
divider
echo -e "${BOLD}SUMMARY${NC}"
divider
echo -e "  Without NAT  -> john sees ${RED}${BOLD}$ALICE_IP${NC}     (alice's real IP)"
echo -e "  With NAT     -> john sees ${GREEN}${BOLD}$ROUTER_A_ETH1${NC}  (router_a's IP)"
echo ""
echo -e "  NAT rule is ${GREEN}still active${NC} after this test."
divider
echo ""
