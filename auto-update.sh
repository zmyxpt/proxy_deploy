#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

export DEBIAN_FRONTEND=noninteractive
PROJECT_NAME="proxy_deploy"

cd "$HOME/${PROJECT_NAME}-main"

apt-get update
apt-get upgrade --with-new-pkgs -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get clean
apt-get autoremove --purge -y

docker compose down
docker compose pull --ignore-buildable || true
docker compose build --no-cache --pull || true
docker compose up -d

docker builder prune -af
docker system prune -af
docker volume prune -f

journalctl --vacuum-size=200M
systemctl reboot
