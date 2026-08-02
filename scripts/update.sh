#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

export DEBIAN_FRONTEND=noninteractive

readonly PROJECT_NAME="proxy_deploy"
readonly PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
readonly COMPOSE_FILE="$PROJECT_DIR/compose.yaml"
readonly REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
readonly LOCK_FILE="/run/${PROJECT_NAME}_update.lock"

if [[ $UID -ne 0 ]]
then
    echo "update.sh must run as root."
    exit 31
fi

exec {LOCK_FD}>"$LOCK_FILE"
readonly LOCK_FD

if ! flock -n "$LOCK_FD"
then
    echo "Another update is already running."
    exit 0
fi

apt-get update
apt-get upgrade --with-new-pkgs -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get clean
apt-get autoremove --purge -y

STAGING_DIR="$(mktemp -d)"
readonly STAGING_DIR
trap 'rm -rf "$STAGING_DIR"' EXIT

curl -fsSL "$REPO_ZIP_URL" -o "$STAGING_DIR/project.zip"
unzip -q "$STAGING_DIR/project.zip" -d "$STAGING_DIR"
rsync -a --delete \
    --exclude /deploy.conf \
    --exclude /data/ \
    --exclude /client-configs/ \
    "$STAGING_DIR/${PROJECT_NAME}-main/" "$PROJECT_DIR/"

bash "$PROJECT_DIR/scripts/render-configs.sh"
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --quiet
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull --ignore-buildable || true
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" build --no-cache --pull || true
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d

docker builder prune -af
docker system prune -af
docker volume prune -f

journalctl --vacuum-size=200M
systemctl reboot
