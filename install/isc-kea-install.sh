#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck
# Author: community-scripts
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://kea.readthedocs.io/en/kea-3.0.0/arm/quickstart.html

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Kea 3.0 and PostgreSQL"
$STD apt-get install -y postgresql postgresql-contrib jq curl >/dev/null
# Assume meta-package availability on Debian 13
$STD apt-get install -y isc-kea isc-kea-ctrl-agent isc-kea-admin >/dev/null
msg_ok "Installed Kea and PostgreSQL"

# Configure PostgreSQL DB and user for Kea
msg_info "Configuring PostgreSQL for Kea"
PG_SVC=postgresql
systemctl enable -q --now ${PG_SVC}
KEA_DB_NAME="kea"
KEA_DB_USER="keauser"
KEA_DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${KEA_DB_NAME}') THEN
      PERFORM dblink_exec('dbname=' || current_database(), '');
   END IF;
END$$;
CREATE ROLE ${KEA_DB_USER} WITH LOGIN PASSWORD '${KEA_DB_PASS}';
CREATE DATABASE ${KEA_DB_NAME} OWNER ${KEA_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${KEA_DB_NAME} TO ${KEA_DB_USER};
EOF

# Initialize Kea DB schema
kea-admin db-init pgsql -u ${KEA_DB_USER} -p ${KEA_DB_PASS} -n ${KEA_DB_NAME} -h 127.0.0.1 -P 5432 >/dev/null
msg_ok "Configured PostgreSQL"

mkdir -p /etc/kea

# Initialize Kea Config Backend schema (for Stork-managed config)
msg_info "Initializing Kea Config Backend schema"
kea-admin db-init pgsql -u ${KEA_DB_USER} -p ${KEA_DB_PASS} -n ${KEA_DB_NAME} -h 127.0.0.1 -P 5432 --config >/dev/null
msg_ok "Initialized Config Backend"

# Prompt or generate API password for ctrl-agent
read -r -p "${TAB3}Enter Kea API password (blank to auto-generate): " KEA_API_PASS
if [[ -z "${KEA_API_PASS}" ]]; then
  KEA_API_PASS="$(openssl rand -base64 24)"
fi
echo -n "${KEA_API_PASS}" >/etc/kea/kea-api-password
chown root:root /etc/kea/kea-api-password
chmod 640 /etc/kea/kea-api-password

# Build kea-dhcp4.conf with PostgreSQL backend and control socket
cat >/etc/kea/kea-dhcp4.conf <<'JSON'
{
  "Dhcp4": {
    "interfaces-config": { "interfaces": [ "eth0" ] },
    "lease-database": {
      "type": "postgresql",
      "name": "kea",
      "user": "keauser",
      "password": "__DB_PASSWORD__",
      "host": "127.0.0.1",
      "port": 5432
    },
    "config-control": {
      "config-databases": [{
        "type": "postgresql",
        "name": "kea",
        "user": "keauser",
        "password": "__DB_PASSWORD__",
        "host": "127.0.0.1",
        "port": 5432
      }],
      "server-tag": "srv1"
    },
    "control-socket": { "socket-type": "unix", "socket-name": "/run/kea/kea4-ctrl-socket" },
    "valid-lifetime": 86400,
    "renew-timer": 3000,
    "rebind-timer": 6000,
    "subnet4": []
  }
}
JSON
sed -i "s/__DB_PASSWORD__/${KEA_DB_PASS}/g" /etc/kea/kea-dhcp4.conf

# Build kea-dhcp6.conf (minimal) using same DB
cat >/etc/kea/kea-dhcp6.conf <<'JSON'
{
  "Dhcp6": {
    "interfaces-config": { "interfaces": [ "eth0" ] },
    "lease-database": {
      "type": "postgresql",
      "name": "kea",
      "user": "keauser",
      "password": "__DB_PASSWORD__",
      "host": "127.0.0.1",
      "port": 5432
    },
    "config-control": {
      "config-databases": [{
        "type": "postgresql",
        "name": "kea",
        "user": "keauser",
        "password": "__DB_PASSWORD__",
        "host": "127.0.0.1",
        "port": 5432
      }],
      "server-tag": "srv1"
    },
    "control-socket": { "socket-type": "unix", "socket-name": "/run/kea/kea6-ctrl-socket" },
    "valid-lifetime": 86400,
    "renew-timer": 3000,
    "rebind-timer": 6000,
    "subnet6": []
  }
}
JSON
sed -i "s/__DB_PASSWORD__/${KEA_DB_PASS}/g" /etc/kea/kea-dhcp6.conf

# Configure kea-ctrl-agent with HTTP basic auth reading password from file
cat >/etc/kea/kea-ctrl-agent.conf <<'JSON'
{
  "Control-agent": {
    "http-host": "127.0.0.1",
    "http-port": 8000,
    "control-sockets": {
      "dhcp4": { "socket-type": "unix", "socket-name": "/run/kea/kea4-ctrl-socket" },
      "dhcp6": { "socket-type": "unix", "socket-name": "/run/kea/kea6-ctrl-socket" }
    },
    "authentication": {
      "type": "basic",
      "realm": "kea-api",
      "users": [
        { "user": "admin", "password": { "type": "file", "value": "/etc/kea/kea-api-password" } }
      ]
    }
  }
}
JSON

systemctl enable -q --now kea-dhcp4-server
systemctl enable -q --now kea-dhcp6-server
systemctl enable -q --now kea-ctrl-agent

msg_ok "Configured Kea DHCP and Ctrl-Agent"

motd_ssh
customize

echo "Kea DB user: ${KEA_DB_USER}" > /root/kea-install.info
echo "Kea DB pass: ${KEA_DB_PASS}" >> /root/kea-install.info
echo "Ctrl-Agent user: admin" >> /root/kea-install.info
echo "Ctrl-Agent password stored at /etc/kea/kea-api-password" >> /root/kea-install.info

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

