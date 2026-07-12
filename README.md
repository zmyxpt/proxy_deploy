# ss_deploy

Deploy two Shadowsocks-over-WebSocket services behind one HTTPS endpoint:

 - direct profile: exits from the VPS network directly
 - WARP profile: exits through Cloudflare WARP

Both client profiles connect to the same domain and port `443`. Caddy separates them by WebSocket path and forwards traffic to the matching Shadowsocks service.

Enable bbr if supported.

# Components

 - [Caddy v2](https://caddyserver.com): TLS certificate and WebSocket reverse proxy
 - [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust): Shadowsocks server
 - [v2ray-plugin](https://github.com/shadowsocks/v2ray-plugin): WebSocket transport
 - Cloudflare WARP: WARP egress for the second Shadowsocks service

# Requirements

1. A VPS running debian trixie.
2. A domain pointing to the VPS public IP.
3. TCP ports `80` and `443` open on the VPS firewall/security group.

# Install

Run as root on the VPS:

```bash
bash <(curl -fsSL 'https://raw.githubusercontent.com/zmyxpt/ss_deploy/main/setup.sh')
```

The script asks for:

 - domain
 - email for TLS certificate notifications
 - direct Shadowsocks WebSocket path
 - WARP Shadowsocks WebSocket path
 - Shadowsocks password

Example values:

```text
domain: www.example.com
direct path: /direct
WARP path: /warp
password: pass1234
```

# Client Profiles

Create two Shadowsocks client profiles if you want both exits.

Common settings:

```text
server: www.example.com
server_port: 443
method: aes-256-gcm
plugin: v2ray-plugin
```

Direct profile:

```text
password: pass1234
plugin_opts: tls;host=www.example.com;path=/direct
```

WARP profile:

```text
password: pass1234
plugin_opts: tls;host=www.example.com;path=/warp
```

# How It Works

External traffic:

```text
client -> https://www.example.com:443
```

Caddy routes by WebSocket path:

```text
/direct -> shadowsocks-direct:9000 -> VPS direct egress
/warp   -> warp:9001               -> Cloudflare WARP egress
```

# Project Layout

 - `setup.sh`: installer and interactive configuration
 - `auto-update.sh`: weekly update task installed by `setup.sh`
 - `docker-compose.yaml`: service topology
 - `docker/`: Dockerfiles and container entrypoints
 - `templates/`: Caddy and Shadowsocks config templates
 - `Volumes/`: generated runtime config and persistent data, created by `setup.sh`

# Container Notes

 - Shadowsocks containers use Arch Linux with `shadowsocks-rust`.
 - The WARP container uses Debian stable with Cloudflare's official apt package source.
 - The WARP container stores registration state in `Volumes/warp`, so it should not need to register again after normal restarts.

# Maintenance

The installer adds a weekly cron job that runs `auto-update.sh`. It updates system packages, rebuilds containers, starts the stack again, prunes unused Docker objects, then reboots the VPS.

Generated configuration and persistent state live under `Volumes/`. Back up this directory before reinstalling or moving the deployment.
