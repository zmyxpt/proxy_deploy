#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail #-o xtrace

PROJECT_NAME="ss_deploy"
REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
VOLUME_DIR="Volumes"
TEMPLATE_DIR="templates"
CADDY_CONF_DIR="${VOLUME_DIR}/caddyconf"
CADDY_DATA_DIR="${VOLUME_DIR}/caddydata"
SS_DIRECT_DIR="${VOLUME_DIR}/shadowsocks-direct"
SS_WARP_DIR="${VOLUME_DIR}/shadowsocks-warp"
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
    mkdir -p "$SS_DIRECT_DIR"
    mkdir -p "$SS_WARP_DIR"
    mkdir -p "$CADDY_CONF_DIR"
    mkdir -p "$CADDY_DATA_DIR"
    mkdir -p "$WARP_DIR"

    local domain email ss_direct_path ss_direct_password ss_warp_path ss_warp_password
    read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' domain
    read -r -p $'Set your email to receive TLS certificate notice, e.g. \033[1mabc@gmail.com\033[0m\n' email
    read -r -p $'Set your shadowsocks direct path, e.g. \033[1m/direct\033[0m\n' ss_direct_path
    read -r -p $'Set your shadowsocks direct password, e.g. \033[1mpass1234\033[0m\n' ss_direct_password
    read -r -p $'Set your shadowsocks WARP path, e.g. \033[1m/warp\033[0m\n' ss_warp_path
    read -r -p $'Set your shadowsocks WARP password, e.g. \033[1mpass5678\033[0m\n' ss_warp_password

    local finish=false
    until "$finish"
    do
        echo $'Here is your setting:\n=============================='
        echo -e "Domain: \033[32m${domain}\033[0m"
        echo -e "Email: \033[32m${email}\033[0m"
        echo -e "Direct path: \033[32m${ss_direct_path}\033[0m"
        echo -e "Direct password: \033[32m${ss_direct_password}\033[0m"
        echo -e "WARP path: \033[32m${ss_warp_path}\033[0m"
        echo -e "WARP password: \033[32m${ss_warp_password}\033[0m"
        echo $'===============================\nYou can:'
        echo "1. Reset domain"
        echo "2. Reset email"
        echo "3. Reset shadowsocks direct path"
        echo "4. Reset shadowsocks direct password"
        echo "5. Reset shadowsocks WARP path"
        echo "6. Reset shadowsocks WARP password"
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
            read -r -p $'Set your shadowsocks direct path, e.g. \033[1m/direct\033[0m\n' ss_direct_path
            ;;
        4)
            read -r -p $'Set your shadowsocks direct password, e.g. \033[1mpass1234\033[0m\n' ss_direct_password
            ;;
        5)
            read -r -p $'Set your shadowsocks WARP path, e.g. \033[1m/warp\033[0m\n' ss_warp_path
            ;;
        6)
            read -r -p $'Set your shadowsocks WARP password, e.g. \033[1mpass5678\033[0m\n' ss_warp_password
            ;;
        0)
            finish=true
            ;;
        *) ;;
        esac
    done

    cp "$TEMPLATE_DIR/shadowsocks-direct.json" "$SS_DIRECT_DIR/config.json"
    cp "$TEMPLATE_DIR/shadowsocks-warp.json" "$SS_WARP_DIR/config.json"
    cp "$TEMPLATE_DIR/Caddyfile" "$CADDY_CONF_DIR/Caddyfile"

    ss_direct_path="/${ss_direct_path#/}"
    ss_warp_path="/${ss_warp_path#/}"
    export DOMAIN="$domain"
    export EMAIL="$email"
    export SS_DIRECT_PATH="${ss_direct_path:1}"
    export SS_DIRECT_PASSWORD="$ss_direct_password"
    export SS_WARP_PATH="${ss_warp_path:1}"
    export SS_WARP_PASSWORD="$ss_warp_password"

    perl -0pi -e 's/domain/$ENV{DOMAIN}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/email/$ENV{EMAIL}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/ss_direct_path/$ENV{SS_DIRECT_PATH}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/ss_direct_password/$ENV{SS_DIRECT_PASSWORD}/g' "$SS_DIRECT_DIR/config.json"
    perl -0pi -e 's/ss_warp_path/$ENV{SS_WARP_PATH}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/ss_warp_password/$ENV{SS_WARP_PASSWORD}/g' "$SS_WARP_DIR/config.json"
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
        crontab -l 2>/dev/null | grep -v 'ss_deploy-main/auto-update.sh' || true
        echo '0 19 * * 1 bash "$HOME"/ss_deploy-main/auto-update.sh >> "$HOME"/ss_deploy-main/auto-update.log 2>&1'
    ) | crontab -
}

client_configure_help()
{
    echo -e "=================================================="
    echo -e "\n  Deploy finished!"
    echo -e "\n  On client side, install \033[33mshadowsocks\033[0m and \033[33mv2ray plugin\033[0m, then edit config json:"
    echo -e "\n   \"server\" should be \033[3;33m\"your_domain\"\033[0m"
    echo -e "   \"server_port\" should be \033[33m443\033[0m"
    echo -e "   \"password\" should be \033[3;33m\"your_ss_direct_or_ss_warp_password\"\033[0m"
    echo -e "   \"method\" should be \033[33m\"aes-256-gcm\"\033[0m"
    echo -e "   \"plugin\" should be the path you run v2ray plugin from within shadowsocks workdir"
    echo -e "   Direct \"plugin_opts\" should be \033[33m\"tls;host=\033[3myour_domain\033[0;33m;path=\033[3myour_ss_direct_path\033[33m\"\033[0m"
    echo -e "   WARP \"plugin_opts\" should be \033[33m\"tls;host=\033[3myour_domain\033[0;33m;path=\033[3myour_ss_warp_path\033[33m\"\033[0m"
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
