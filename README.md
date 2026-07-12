# gost_deploy

Deploy two authenticated SOCKS5-over-WebSocket services behind one HTTPS endpoint:

 - direct profile: exits from the VPS network directly
 - WARP profile: exits through Cloudflare WARP proxy mode

Both client profiles connect to the same domain and port `443`. Caddy separates them by WebSocket path and forwards traffic to the matching GOST service.

Enable bbr if supported.

# Components

 - [Caddy v2](https://caddyserver.com): TLS certificate and WebSocket reverse proxy
 - [GOST](https://gost.run): SOCKS5 server over WebSocket with username/password authentication
 - Cloudflare WARP: WARP egress for the second GOST service
 - socat: exposes the WARP proxy-mode listener on `0.0.0.0` inside the WARP container

# Requirements

1. A VPS running debian trixie.
2. A domain pointing to the VPS public IP.
3. TCP ports `80` and `443` open on the VPS firewall/security group.

# Install

Run as root on the VPS:

```bash
bash <(curl -fsSL 'https://raw.githubusercontent.com/zmyxpt/gost_deploy/main/setup.sh')
```

The script asks for:

 - domain
 - email for TLS certificate notifications
 - direct GOST WebSocket path
 - WARP GOST WebSocket path
 - SOCKS5 username
 - SOCKS5 password

Example values:

```text
domain: www.example.com
direct path: /direct
WARP path: /warp
username: user1234
password: pass1234
```

# Client Profiles

Create two GOST client tunnels if you want both exits.

```bash
gost \
    -L auto://127.0.0.1:1080 -F 'socks5+wss://user1234:pass1234@www.example.com:443?path=/direct' \
    -- \
    -L auto://127.0.0.1:1081 -F 'socks5+wss://user1234:pass1234@www.example.com:443?path=/warp'
```

Or ou can use config.yaml for gost client if you want.

# How It Works

External traffic:

```text
client -> https://www.example.com:443
```

Caddy routes by WebSocket path:

```text
/direct -> gost:9000 -> VPS direct egress
/warp   -> gost:9001 -> warp:40000 -> Cloudflare WARP proxy egress
```

# Project Layout

 - `setup.sh`: installer and interactive configuration
 - `auto-update.sh`: weekly update task installed by `setup.sh`
 - `docker-compose.yaml`: service topology
 - `docker/`: Dockerfile and container entrypoint
 - `templates/`: Caddy and GOST config templates
 - `Volumes/`: generated runtime config and persistent data, created by `setup.sh`

# Container Notes

 - The GOST container uses `gogost/gost`.
 - The WARP container uses Debian stable with Cloudflare's official apt package source.
 - The WARP container stores registration state in `Volumes/warp`, so it should not need to register again after normal restarts.

# Maintenance

The installer adds a weekly cron job that runs `auto-update.sh`. It updates system packages, pulls/rebuilds containers, starts the stack again, prunes unused Docker objects, then reboots the VPS.

Generated configuration and persistent state live under `Volumes/`. Back up this directory before reinstalling or moving the deployment.
