#!/bin/sh
set -eu

# ==========================================
# MicroWARP 健康检查脚本
# 检查项：
# 1. wg0 是否存在且可被 wg show 读取
# 2. 出口探测地址是否可访问
# 3. SOCKS5 监听端口是否已就绪
# ==========================================

# 与主入口脚本保持一致的默认值
: "${HEALTHCHECK_URL:=https://1.1.1.1/cdn-cgi/trace}"
: "${HEALTHCHECK_TIMEOUT:=10}"
: "${BIND_ADDR:=127.0.0.1}"
: "${BIND_PORT:=1080}"

# 1) WireGuard 必须存在，否则说明隧道根本没起来
wg show wg0 >/dev/null 2>&1

# 2) 出口探测必须可达，否则即使进程活着也可能已经失去代理能力
curl -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" >/dev/null

# 3) 将 0.0.0.0 / :: 转为本地回环地址，便于容器内探测监听端口
HOST="$BIND_ADDR"
if [ "$HOST" = "0.0.0.0" ]; then
    HOST="127.0.0.1"
elif [ "$HOST" = "::" ]; then
    HOST="::1"
fi

# 4) 检查 SOCKS5 端口是否可连接
nc -z "$HOST" "$BIND_PORT" >/dev/null 2>&1
