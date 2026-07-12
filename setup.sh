#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail #-o xtrace

PROJECT_NAME="gost_deploy"
REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
VOLUME_DIR="Volumes"
TEMPLATE_DIR="templates"
CADDY_CONF_DIR="${VOLUME_DIR}/caddyconf"
CADDY_DATA_DIR="${VOLUME_DIR}/caddydata"
GOST_DIR="${VOLUME_DIR}/gost"
WARP_DIR="${VOLUME_DIR}/warp"

check_if_running_as_root()
{
    if [[ $UID -ne 0 ]]
    then
        echo -e "\033[31mNot running with root, exiting...\033[0m"
        exit 11
    fi
}

check_os_version()
{
    if [[ -r /etc/os-release ]]
    then
        . /etc/os-release
    else
        echo -e "\033[31mCannot detect linux distro!\033[0m"
        exit 12
    fi

    if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]
    then
        echo -e "\033[31mUnsupported linux distro! Debian trixie is required.\033[0m"
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
        echo -e "\033[31mFail to download ${PROJECT_NAME} resource, exiting...\033[0m"
        exit 15
    fi

    unzip -o "${PROJECT_NAME}.zip"
    rm "${PROJECT_NAME}.zip"
}

configure()
{
    mkdir -p "$GOST_DIR"
    mkdir -p "$CADDY_CONF_DIR"
    mkdir -p "$CADDY_DATA_DIR"
    mkdir -p "$WARP_DIR"

    local domain email gost_direct_path gost_warp_path socks_username socks_password
    read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' domain
    read -r -p $'Set your email to receive TLS certificate notice, e.g. \033[1mabc@gmail.com\033[0m\n' email
    read -r -p $'Set your GOST direct WebSocket path, e.g. \033[1m/direct\033[0m\n' gost_direct_path
    read -r -p $'Set your GOST WARP WebSocket path, e.g. \033[1m/warp\033[0m\n' gost_warp_path
    read -r -p $'Set your SOCKS5 username, e.g. \033[1muser1234\033[0m\n' socks_username
    read -r -p $'Set your SOCKS5 password, e.g. \033[1mpass1234\033[0m\n' socks_password

    local finish=false
    until "$finish"
    do
        echo $'Here is your setting:\n=============================='
        echo -e "Domain: \033[32m${domain}\033[0m"
        echo -e "Email: \033[32m${email}\033[0m"
        echo -e "Direct path: \033[32m${gost_direct_path}\033[0m"
        echo -e "WARP path: \033[32m${gost_warp_path}\033[0m"
        echo -e "SOCKS5 username: \033[32m${socks_username}\033[0m"
        echo -e "SOCKS5 password: \033[32m${socks_password}\033[0m"
        echo $'===============================\nYou can:'
        echo "1. Reset domain"
        echo "2. Reset email"
        echo "3. Reset GOST direct WebSocket path"
        echo "4. Reset GOST WARP WebSocket path"
        echo "5. Reset SOCKS5 username"
        echo "6. Reset SOCKS5 password"
        echo "0. Finish it, start up"
        read -r -p $'Choose an option by number:\n' choice
        case "$choice" in
        1)
            read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' domain
            ;;
        2)
            read -r -p $'Set your email to receive TLS certificate notice, e.g. \033[1mabc@gmail.com\033[0m\n' email
            ;;
        3)
            read -r -p $'Set your GOST direct WebSocket path, e.g. \033[1m/direct\033[0m\n' gost_direct_path
            ;;
        4)
            read -r -p $'Set your GOST WARP WebSocket path, e.g. \033[1m/warp\033[0m\n' gost_warp_path
            ;;
        5)
            read -r -p $'Set your SOCKS5 username, e.g. \033[1muser1234\033[0m\n' socks_username
            ;;
        6)
            read -r -p $'Set your SOCKS5 password, e.g. \033[1mpass1234\033[0m\n' socks_password
            ;;
        0)
            finish=true
            ;;
        *) ;;
        esac
    done

    cp "$TEMPLATE_DIR/gost.yaml" "$GOST_DIR/gost.yaml"
    cp "$TEMPLATE_DIR/Caddyfile" "$CADDY_CONF_DIR/Caddyfile"

    gost_direct_path="/${gost_direct_path#/}"
    gost_warp_path="/${gost_warp_path#/}"
    export DOMAIN="$domain"
    export EMAIL="$email"
    export GOST_DIRECT_PATH="${gost_direct_path:1}"
    export GOST_WARP_PATH="${gost_warp_path:1}"
    export SOCKS_USERNAME="$socks_username"
    export SOCKS_PASSWORD="$socks_password"

    perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/__EMAIL__/$ENV{EMAIL}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/__GOST_DIRECT_PATH__/$ENV{GOST_DIRECT_PATH}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/__GOST_WARP_PATH__/$ENV{GOST_WARP_PATH}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/__SOCKS_USERNAME__/$ENV{SOCKS_USERNAME}/g' "$GOST_DIR/gost.yaml"
    perl -0pi -e 's/__SOCKS_PASSWORD__/$ENV{SOCKS_PASSWORD}/g' "$GOST_DIR/gost.yaml"
}

run_server()
{
    if [[ $(lsof -i :443 | grep 'docker' | grep -v 'grep') != "" ]]
    then
        docker compose down
    fi

    docker compose pull --ignore-buildable
    docker compose build --no-cache --pull
    docker compose up -d
}

auto_update_cron()
{
    timedatectl set-timezone Etc/UTC
    systemctl restart cron.service

    (
        crontab -l 2>/dev/null | grep -v 'gost_deploy-main/auto-update.sh' || true
        echo '0 19 * * 1 bash "$HOME"/gost_deploy-main/auto-update.sh >> "$HOME"/gost_deploy-main/auto-update.log 2>&1'
    ) | crontab -
}

client_configure_help()
{
    echo -e "=================================================="
    echo -e "\n  Deploy finished!"
    echo -e "\n  On client side, install \033[33mGOST\033[0m and create local SOCKS5 tunnels with this command:"
    echo -e "\n   \033[33mgost \\"
    echo -e "       -L auto://127.0.0.1:1080 \\"
    echo -e "       -F 'socks5+wss://\033[3myour_user\033[0;33m:\033[3myour_password\033[0;33m@\033[3myour_domain\033[0;33m:443?path=/\033[3myour_direct_path\033[0;33m' \\"
    echo -e "       -- \\"
    echo -e "       -L auto://127.0.0.1:1081 \\"
    echo -e "       -F 'socks5+wss://\033[3myour_user\033[0;33m:\033[3myour_password\033[0;33m@\033[3myour_domain\033[0;33m:443?path=/\033[3myour_warp_path\033[0;33m'\033[0m"
    echo -e "\n=================================================="
}

main()
{
    local old_PWD
    old_PWD=$PWD

    check_if_running_as_root
    check_os_version
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
