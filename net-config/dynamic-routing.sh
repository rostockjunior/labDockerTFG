#!/bin/bash

# Routing protocol defaults to rip if not specified
routing=${2:-rip}
daemon=${routing}d

DAEMON_CONF="/etc/frr/frr.conf"
DAEMON_LOG="/var/log/frr/frr.log"

# Write the daemon config file
echo "log file $DAEMON_LOG" >$DAEMON_CONF
echo "router ${routing}" >>$DAEMON_CONF
echo " redistribute connected" >>$DAEMON_CONF

if [[ $routing == "rip" ]]; then
  echo " timers basic 5 30 30" >>$DAEMON_CONF
  extra=""
else
  extra="area 0"
fi

# Loop through active interfaces and add their networks to the config
for iface in $(ip -4 addr show | cut -d: -f2 | awk '{print $1}' | grep eth | cut -d@ -f1); do
  NETWORK=$(ip r | grep $iface | grep -v via | awk '{print $1}' | head -1)
  if [[ -n "$NETWORK" ]]; then
    echo " network $NETWORK $extra" >>$DAEMON_CONF
  fi
done

chown frr:frr $DAEMON_CONF

wait_socket() {
  local sock="$1" retries=15
  while [[ $retries -gt 0 ]]; do
    [[ -S $sock ]] && return 0
    sleep 1
    retries=$((retries - 1))
  done
  echo "ERROR: socket $sock not available" >&2
  return 1
}

start_services() {
  # Kill any leftover processes from previous runs
  pkill -x mgmtd 2>/dev/null || true
  pkill -x zebra 2>/dev/null || true
  pkill -x ${daemon} 2>/dev/null || true
  sleep 1

  # FRR 10.x: mgmtd must start before zebra
  /usr/sbin/mgmtd -d --limit-fds 100000
  wait_socket /run/frr/mgmtd_fe.sock || exit 1

  /usr/sbin/zebra -d --limit-fds 100000
  wait_socket /run/frr/zserv.api || exit 1

  /usr/sbin/${daemon} -d --limit-fds 100000
  wait_socket /run/frr/${daemon}.vty || exit 1

  # Push frr.conf into the running daemons
  vtysh -b || true
}

stop_services() {
  pkill -x zebra 2>/dev/null || true
  pkill -x ${daemon} 2>/dev/null || true
}

if [[ "$1" == "--start" ]]; then
  start_services
elif [[ "$1" == "--stop" ]]; then
  stop_services
elif [[ "$1" == "--restart" ]]; then
  stop_services
  sleep 2
  start_services
else
  start_services
fi
