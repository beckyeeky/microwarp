#!/bin/sh
set -eu

WG_CONF="/etc/wireguard/wg0.conf"
WG_DIR="/etc/wireguard"
WGCF_VERSION="2.2.22"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://1.1.1.1/cdn-cgi/trace}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"
mkdir -p "$WG_DIR"

log() {
    echo "==> [MicroWARP] $*"
}

fail() {
    echo "==> [ERROR] $*" >&2
    exit 1
}

get_wgcf_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) fail "Unsupported architecture: $(uname -m)" ;;
    esac
}

install_wgcf() {
    arch="$(get_wgcf_arch)"
    binary="wgcf_${WGCF_VERSION}_linux_${arch}"
    url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/${binary}"
    checksum_url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_checksums.txt"

    log "Downloading wgcf ${WGCF_VERSION} for ${arch}..."
    wget -qO /tmp/wgcf "$url"
    wget -qO /tmp/wgcf_checksums.txt "$checksum_url"

    expected_sha256="$(awk -v file="$binary" '$2 == file {print $1}' /tmp/wgcf_checksums.txt)"
    [ -n "$expected_sha256" ] || fail "Unable to find checksum for ${binary}"

    actual_sha256="$(sha256sum /tmp/wgcf | awk '{print $1}')"
    [ "$actual_sha256" = "$expected_sha256" ] || fail "wgcf checksum verification failed"

    chmod +x /tmp/wgcf
}

initialize_warp() {
    if [ -f "$WG_CONF" ]; then
        log "Found persisted WireGuard config, skipping registration."
        return
    fi

    log "No WireGuard config found, initializing Cloudflare WARP account..."
    install_wgcf

    log "Registering device with Cloudflare WARP..."
    /tmp/wgcf register --accept-tos >/dev/null

    log "Generating WireGuard profile..."
    /tmp/wgcf generate >/dev/null

    mv wgcf-profile.conf "$WG_CONF"
    rm -f /tmp/wgcf /tmp/wgcf_checksums.txt wgcf-account.toml
    log "WireGuard profile created successfully."
}

prepare_wg_config() {
    [ -f "$WG_CONF" ] || fail "WireGuard config not found at ${WG_CONF}"

    sed -i 's#^AllowedIPs.*#AllowedIPs = 0.0.0.0/0#g' "$WG_CONF"
    sed -i '/^Address = .*:.*$/d' "$WG_CONF"
    sed -i '/^DNS *=/d' "$WG_CONF"

    if grep -q '^PersistentKeepalive' "$WG_CONF"; then
        sed -i 's/^PersistentKeepalive.*/PersistentKeepalive = 15/' "$WG_CONF"
    else
        sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
    fi

    if [ -n "${ENDPOINT_IP:-}" ]; then
        log "Overriding endpoint with ENDPOINT_IP=${ENDPOINT_IP}"
        sed -i "s#^Endpoint *=.*#Endpoint = ${ENDPOINT_IP}#" "$WG_CONF"
    fi
}

start_wireguard() {
    log "Starting wg0 interface..."
    wg-quick up wg0
    log "Current egress IP trace:"
    curl -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" | grep '^ip=' || true
}

validate_socks_config() {
    LISTEN_ADDR="${BIND_ADDR:-127.0.0.1}"
    LISTEN_PORT="${BIND_PORT:-1080}"

    case "$LISTEN_PORT" in
        ''|*[!0-9]*) fail "BIND_PORT must be numeric" ;;
    esac

    if [ "$LISTEN_ADDR" = "0.0.0.0" ] || [ "$LISTEN_ADDR" = "::" ]; then
        if [ -z "${SOCKS_USER:-}" ] || [ -z "${SOCKS_PASS:-}" ]; then
            fail "Refusing to bind ${LISTEN_ADDR}:${LISTEN_PORT} without SOCKS_USER and SOCKS_PASS"
        fi
    fi

    export LISTEN_ADDR LISTEN_PORT
}

start_microsocks() {
    validate_socks_config

    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        log "Authentication enabled. Listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
        exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
    fi

    log "Authentication disabled. Listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
}

initialize_warp
prepare_wg_config
start_wireguard
start_microsocks
