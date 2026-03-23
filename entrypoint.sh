#!/bin/sh
set -eu

# ==========================================
# MicroWARP 统一入口脚本
# 主要职责：
# 1. 首次启动时自动注册 WARP 并生成 WireGuard 配置
# 2. 对 wg0.conf 做最小必要修正
# 3. 拉起 wg0 网卡
# 4. 启动 microsocks 提供 SOCKS5 出口
# ==========================================

# WireGuard 主配置文件路径
WG_CONF="/etc/wireguard/wg0.conf"
WG_DIR="/etc/wireguard"

# 固定 wgcf 版本，避免运行期下载 latest 造成不可控漂移
WGCF_VERSION="2.2.22"

# 出口探测地址与超时；同时用于 startup log 与 healthcheck
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://1.1.1.1/cdn-cgi/trace}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"

# 确保持久化目录存在
mkdir -p "$WG_DIR"

# 统一日志输出
log() {
    echo "==> [MicroWARP] $*"
}

# 统一错误输出并退出
fail() {
    echo "==> [ERROR] $*" >&2
    exit 1
}

# ==========================================
# 1. 根据容器架构映射 wgcf 发布产物名
# ==========================================
get_wgcf_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) fail "Unsupported architecture: $(uname -m)" ;;
    esac
}

# ==========================================
# 2. 下载并校验 wgcf
# - 固定版本
# - 下载官方 checksum 文件
# - 对二进制做 SHA256 校验，降低供应链风险
# ==========================================
install_wgcf() {
    arch="$(get_wgcf_arch)"
    binary="wgcf_${WGCF_VERSION}_linux_${arch}"
    url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/${binary}"
    checksum_url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_checksums.txt"

    log "Downloading wgcf ${WGCF_VERSION} for ${arch}..."
    wget -qO /tmp/wgcf "$url"
    wget -qO /tmp/wgcf_checksums.txt "$checksum_url"

    # 从 checksum 列表中提取当前架构二进制的预期哈希
    expected_sha256="$(awk -v file="$binary" '$2 == file {print $1}' /tmp/wgcf_checksums.txt)"
    [ -n "$expected_sha256" ] || fail "Unable to find checksum for ${binary}"

    # 计算实际哈希并比对，不匹配则拒绝继续执行
    actual_sha256="$(sha256sum /tmp/wgcf | awk '{print $1}')"
    [ "$actual_sha256" = "$expected_sha256" ] || fail "wgcf checksum verification failed"

    chmod +x /tmp/wgcf
}

# ==========================================
# 3. 首次初始化 WARP 账户与 wg0.conf
# - 若已存在持久化配置，则直接复用
# - 若不存在，则自动注册并生成配置
# ==========================================
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

    # 将生成的 profile 作为标准 wg0 配置保存到持久化目录
    mv wgcf-profile.conf "$WG_CONF"

    # 清理一次性工具与明文账号文件，降低遗留风险
    rm -f /tmp/wgcf /tmp/wgcf_checksums.txt wgcf-account.toml
    log "WireGuard profile created successfully."
}

# ==========================================
# 4. 修正 wg0.conf
# - AllowedIPs 统一改为 0.0.0.0/0，确保全局出站走 WARP
# - 删除 IPv6 Address 行，避免部分环境下的兼容性问题
# - 删除 DNS 注入，避免影响宿主或业务侧自己的解析策略
# - 强制 PersistentKeepalive=15，降低长连接空闲断流概率
# - 若提供 ENDPOINT_IP，则覆盖默认 Endpoint
# ==========================================
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

# ==========================================
# 5. 拉起 WireGuard 网卡
# - 若 wg-quick up 失败，脚本会直接退出
# - 成功后打印一次出口探测结果，便于容器日志排障
# ==========================================
start_wireguard() {
    log "Starting wg0 interface..."
    wg-quick up wg0

    log "Current egress IP trace:"
    curl -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" | grep '^ip=' || true
}

# ==========================================
# 6. 校验 SOCKS5 监听参数
# - 默认绑定 127.0.0.1，避免默认变成开放代理
# - 若绑定公网地址（0.0.0.0 / ::），则强制要求认证
# - 端口必须为纯数字
# ==========================================
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

# ==========================================
# 7. 启动 MicroSOCKS
# - 有用户名密码时启用 SOCKS5 认证
# - 否则仅允许本地监听下的无认证模式
# ==========================================
start_microsocks() {
    validate_socks_config

    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        log "Authentication enabled. Listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
        exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
    fi

    log "Authentication disabled. Listening on ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
}

# 依次执行初始化、配置修正、拉起隧道与启动 SOCKS5
initialize_warp
prepare_wg_config
start_wireguard
start_microsocks
