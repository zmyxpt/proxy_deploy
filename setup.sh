#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail #-o xtrace

PROJECT_NAME="proxy_deploy"
REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
COMPOSE_FILE="docker-compose.yaml"
TEMPLATE_DIR="templates"
CLIENT_DIR="client"
VOLUME_DIR="volumes"

check_if_running_as_root()
{
    if [[ $UID -ne 0 ]]
    then
        echo -e "\033[31mNot running as root, exiting...\033[0m"
        exit 11
    fi
}

check_os_version()
{
    if [[ -r /etc/os-release ]]
    then
        . /etc/os-release
    else
        echo -e "\033[31mCannot detect Linux distro!\033[0m"
        exit 12
    fi

    if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]
    then
        echo -e "\033[31mUnsupported Linux distro! Debian trixie is required.\033[0m"
        exit 13
    fi
}

install_packages()
{
    apt-get update
    apt-get upgrade --with-new-pkgs -y
    apt-get install -y --no-install-recommends bash-completion ca-certificates cronie curl docker.io docker-buildx docker-cli docker-compose perl tzdata unzip
    apt-get autoremove --purge -y
    systemctl enable --now cronie.service
}

download_project()
{
    if ! curl -fsSL "$REPO_ZIP_URL" -o "${PROJECT_NAME}.zip"
    then
        echo -e "\033[31mFailed to download ${PROJECT_NAME} resources, exiting...\033[0m"
        exit 15
    fi

    unzip -o "${PROJECT_NAME}.zip"
    rm "${PROJECT_NAME}.zip"
}

random_value()
{
    local byte_count="$1"

    dd if=/dev/urandom bs="$byte_count" count=1 status=none |
        base64 |
        tr '+/' '_-' |
        tr -d '=\n'
}

