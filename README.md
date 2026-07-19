# proxy_deploy

Deploy either Shadowsocks or GOST behind a Caddy HTTPS endpoint. Both options provide two WebSocket paths:

- direct: traffic exits from the VPS network
- WARP: traffic exits through Cloudflare WARP

The repository combines the histories and functionality of `ss_deploy` and `gost_deploy`. Shared installation, TLS, update, and container management logic lives in one place, while protocol-specific templates remain separate.

## Requirements

- Debian 13 (trixie)
- root access
- a domain pointing to the VPS
- inbound TCP ports 80 and 443
- `/dev/net/tun` when deploying Shadowsocks with WARP

## Install

Run as root on the VPS:

```bash
bash <(curl -fsSL 'https://raw.githubusercontent.com/zmyxpt/proxy_deploy/main/setup.sh')
```

The installer first asks which server to deploy:

1. Shadowsocks with `v2ray-plugin`
2. GOST authenticated SOCKS5 over WebSocket

It then asks for the domain, certificate email, direct and WARP paths, and protocol credentials. The selected Compose file is written to `docker-compose.yaml`, and generated configuration is stored under `Volumes/`.

## Shadowsocks Client

Create direct and WARP profiles with these common settings:

```text
server: www.example.com
server_port: 443
method: aes-256-gcm
plugin: v2ray-plugin
password: your password
```

Use the matching WebSocket path for each profile:

```text
tls;host=www.example.com;path=/direct
tls;host=www.example.com;path=/warp
```

## GOST Client

Create both local tunnels with:

```bash
gost \
    -L auto://127.0.0.1:1080 -F 'socks5+wss://user:password@www.example.com:443?path=/direct' \
    -- \
    -L auto://127.0.0.1:1081 -F 'socks5+wss://user:password@www.example.com:443?path=/warp'
```

## Layout

- `setup.sh`: unified interactive installer
- `auto-update.sh`: weekly package and container update task
- `templates/docker-compose.*.yaml`: protocol-specific service topology
- `templates/Caddyfile.*`: protocol-specific reverse proxy routes
- `templates/*.json` and `templates/gost.yaml`: server configuration templates
- `docker/`: Shadowsocks and protocol-specific WARP images
- `Volumes/`: generated runtime configuration and persistent state

## Switching Protocols

Back up `Volumes/`, then rerun `setup.sh` and choose the other protocol. The installer replaces `docker-compose.yaml` and the active Caddy configuration. Remove unused protocol directories under `Volumes/` only after confirming the new deployment works.

## Maintenance

The installer creates a weekly cron job for `auto-update.sh`. It updates Debian packages, refreshes and rebuilds containers, prunes unused Docker data, and reboots the VPS. Back up `Volumes/` before reinstalling or moving the deployment.
