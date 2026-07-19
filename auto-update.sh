#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail #-o xtrace

export DEBIAN_FRONTEND=noninteractive
PROJECT_NAME="proxy_deploy"
COMPOSE_FILE="docker-compose.yaml"

cd "$HOME/${PROJECT_NAME}-main"

apt-get update
apt-get upgrade --with-new-pkgs -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get clean
apt-get autoremove --purge -y

docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull --ignore-buildable || true
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" build --no-cache --pull || true
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d

docker builder prune -af
docker system prune -af
docker volume prune -f

journalctl --vacuum-size=200M
systemctl reboot
