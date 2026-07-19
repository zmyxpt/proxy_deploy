#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

PROJECT_NAME="proxy_deploy"
REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
VOLUME_DIR="Volumes"
TEMPLATE_DIR="templates"
CADDY_CONF_DIR="${VOLUME_DIR}/caddyconf"
CADDY_DATA_DIR="${VOLUME_DIR}/caddydata"
WARP_DIR="${VOLUME_DIR}/warp"
PROXY_TYPE=""

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

enable_bbr()
{
    modprobe tcp_bbr 2>/dev/null || true

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
    then
        echo "BBR is not supported by the current kernel, skipping."
        return 0
    fi

    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p /etc/sysctl.d/99-bbr.conf
}

install_packages()
{
    apt-get update
    apt-get upgrade --with-new-pkgs -y
    apt-get install -y --no-install-recommends aptitude ca-certificates cron curl docker.io docker-buildx docker-cli docker-compose lsof perl unzip
    aptitude search ~pstandard ~prequired ~pimportant -F%p | xargs apt-get install -y --no-install-recommends
    apt-get autoremove --purge -y
}

download_res()
{
    if ! curl -fsSL "$REPO_ZIP_URL" -o "${PROJECT_NAME}.zip"
    then
        echo -e "\033[31mFailed to download ${PROJECT_NAME} resources, exiting...\033[0m"
        exit 15
    fi

    unzip -o "${PROJECT_NAME}.zip"
    rm "${PROJECT_NAME}.zip"
}

select_proxy()
{
    while true
    do
        echo "Choose the proxy server to deploy:"
        echo "1. Shadowsocks with v2ray-plugin"
        echo "2. GOST SOCKS5 over WebSocket"
        read -r -p $'Choose an option by number:\n' choice
        case "$choice" in
        1) PROXY_TYPE="shadowsocks"; return ;;
        2) PROXY_TYPE="gost"; return ;;
        *) echo "Invalid option." ;;
        esac
    done
}

configure()
{
    mkdir -p "$CADDY_CONF_DIR" "$CADDY_DATA_DIR" "$WARP_DIR"

    local domain email direct_path warp_path password username=""
    while true
    do
        read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' domain
        read -r -p $'Set your email for TLS certificate notices, e.g. \033[1mabc@gmail.com\033[0m\n' email
        read -r -p $'Set the direct WebSocket path, e.g. \033[1m/direct\033[0m\n' direct_path
        read -r -p $'Set the WARP WebSocket path, e.g. \033[1m/warp\033[0m\n' warp_path

        if [[ "$PROXY_TYPE" == "shadowsocks" ]]
        then
            read -r -p $'Set the Shadowsocks password, e.g. \033[1mpass1234\033[0m\n' password
        else
            read -r -p $'Set the SOCKS5 username, e.g. \033[1muser1234\033[0m\n' username
            read -r -p $'Set the SOCKS5 password, e.g. \033[1mpass1234\033[0m\n' password
        fi

        echo $'Here is your setting:\n=============================='
        echo -e "Proxy: \033[32m${PROXY_TYPE}\033[0m"
        echo -e "Domain: \033[32m${domain}\033[0m"
        echo -e "Email: \033[32m${email}\033[0m"
        echo -e "Direct path: \033[32m/${direct_path#/}\033[0m"
        echo -e "WARP path: \033[32m/${warp_path#/}\033[0m"
        [[ -z "$username" ]] || echo -e "Username: \033[32m${username}\033[0m"
        echo -e "Password: \033[32m${password}\033[0m"
        read -r -p $'Continue? [y/N]\n' confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && break
    done

    direct_path="${direct_path#/}"
    warp_path="${warp_path#/}"
    export DOMAIN="$domain" EMAIL="$email" DIRECT_PATH="$direct_path" WARP_PATH="$warp_path"
    export PROXY_PASSWORD="$password" PROXY_USERNAME="$username"

    cp "$TEMPLATE_DIR/docker-compose.${PROXY_TYPE}.yaml" docker-compose.yaml
    cp "$TEMPLATE_DIR/Caddyfile.${PROXY_TYPE}" "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g; s/__EMAIL__/$ENV{EMAIL}/g; s/__DIRECT_PATH__/$ENV{DIRECT_PATH}/g; s/__WARP_PATH__/$ENV{WARP_PATH}/g' "$CADDY_CONF_DIR/Caddyfile"

    if [[ "$PROXY_TYPE" == "shadowsocks" ]]
    then
        mkdir -p "${VOLUME_DIR}/shadowsocks-direct" "${VOLUME_DIR}/shadowsocks-warp"
        cp "$TEMPLATE_DIR/shadowsocks-direct.json" "${VOLUME_DIR}/shadowsocks-direct/config.json"
        cp "$TEMPLATE_DIR/shadowsocks-warp.json" "${VOLUME_DIR}/shadowsocks-warp/config.json"
        perl -0pi -e 's/__SS_PASSWORD__/$ENV{PROXY_PASSWORD}/g' "${VOLUME_DIR}/shadowsocks-direct/config.json" "${VOLUME_DIR}/shadowsocks-warp/config.json"
    else
        mkdir -p "${VOLUME_DIR}/gost"
        cp "$TEMPLATE_DIR/gost.yaml" "${VOLUME_DIR}/gost/gost.yaml"
        perl -0pi -e 's/__SOCKS_USERNAME__/$ENV{PROXY_USERNAME}/g; s/__SOCKS_PASSWORD__/$ENV{PROXY_PASSWORD}/g' "${VOLUME_DIR}/gost/gost.yaml"
    fi

    printf '%s\n' "$PROXY_TYPE" > "${VOLUME_DIR}/proxy-type"
}

run_server()
{
    docker compose down --remove-orphans
    docker compose pull --ignore-buildable
    docker compose build --no-cache --pull
    docker compose up -d
}

auto_update_cron()
{
    timedatectl set-timezone Etc/UTC
    systemctl restart cron.service

    (
        crontab -l 2>/dev/null | grep -Ev '(ss_deploy|gost_deploy|proxy_deploy)-main/auto-update.sh' || true
        echo '0 19 * * 1 bash "$HOME"/proxy_deploy-main/auto-update.sh >> "$HOME"/proxy_deploy-main/auto-update.log 2>&1'
    ) | crontab -
}

client_configure_help()
{
    echo -e "=================================================="
    echo -e "\n  Deploy finished: \033[33m${PROXY_TYPE}\033[0m"
    if [[ "$PROXY_TYPE" == "shadowsocks" ]]
    then
        echo -e "\n  Create direct and WARP Shadowsocks profiles using port 443, aes-256-gcm, and v2ray-plugin."
        echo -e "  Plugin options: tls;host=your_domain;path=/your_path"
    else
        echo -e "\n  Example GOST client tunnel:"
        echo -e "  gost -L auto://127.0.0.1:1080 -F 'socks5+wss://user:password@your_domain:443?path=/your_path'"
    fi
    echo -e "\n=================================================="
}

main()
{
    local old_PWD=$PWD
    check_if_running_as_root
    check_os_version
    select_proxy
    enable_bbr
    install_packages

    cd "$HOME"
    download_res
    cd "$PROJECT_DIR"
    configure
    run_server
    auto_update_cron
    client_configure_help
    cd "$old_PWD"
}

main
