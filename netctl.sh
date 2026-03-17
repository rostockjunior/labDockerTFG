#!/bin/bash

# Get the current working directory
current=$(pwd)

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed."
    exit 1
fi

services=$(docker compose ps --services)

# Check the first parameter
case "$1" in
    --start-scenario)
        echo "Starting scenario..."
        # Use docker compose as a subcommand
        docker compose up -d --build
        ;;
    
    --stop-scenario)
        echo "Stopping scenario..."
        # Use docker compose as a subcommand
        docker compose down --volumes --remove-orphans
        ;;
    
    --open)
        # Ensure the node name is provided
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
            echo "Stoping RIP for $service ..."
    	    docker compose exec -T "$service" /bin/sh -c "/usr/local/bin/net-config/dynamic-routing.sh --stop rip"
          fi
        done
	;;
    --stop-ospf)
	for service in $services; do
	  if [[ "$service" == *router* ]]; then
            echo "Stoping OSPF for $service ..."
    	    docker compose exec -T "$service" /bin/sh -c "/usr/local/bin/net-config/dynamic-routing.sh --stop ospf"
          fi
        done
	;;

    --remove-link)
	;;
    *)
        echo "Error: Invalid parameter. Valid options are --start-scenario, --stop-scenario, --open <nodeName>, --run <nodeName> <script> <arguments>"
        exit 1
        ;;
esac
