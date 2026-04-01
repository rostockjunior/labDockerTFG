#!/bin/sh
set -ex

# Setup networking
ip route flush table main

# Configure network routes
ip route add 192.168.4.128/26 dev eth0 scope link src 192.168.4.131
ip route add default via 192.168.4.129 dev eth0

# Setup mariadb (MySQL compatible)
apk add --no-cache mariadb mariadb-client
if [ ! -d /var/lib/mysql/mysql ]; then
  mysql_install_db --user=mysql --datadir=/var/lib/mysql
fi

# Start mariadb in the background
mysqld_safe --user=mysql &

echo "Waiting for MariaDB to start..."
until mysqladmin ping --silent; do
  sleep 1
done

# Run the init script to create database and user
mysql </scripts/mysql/init.sql

echo "MariaDB is ready"

# Execute CMD arguments
exec /bin/sh
