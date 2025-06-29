#!/bin/bash
set -eux

apt-get update -y
apt-get install -y docker.io docker-compose

# seed sql
cat > /tmp/seed.sql <<'EOSQL'
${seed_sql_content}
EOSQL

cat > /root/docker-compose.yml <<EOF
version: '3'
services:
  app:
    image: ${DOCKER_IMAGE}
    restart: unless-stopped
    depends_on: [db]
    environment: [PORT=3000]

  db:
    image: postgres:15
    restart: unless-stopped
    environment:
      - POSTGRES_DB=mydb
      - POSTGRES_USER=myuser
      - POSTGRES_PASSWORD=mypassword
    volumes:
      - /tmp/seed.sql:/docker-entrypoint-initdb.d/seed.sql

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: always
    command: tunnel run --token ${TUNNEL_TOKEN}

  watchtower:
    image: containrrr/watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup --interval 1800
EOF

docker compose -f /root/docker-compose.yml up -d