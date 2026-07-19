FROM ghcr.io/shadowsocks/ssserver-rust:latest

USER root

RUN cd /tmp && \
    TAG=$(wget -qO- https://api.github.com/repos/shadowsocks/v2ray-plugin/releases/latest | grep tag_name | cut -d '"' -f4) && \
    case "$(uname -m)" in \
        x86_64)  PLUGIN_ARCH="amd64" ;; \
        aarch64) PLUGIN_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;; \
    esac && \
    wget "https://github.com/shadowsocks/v2ray-plugin/releases/download/${TAG}/v2ray-plugin-linux-${PLUGIN_ARCH}-${TAG}.tar.gz" && \
    tar -xf ./*.tar.gz && \
    rm ./*.tar.gz && \
    mv ./v2ray* /usr/bin/v2ray-plugin && \
    chmod +x /usr/bin/v2ray-plugin

USER nobody

CMD ["ssserver", "--log-without-time", "-c", "/etc/shadowsocks-rust/config.json"]

