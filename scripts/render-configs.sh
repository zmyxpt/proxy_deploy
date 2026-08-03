#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

readonly PROJECT_NAME="proxy_deploy"
readonly PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
readonly DEPLOY_CONFIG_FILE="$PROJECT_DIR/deploy.conf"
readonly TEMPLATE_DIR="$PROJECT_DIR/templates"
readonly CLIENT_CONFIG_DIR="$PROJECT_DIR/client-configs"
readonly DATA_DIR="$PROJECT_DIR/data"

declare -ar REQUIRED_VARIABLES=(
    SS_DIRECT_PORT SS_WARP_PORT GOST_DIRECT_PORT GOST_WARP_PORT
    DOMAIN EMAIL PROXY_PASSWORD
    SS_DIRECT_PATH SS_WARP_PATH GOST_DIRECT_PATH GOST_WARP_PATH
)

if [[ ! -f "$DEPLOY_CONFIG_FILE" ]]
then
    echo "Missing ${DEPLOY_CONFIG_FILE}."
    exit 21
fi

set -o allexport
. "$DEPLOY_CONFIG_FILE"
set +o allexport

for variable in "${REQUIRED_VARIABLES[@]}"
do
    if [[ -z "${!variable:-}" ]]
    then
        echo "Missing ${variable} in deploy.conf."
        exit 22
    fi
done

