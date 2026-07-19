FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN set -evx && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gpg iproute2 iptables lsb-release procps && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" >/etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends cloudflare-warp && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY warp-entrypoint.sh /usr/local/bin/warp-entrypoint.sh
RUN chmod +x /usr/local/bin/warp-entrypoint.sh

CMD ["/usr/local/bin/warp-entrypoint.sh"]
