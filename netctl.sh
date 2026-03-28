#!/bin/bash

# netctl.sh - main control script for the lab
# usage: ./netctl.sh [--start-scenario] [--stop-scenario] [--open <node>]
#        [--start-rip] [--stop-rip] [--start-ospf] [--stop-ospf]

# Check if Docker is available
if ! command -v docker &>/dev/null; then
  echo "Error: Docker is not installed."
  exit 1
fi

services=$(docker compose ps --services)

case "$1" in
--start-scenario)
  echo "Starting scenario..."
  docker compose build --no-cache
  docker compose up -d
  ;;

--stop-scenario)
  echo "Stopping scenario..."
  docker compose down --volumes --remove-orphans
  ;;

--open)
  if [ -z "$2" ]; then
    echo "Error: Node name is required for --open."
    exit 1
  fi
  node_name="$2"
  echo "Opening shell for node: $node_name"
  docker exec -it "$node_name" /bin/bash
  ;;

--start-rip)
  for service in $services; do
    if [[ "$service" == *router* ]]; then
      echo "Starting RIP for $service ..."
      docker compose exec -T "$service" /bin/sh -c "/usr/local/bin/net-config/dynamic-routing.sh --start rip"
    fi
  done
  ;;

--start-ospf)
  for service in $services; do
    if [[ "$service" == *router* ]]; then
      echo "Starting OSPF for $service ..."
      docker compose exec -T "$service" /bin/sh -c "/usr/local/bin/net-config/dynamic-routing.sh --start ospf"
    fi
  done
  ;;

--stop-rip)
  for service in $services; do
    if [[ "$service" == *router* ]]; then
      echo "Stopping RIP for $service ..."
      docker compose exec -T "$service" /bin/sh -c "/usr/local/bin/net-config/dynamic-routing.sh --stop rip"
    fi
  done
  ;;

--stop-ospf)
  for service in $services; do
    if [[ "$service" == *router* ]]; then
      echo "Stopping OSPF for $service ..."
      docker compose exec -T "$service" /bin/sh -c "/usr/local/bin/net-config/dynamic-routing.sh --stop ospf"
    fi
  done
  ;;

--remove-link) ;;

*)
  echo "Error: Invalid parameter."
  echo "Valid options:"
  echo "  --start-scenario        build and start all containers"
  echo "  --stop-scenario         stop and remove all containers"
  echo "  --open <node>           open a shell in a container"
  echo "  --start-rip             start RIP on all routers"
  echo "  --stop-rip              stop RIP on all routers"
  echo "  --start-ospf            start OSPF on all routers"
  echo "  --stop-ospf             stop OSPF on all routers"
  exit 1
  ;;
esac
