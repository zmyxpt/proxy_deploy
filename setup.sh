#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail #-o xtrace

PROJECT_NAME="proxy_deploy"
REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
VOLUME_DIR="Volumes"
TEMPLATE_DIR="templates"
CADDY_CONF_DIR="${VOLUME_DIR}/caddyconf"
CADDY_DATA_DIR="${VOLUME_DIR}/caddydata"
COMPOSE_FILE="docker-compose.yaml"

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
    apt-get install -y --no-install-recommends aptitude ca-certificates cron curl docker.io docker-buildx docker-cli docker-compose perl unzip
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

configure()
{
    mkdir -p \
        "$CADDY_CONF_DIR" \
        "$CADDY_DATA_DIR" \
        "${VOLUME_DIR}/shadowsocks-direct" \
        "${VOLUME_DIR}/shadowsocks-warp" \
        "${VOLUME_DIR}/gost-direct" \
        "${VOLUME_DIR}/gost-warp" \
        "${VOLUME_DIR}/warp"

    local domain email ss_direct_path ss_warp_path gost_direct_path gost_warp_path
    local ss_password gost_username gost_password choice

    read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' domain
    read -r -p $'Set your email for TLS certificate notices, e.g. \033[1mabc@gmail.com\033[0m\n' email
    read -r -p $'Set the Shadowsocks direct path, e.g. \033[1m/ss-direct\033[0m\n' ss_direct_path
    read -r -p $'Set the Shadowsocks WARP path, e.g. \033[1m/ss-warp\033[0m\n' ss_warp_path
    read -r -p $'Set the Shadowsocks password, e.g. \033[1mpass1234\033[0m\n' ss_password
    read -r -p $'Set the GOST direct path, e.g. \033[1m/gost-direct\033[0m\n' gost_direct_path
    read -r -p $'Set the GOST WARP path, e.g. \033[1m/gost-warp\033[0m\n' gost_warp_path
    read -r -p $'Set the GOST SOCKS5 username, e.g. \033[1muser1234\033[0m\n' gost_username
    read -r -p $'Set the GOST SOCKS5 password, e.g. \033[1mpass1234\033[0m\n' gost_password

    while true
    do
        ss_direct_path="${ss_direct_path#/}"
        ss_warp_path="${ss_warp_path#/}"
        gost_direct_path="${gost_direct_path#/}"
        gost_warp_path="${gost_warp_path#/}"

        echo $'Here is your setting:\n=============================='
        echo -e "Domain: \033[32m${domain}\033[0m"
        echo -e "Email: \033[32m${email}\033[0m"
        echo -e "Shadowsocks direct: \033[32m/${ss_direct_path}\033[0m -> 9000"
        echo -e "Shadowsocks WARP: \033[32m/${ss_warp_path}\033[0m -> 9001"
        echo -e "Shadowsocks password: \033[32m${ss_password}\033[0m"
        echo -e "GOST direct: \033[32m/${gost_direct_path}\033[0m -> 9002"
        echo -e "GOST WARP: \033[32m/${gost_warp_path}\033[0m -> 9003"
        echo -e "GOST username: \033[32m${gost_username}\033[0m"
        echo -e "GOST password: \033[32m${gost_password}\033[0m"

        echo $'=============================='
        echo "1. Change domain"
        echo "2. Change email"
        echo "3. Change Shadowsocks direct path"
        echo "4. Change Shadowsocks WARP path"
        echo "5. Change Shadowsocks password"
        echo "6. Change GOST direct path"
        echo "7. Change GOST WARP path"
        echo "8. Change GOST username"
        echo "9. Change GOST password"
        echo "0. Confirm and start deployment"

        read -r -p $'Choose an option:\n' choice

        case "$choice" in
        1)
            read -r -p $'Set your domain:\n' domain
            ;;
        2)
            read -r -p $'Set your email:\n' email
            ;;
        3)
            read -r -p $'Set the Shadowsocks direct path:\n' ss_direct_path
            ;;
        4)
            read -r -p $'Set the Shadowsocks WARP path:\n' ss_warp_path
            ;;
        5)
            read -r -p $'Set the Shadowsocks password:\n' ss_password
            ;;
        6)
            read -r -p $'Set the GOST direct path:\n' gost_direct_path
            ;;
        7)
            read -r -p $'Set the GOST WARP path:\n' gost_warp_path
            ;;
        8)
            read -r -p $'Set the GOST username:\n' gost_username
            ;;
        9)
            read -r -p $'Set the GOST password:\n' gost_password
            ;;
        0)
            if [[ -z "$ss_direct_path" || -z "$ss_warp_path" ||
                  -z "$gost_direct_path" || -z "$gost_warp_path" ]]
            then
                echo -e "\033[31mWebSocket paths cannot be empty.\033[0m"
                continue
            fi

            if printf '%s\n' "$ss_direct_path" "$ss_warp_path" \
                "$gost_direct_path" "$gost_warp_path" |
                sort | uniq -d | grep -q .
            then
                echo -e "\033[31mAll four WebSocket paths must be different.\033[0m"
                continue
            fi

            break
            ;;
        *) ;;
        esac
    done

    export DOMAIN="$domain" EMAIL="$email"
    export SS_DIRECT_PATH="$ss_direct_path" SS_WARP_PATH="$ss_warp_path"
    export GOST_DIRECT_PATH="$gost_direct_path" GOST_WARP_PATH="$gost_warp_path"
    export SS_PASSWORD="$ss_password" GOST_USERNAME="$gost_username" GOST_PASSWORD="$gost_password"

    cp "$TEMPLATE_DIR/Caddyfile" "$CADDY_CONF_DIR/Caddyfile"
    cp "$TEMPLATE_DIR/shadowsocks-direct.json" "${VOLUME_DIR}/shadowsocks-direct/config.json"
    cp "$TEMPLATE_DIR/shadowsocks-warp.json" "${VOLUME_DIR}/shadowsocks-warp/config.json"
    cp "$TEMPLATE_DIR/gost-direct.yaml" "${VOLUME_DIR}/gost-direct/gost.yaml"
    cp "$TEMPLATE_DIR/gost-warp.yaml" "${VOLUME_DIR}/gost-warp/gost.yaml"

    perl -0pi -e 's/__DOMAIN__/$ENV{DOMAIN}/g; s/__EMAIL__/$ENV{EMAIL}/g; s/__SS_DIRECT_PATH__/$ENV{SS_DIRECT_PATH}/g; s/__SS_WARP_PATH__/$ENV{SS_WARP_PATH}/g; s/__GOST_DIRECT_PATH__/$ENV{GOST_DIRECT_PATH}/g; s/__GOST_WARP_PATH__/$ENV{GOST_WARP_PATH}/g' "$CADDY_CONF_DIR/Caddyfile"
    perl -0pi -e 's/__SS_PASSWORD__/$ENV{SS_PASSWORD}/g' "${VOLUME_DIR}/shadowsocks-direct/config.json" "${VOLUME_DIR}/shadowsocks-warp/config.json"
    perl -0pi -e 's/__SOCKS_USERNAME__/$ENV{GOST_USERNAME}/g; s/__SOCKS_PASSWORD__/$ENV{GOST_PASSWORD}/g' "${VOLUME_DIR}/gost-direct/gost.yaml" "${VOLUME_DIR}/gost-warp/gost.yaml"
}

run_server()
{
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull --ignore-buildable
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" build --no-cache --pull
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d
}

auto_update_cron()
{
    timedatectl set-timezone Etc/UTC
    systemctl restart cron.service

    (
        crontab -l 2>/dev/null | grep -Ev 'proxy_deploy-main/auto-update.sh' || true
        echo '0 19 * * 1 bash "$HOME"/proxy_deploy-main/auto-update.sh >> "$HOME"/proxy_deploy-main/auto-update.log 2>&1'
    ) | crontab -
}

client_configure_help()
{
    echo -e "=================================================="
    echo -e "\n  Shadowsocks and GOST were deployed together."
    echo -e "  Shadowsocks listens internally on ports 9000 and 9001."
    echo -e "  GOST listens internally on ports 9002 and 9003."
    echo -e "  All clients connect to your domain on HTTPS port 443 using their configured WebSocket path."
    echo -e "\n=================================================="
}

main()
{
    local old_PWD=$PWD

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