declare -A seen_ports=()
for variable in SS_DIRECT_PORT SS_WARP_PORT GOST_DIRECT_PORT GOST_WARP_PORT
do
    value="${!variable}"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] ||
        (( 10#$value < 1024 || 10#$value > 65535 ))
    then
        echo "Invalid port: ${variable}=${value}; expected 1024-65535."
        exit 23
    fi

    if [[ -n "${seen_ports[$value]:-}" ]]
    then
        echo "Duplicate port: ${seen_ports[$value]} and ${variable} both use ${value}."
        exit 24
    fi
    seen_ports[$value]="$variable"
done

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$DOMAIN" == *..* ]]
then
    echo "Invalid DOMAIN."
    exit 26
fi

if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
then
    echo "Invalid EMAIL."
    exit 27
fi

for variable in PROXY_PASSWORD SS_DIRECT_PATH SS_WARP_PATH GOST_DIRECT_PATH GOST_WARP_PATH
do
    if [[ ! "${!variable}" =~ ^[A-Za-z0-9_-]+$ ]]
    then
        echo "Invalid characters in ${variable}."
        exit 28
    fi
done

declare -A seen_paths=()
for variable in SS_DIRECT_PATH SS_WARP_PATH GOST_DIRECT_PATH GOST_WARP_PATH
do
    value="${!variable}"
    if [[ -n "${seen_paths[$value]:-}" ]]
    then
        echo "Duplicate WebSocket path: ${value}"
        exit 29
    fi
    seen_paths[$value]=1
done

STAGING_DIR="$(mktemp -d)"
readonly STAGING_DIR
trap 'rm -rf "$STAGING_DIR"' EXIT

cp "$TEMPLATE_DIR/Caddyfile" "$STAGING_DIR/Caddyfile"
cp "$TEMPLATE_DIR/shadowsocks-rust-server.json" "$STAGING_DIR/shadowsocks-rust-server-direct.json"
cp "$TEMPLATE_DIR/shadowsocks-rust-server.json" "$STAGING_DIR/shadowsocks-rust-server-warp.json"
cp "$TEMPLATE_DIR/gost-server.yaml" "$STAGING_DIR/gost-server-direct.yaml"
cp "$TEMPLATE_DIR/gost-server.yaml" "$STAGING_DIR/gost-server-warp.yaml"
cp "$TEMPLATE_DIR/shadowsocks-rust-client.json" "$STAGING_DIR/shadowsocks-rust-client-direct.json"
cp "$TEMPLATE_DIR/shadowsocks-rust-client.json" "$STAGING_DIR/shadowsocks-rust-client-warp.json"
cp "$TEMPLATE_DIR/gost-client.yaml" "$STAGING_DIR/gost-client.yaml"

perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g; s/__EMAIL__/$ENV{EMAIL}/g; s/__SS_DIRECT_PORT__/$ENV{SS_DIRECT_PORT}/g; s/__SS_WARP_PORT__/$ENV{SS_WARP_PORT}/g; s/__GOST_DIRECT_PORT__/$ENV{GOST_DIRECT_PORT}/g; s/__GOST_WARP_PORT__/$ENV{GOST_WARP_PORT}/g; s/__SS_DIRECT_PATH__/$ENV{SS_DIRECT_PATH}/g; s/__SS_WARP_PATH__/$ENV{SS_WARP_PATH}/g; s/__GOST_DIRECT_PATH__/$ENV{GOST_DIRECT_PATH}/g; s/__GOST_WARP_PATH__/$ENV{GOST_WARP_PATH}/g' "$STAGING_DIR/Caddyfile"
perl -0pi -e 's/__SERVER_PORT__/$ENV{SS_DIRECT_PORT}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "$STAGING_DIR/shadowsocks-rust-server-direct.json"
perl -0pi -e 's/__SERVER_PORT__/$ENV{SS_WARP_PORT}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "$STAGING_DIR/shadowsocks-rust-server-warp.json"
perl -0pi -e 's/__SERVICE_NAME__/direct/g; s/__SERVER_PORT__/$ENV{GOST_DIRECT_PORT}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "$STAGING_DIR/gost-server-direct.yaml"
perl -0pi -e 's/__SERVICE_NAME__/warp/g; s/__SERVER_PORT__/$ENV{GOST_WARP_PORT}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "$STAGING_DIR/gost-server-warp.yaml"
perl -0pi -e 's/__LOCAL_PORT__/$ENV{SS_DIRECT_PORT}/g; s/__DOMAIN__/$ENV{DOMAIN}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g; s/__PATH__/$ENV{SS_DIRECT_PATH}/g' "$STAGING_DIR/shadowsocks-rust-client-direct.json"
perl -0pi -e 's/__LOCAL_PORT__/$ENV{SS_WARP_PORT}/g; s/__DOMAIN__/$ENV{DOMAIN}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g; s/__PATH__/$ENV{SS_WARP_PATH}/g' "$STAGING_DIR/shadowsocks-rust-client-warp.json"
perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g; s/__GOST_DIRECT_PORT__/$ENV{GOST_DIRECT_PORT}/g; s/__GOST_WARP_PORT__/$ENV{GOST_WARP_PORT}/g; s/__GOST_DIRECT_PATH__/$ENV{GOST_DIRECT_PATH}/g; s/__GOST_WARP_PATH__/$ENV{GOST_WARP_PATH}/g' "$STAGING_DIR/gost-client.yaml"

mkdir -p "$DATA_DIR/caddy-data" "$DATA_DIR/cloudflare-warp"
install -d -o root -g root -m 0755 "$DATA_DIR/caddy-conf"
install -d -o root -g 65534 -m 0750 "$DATA_DIR/shadowsocks-direct" "$DATA_DIR/shadowsocks-warp" "$DATA_DIR/gost-direct" "$DATA_DIR/gost-warp"
install -d -o root -g root -m 0700 "$CLIENT_CONFIG_DIR"

install -o root -g root -m 0644 "$STAGING_DIR/Caddyfile" "$DATA_DIR/caddy-conf/Caddyfile"
install -o root -g 65534 -m 0640 "$STAGING_DIR/shadowsocks-rust-server-direct.json" "$DATA_DIR/shadowsocks-direct/config.json"
install -o root -g 65534 -m 0640 "$STAGING_DIR/shadowsocks-rust-server-warp.json" "$DATA_DIR/shadowsocks-warp/config.json"
install -o root -g 65534 -m 0640 "$STAGING_DIR/gost-server-direct.yaml" "$DATA_DIR/gost-direct/gost.yaml"
install -o root -g 65534 -m 0640 "$STAGING_DIR/gost-server-warp.yaml" "$DATA_DIR/gost-warp/gost.yaml"
install -o root -g root -m 0600 "$STAGING_DIR/shadowsocks-rust-client-direct.json" "$CLIENT_CONFIG_DIR/ssrust_direct.json"
install -o root -g root -m 0600 "$STAGING_DIR/shadowsocks-rust-client-warp.json" "$CLIENT_CONFIG_DIR/ssrust_warp.json"
install -o root -g root -m 0600 "$STAGING_DIR/gost-client.yaml" "$CLIENT_CONFIG_DIR/gost.yaml"
