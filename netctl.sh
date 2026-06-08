#!/bin/bash

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

--attack)
  if [ -z "$2" ] || [ -z "$3" ]; then
    echo "Error: se requiere nombre de ataque y acción."
    echo "Uso: $0 --attack <nombre|all> <start|stop|status>"
    exit 1
  fi
  action="$3"
  attack_map() {
    case "$1" in
      rip)   echo "attack_rip.py" ;;
      spoof) echo "attack_spoof.py" ;;
      mitm)  echo "attack_mitm.py" ;;
      flood) echo "attack_flood.py" ;;
      dns)   echo "attack_dns.py" ;;
      proxy) echo "attack_proxy.py" ;;
      *) echo "" ;;
    esac
  }
  if [ "$2" = "all" ]; then
    for name in rip spoof mitm flood dns proxy; do
      script=$(attack_map $name)
      echo "[$name] $action..."
      docker exec john python3 /scripts/attacks/$script $action 2>/dev/null || true
    done
  else
    script=$(attack_map "$2")
    if [ -z "$script" ]; then
      echo "Error: ataque desconocido '$2'. Válidos: rip spoof mitm flood dns proxy all"
      exit 1
    fi
    docker exec john python3 /scripts/attacks/$script $action
  fi
  ;;

*)
  echo "Error: Invalid parameter."
  echo "Valid options:"
  echo "  --start-scenario              build and start all containers"
  echo "  --stop-scenario               stop and remove all containers"
  echo "  --open <node>                 open a shell in a container"
  echo "  --start-rip                   start RIP on all routers"
  echo "  --stop-rip                    stop RIP on all routers"
  echo "  --start-ospf                  start OSPF on all routers"
  echo "  --stop-ospf                   stop OSPF on all routers"
  echo "  --attack <nombre> <acción>    gestionar ataques desde john"
  echo "    nombres: rip spoof mitm flood dns proxy all"
  echo "    acciones: start stop status"
  exit 1
  ;;
esac
