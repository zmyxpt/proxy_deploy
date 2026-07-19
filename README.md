# proxy_deploy

Deploy Shadowsocks and GOST together behind one Caddy HTTPS endpoint. Each protocol provides a direct exit and a Cloudflare WARP exit, selected by WebSocket path.

| Service | Internal port | Egress |
| --- | ---: | --- |
| Shadowsocks direct | 9000 | VPS |
| Shadowsocks WARP | 9001 | Cloudflare WARP |
| GOST direct | 9002 | VPS |
| GOST WARP | 9003 | Cloudflare WARP proxy |

Clients always connect to the public domain on port `443`. The internal ports are only used between Caddy and the proxy containers.

## Requirements

- Debian 13 (trixie)
- root access
- a domain pointing to the VPS
- inbound TCP ports 80 and 443
- `/dev/net/tun` for the Shadowsocks WARP container

## Install

Run as root on the VPS:

```bash
bash <(curl -fsSL 'https://raw.githubusercontent.com/zmyxpt/proxy_deploy/main/setup.sh')
```

The installer asks for:

- domain and certificate email
- Shadowsocks direct and WARP WebSocket paths
- Shadowsocks password
- GOST direct and WARP WebSocket paths
- GOST SOCKS5 username and password

Use four different WebSocket paths, for example `/ss-direct`, `/ss-warp`, `/gost-direct`, and `/gost-warp`.

## Shadowsocks Client

Create direct and WARP profiles with these common settings:

```text
server: www.example.com
server_port: 443
method: aes-256-gcm
plugin: v2ray-plugin
password: your password
```

Use the corresponding plugin options:

```text
tls;host=www.example.com;path=/ss-direct
tls;host=www.example.com;path=/ss-warp
```

## GOST Client

Create both local tunnels with:

```bash
gost \
    -L auto://127.0.0.1:1080 -F 'socks5+wss://user:password@www.example.com:443?path=/gost-direct' \
    -- \
    -L auto://127.0.0.1:1081 -F 'socks5+wss://user:password@www.example.com:443?path=/gost-warp'
```

## Architecture

Two WARP containers are required because Shadowsocks uses WARP tunnel mode while GOST uses WARP local proxy mode:

```text
/ss-direct   -> shadowsocks-direct:9000 -> VPS egress
/ss-warp     -> warp-shadowsocks:9001   -> WARP tunnel egress
/gost-direct -> gost:9002               -> VPS egress
/gost-warp   -> gost:9003 -> warp-gost  -> WARP proxy egress
```

Persistent state is separated into `Volumes/warp-shadowsocks` and `Volumes/warp-gost` so each WARP mode keeps its own registration and configuration.

## Maintenance

The installer creates a weekly cron job for `auto-update.sh`. It updates Debian packages, refreshes and rebuilds containers, prunes unused Docker data, and reboots the VPS. Back up `Volumes/` before reinstalling or moving the deployment.
