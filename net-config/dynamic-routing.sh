#!/bin/bash

routing=${2}
daemon=${routing}d
verbose=1
# Define the path to ripd.conf
DAEMON_CONF="/etc/frr/${daemon}.conf"
DAEMON_LOG="/var/log/frr/${daemon}.log"

# Start the ripd.conf file with the basic configuration
echo "log file $DAEMON_LOG" > $DAEMON_CONF

if [[ $verbose -gt 0 ]]; then
  echo "debug ${routing} events" >> $DAEMON_CONF
  echo "debug ${routing} zebra" >> $DAEMON_CONF
  echo "debug ${routing} packet" >> $DAEMON_CONF
fi

echo "router ${routing}" >> $DAEMON_CONF
echo " redistribute connected" >> $DAEMON_CONF

if [[ $routing == "rip" ]]; then
  echo " timers basic 5 30 30" >> $DAEMON_CONF
  extra=""
else
  extra="area 0"
fi

# Loop through all active interfaces and get the network addresses
for iface in $(ip -4 addr show | cut -d: -f2 | awk '{print $1}' | grep eth  | cut -d@ -f1); do
    NETWORK=$(ip r | grep $iface | cut -d" " -f1)
    echo " network $NETWORK $extra" >> $DAEMON_CONF
done

chown frr:frr $DAEMON_CONF

# Function to start zebra and ripd/ospfd
start_services() {
    /usr/sbin/zebra -d --limit-fds 100000 >/dev/null 2>&1 &
    /usr/sbin/${daemon} -d --limit-fds 100000 -f /etc/frr/${daemon}.conf  >/dev/null 2>&1 &
}

# Function to stop zebra and ripd/ospfd
stop_services() {
    if pgrep -x zebra > /dev/null; then
        pkill zebra
    fi
    if pgrep -x ${daemon} > /dev/null; then
        pkill ${daemon}
    fi
}

# Handle the start, stop, and restart arguments
if [[ "$1" == "--start" ]]; then
    start_services
elif [[ "$1" == "--stop" ]]; then
    stop_services
elif [[ "$1" == "--restart" ]]; then
    stop_services
    sleep 2  # Wait for processes to terminate
    start_services
fi
