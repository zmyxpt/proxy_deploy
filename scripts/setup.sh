#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

readonly PROJECT_NAME="proxy_deploy"
readonly PROJECT_DIR="$HOME/${PROJECT_NAME}-main"
readonly COMPOSE_FILE="$PROJECT_DIR/compose.yaml"
readonly REPO_ZIP_URL="https://github.com/zmyxpt/${PROJECT_NAME}/archive/refs/heads/main.zip"
readonly TEMPLATE_DIR="$PROJECT_DIR/templates"
readonly DEPLOY_CONFIG_FILE="$PROJECT_DIR/deploy.conf"

declare DOMAIN EMAIL PROXY_PASSWORD
declare SS_DIRECT_PATH SS_WARP_PATH
declare GOST_DIRECT_PATH GOST_WARP_PATH

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
    apt-get install -y --no-install-recommends bash-completion ca-certificates cronie curl docker.io docker-buildx docker-cli docker-compose perl rsync tzdata unzip
    apt-get autoremove --purge -y
    systemctl enable --now cronie.service
}

download_project()
{
    local staging_dir
    staging_dir="$(mktemp -d)"

    if ! curl -fsSL "$REPO_ZIP_URL" -o "$staging_dir/project.zip"
    then
        rm -rf "$staging_dir"
        echo -e "\033[31mFailed to download ${PROJECT_NAME} resources, exiting...\033[0m"
        exit 15
    fi

    unzip -q "$staging_dir/project.zip" -d "$staging_dir"
    mkdir -p "$PROJECT_DIR"
    rsync -a --delete \
        --exclude /deploy.conf \
        --exclude /data/ \
        --exclude /client-configs/ \
        "$staging_dir/${PROJECT_NAME}-main/" "$PROJECT_DIR/"
    rm -rf "$staging_dir"
}

random_value()
{
    local byte_count="$1"

    dd if=/dev/urandom bs="$byte_count" count=1 status=none |
        base64 |
        tr '+/' '_-' |
        tr -d '=\n'
}

read_domain()
{
    local value

    while true
    do
        read -r -p $'Set your domain, e.g. \033[1mwww.example.com\033[0m\n' value
        if [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && "$value" != *..* ]]
        then
            DOMAIN="$value"
            return
        fi
        echo -e "\033[31mInvalid domain.\033[0m"
    done
}

read_email()
{
    local value

    while true
    do
        read -r -p $'Set your email for TLS certificate notices, e.g. \033[1mabc@gmail.com\033[0m\n' value
        if [[ "$value" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
        then
            EMAIL="$value"
            return
        fi
        echo -e "\033[31mInvalid email.\033[0m"
    done
}

create_deploy_config()
{
    if [[ -f "$DEPLOY_CONFIG_FILE" ]]
    then
        chmod 0600 "$DEPLOY_CONFIG_FILE"
        echo "Using existing ${DEPLOY_CONFIG_FILE}."
        return
    fi

    local choice

    PROXY_PASSWORD="$(random_value 18)"
    SS_DIRECT_PATH="$(random_value 12)"
    SS_WARP_PATH="$(random_value 12)"
    GOST_DIRECT_PATH="$(random_value 12)"
    GOST_WARP_PATH="$(random_value 12)"

    read_domain
    read_email

    while true
    do
        echo 'Here is your setting:'
        echo '=============================='
        echo -e "Domain: \033[32m${DOMAIN}\033[0m"
        echo -e "Email: \033[32m${EMAIL}\033[0m"
        echo '=============================='
        echo "1. Change domain"
        echo "2. Change email"
        echo "0. Confirm and start deployment"

        read -r -p $'Choose an option:\n' choice

        case "$choice" in
        1) read_domain ;;
        2) read_email ;;
        0) break ;;
        *) ;;
        esac
    done

    export DOMAIN EMAIL PROXY_PASSWORD
    export SS_DIRECT_PATH SS_WARP_PATH
    export GOST_DIRECT_PATH GOST_WARP_PATH

    install -m 0600 "$TEMPLATE_DIR/deploy.conf" "$DEPLOY_CONFIG_FILE"
    perl -0pi -e 's/^DOMAIN=$/DOMAIN=$ENV{DOMAIN}/m; s/^EMAIL=$/EMAIL=$ENV{EMAIL}/m; s/^PROXY_PASSWORD=$/PROXY_PASSWORD=$ENV{PROXY_PASSWORD}/m; s/^SS_DIRECT_PATH=$/SS_DIRECT_PATH=$ENV{SS_DIRECT_PATH}/m; s/^SS_WARP_PATH=$/SS_WARP_PATH=$ENV{SS_WARP_PATH}/m; s/^GOST_DIRECT_PATH=$/GOST_DIRECT_PATH=$ENV{GOST_DIRECT_PATH}/m; s/^GOST_WARP_PATH=$/GOST_WARP_PATH=$ENV{GOST_WARP_PATH}/m' "$DEPLOY_CONFIG_FILE"
}

deploy_services()
{
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --quiet
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull --ignore-buildable
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" build --no-cache --pull
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d
}

install_update_cron()
{
    cat > /etc/cron.d/proxy_deploy_update <<EOF
CRON_TZ=UTC
0 19 * * 1 root bash "$PROJECT_DIR/scripts/update.sh"
EOF
    chmod 0644 /etc/cron.d/proxy_deploy_update
}

print_completion_message()
{
    echo
    echo 'Installation completed!'
    echo "Client config files can be found in ${PROJECT_DIR}/client-configs/"
    echo
    echo 'These configuration files are for shadowsocks-rust + v2ray-plugin and gost.'
    echo 'You may need to edit them to match your own client setup.'
    echo
}

main()
{
    check_if_running_as_root
    check_os_version
    install_packages
    download_project

    create_deploy_config
    bash "$PROJECT_DIR/scripts/render-configs.sh"
    deploy_services
    install_update_cron
    print_completion_message
}

main