generate_configs()
{
    mkdir -p \
        "${VOLUME_DIR}/caddy-conf" \
        "${VOLUME_DIR}/caddy-data" \
        "${VOLUME_DIR}/shadowsocks-direct" \
        "${VOLUME_DIR}/shadowsocks-warp" \
        "${VOLUME_DIR}/gost-direct" \
        "${VOLUME_DIR}/gost-warp" \
        "${VOLUME_DIR}/cloudflare-warp" \
        "$CLIENT_DIR"

    local domain email proxy_password choice
    local ss_direct_path ss_warp_path gost_direct_path gost_warp_path

    proxy_password="$(random_value 12)"
    ss_direct_path="$(random_value 9)"
    ss_warp_path="$(random_value 9)"
    gost_direct_path="$(random_value 9)"
    gost_warp_path="$(random_value 9)"

    read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' domain
    read -r -p $'Set your email for TLS certificate notices, e.g. \033[1mabc@gmail.com\033[0m\n' email

    while true
    do
        echo 'Here is your setting:'
        echo '=============================='
        echo -e "Domain: \033[32m${domain}\033[0m"
        echo -e "Email: \033[32m${email}\033[0m"
        echo '=============================='
        echo "1. Change domain"
        echo "2. Change email"
        echo "0. Confirm and start deployment"

        read -r -p $'Choose an option:\n' choice

        case "$choice" in
        1)
            read -r -p $'Set your domain:\n' domain
            ;;
        2)
            read -r -p $'Set your email:\n' email
            ;;
        0)
            break
            ;;
        *) ;;
        esac
    done

    export DOMAIN="$domain" EMAIL="$email"
    export SS_DIRECT_PATH="$ss_direct_path" SS_WARP_PATH="$ss_warp_path"
    export GOST_DIRECT_PATH="$gost_direct_path" GOST_WARP_PATH="$gost_warp_path"
    export PROXY_PASSWORD="$proxy_password"

    cp "$TEMPLATE_DIR/Caddyfile" "${VOLUME_DIR}/caddy-conf/Caddyfile"
    cp "$TEMPLATE_DIR/shadowsocks-rust-server.json" "${VOLUME_DIR}/shadowsocks-direct/config.json"
    cp "$TEMPLATE_DIR/shadowsocks-rust-server.json" "${VOLUME_DIR}/shadowsocks-warp/config.json"
    cp "$TEMPLATE_DIR/gost-server.yaml" "${VOLUME_DIR}/gost-direct/gost.yaml"
    cp "$TEMPLATE_DIR/gost-server.yaml" "${VOLUME_DIR}/gost-warp/gost.yaml"

    cp "$TEMPLATE_DIR/shadowsocks-rust-client.json" "$CLIENT_DIR/ssrust_direct.json"
    cp "$TEMPLATE_DIR/shadowsocks-rust-client.json" "$CLIENT_DIR/ssrust_warp.json"
    cp "$TEMPLATE_DIR/gost-client.yaml" "$CLIENT_DIR/gost.yaml"

    perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g; s/__EMAIL__/$ENV{EMAIL}/g; s/__SS_DIRECT_PATH__/$ENV{SS_DIRECT_PATH}/g; s/__SS_WARP_PATH__/$ENV{SS_WARP_PATH}/g; s/__GOST_DIRECT_PATH__/$ENV{GOST_DIRECT_PATH}/g; s/__GOST_WARP_PATH__/$ENV{GOST_WARP_PATH}/g' "${VOLUME_DIR}/caddy-conf/Caddyfile"

    perl -0pi -e 's/__SERVER_PORT__/9000/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "${VOLUME_DIR}/shadowsocks-direct/config.json"
    perl -0pi -e 's/__SERVER_PORT__/9001/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "${VOLUME_DIR}/shadowsocks-warp/config.json"
    perl -0pi -e 's/__SERVICE_NAME__/direct/g; s/__SERVER_PORT__/9002/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "${VOLUME_DIR}/gost-direct/gost.yaml"
    perl -0pi -e 's/__SERVICE_NAME__/warp/g; s/__SERVER_PORT__/9003/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g' "${VOLUME_DIR}/gost-warp/gost.yaml"

    perl -0pi -e 's/__LOCAL_PORT__/1080/g; s/__DOMAIN__/$ENV{DOMAIN}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g; s/__PATH__/$ENV{SS_DIRECT_PATH}/g' "$CLIENT_DIR/ssrust_direct.json"
    perl -0pi -e 's/__LOCAL_PORT__/1081/g; s/__DOMAIN__/$ENV{DOMAIN}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g; s/__PATH__/$ENV{SS_WARP_PATH}/g' "$CLIENT_DIR/ssrust_warp.json"
    perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g; s/__PASSWORD__/$ENV{PROXY_PASSWORD}/g; s/__GOST_DIRECT_PATH__/$ENV{GOST_DIRECT_PATH}/g; s/__GOST_WARP_PATH__/$ENV{GOST_WARP_PATH}/g' "$CLIENT_DIR/gost.yaml"
}

deploy_services()
{
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull --ignore-buildable
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" build --no-cache --pull
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d
}

install_update_cron()
{
    cat > /etc/cron.d/proxy_deploy_update <<'EOF'
CRON_TZ=UTC
0 19 * * 1 root bash "$HOME"/proxy_deploy-main/update.sh >> "$HOME"/proxy_deploy-main/update.log 2>&1
EOF
    chmod 0644 /etc/cron.d/proxy_deploy_update
}

print_completion_message()
{
    echo
    echo 'Installation completed!'
    echo 'Client config files can be found in ~/proxy_deploy-main/client/'
    echo
    echo 'These configuration files are for shadowsocks-rust + v2ray-plugin and gost'
    echo 'You may need to edit them to match your own client setup.'
    echo
}

main()
{
    local old_PWD=$PWD

    check_if_running_as_root
    check_os_version
    install_packages

    cd "$HOME"
    download_project

    cd "$PROJECT_DIR"
    generate_configs
    deploy_services
    install_update_cron
    print_completion_message

    cd "$old_PWD"
}

main
