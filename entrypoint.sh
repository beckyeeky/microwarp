#!/bin/sh
set -e

WG_CONF="/etc/wireguard/wg0.conf"
mkdir -p /etc/wireguard

if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [ERROR] 不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${WGCF_ARCH}"
    chmod +x wgcf
    
    echo "==> [MicroWARP] 正在向 CF 注册设备..."
    ./wgcf register --accept-tos > /dev/null
    
    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null
    
    mv wgcf-profile.conf "$WG_CONF"
    rm -f wgcf wgcf-account.toml
    echo "==> [MicroWARP] 节点配置生成成功！"
else
    echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
fi

# ==========================================
# 强力洗白与内核兼容性处理
# ==========================================
sed -i 's/^AllowedIPs.*/AllowedIPs = 0.0.0.0\/0/g' "$WG_CONF"
sed -i '/Address.*:/d' "$WG_CONF" 
sed -i '/^DNS.*/d' "$WG_CONF"
sed -i '/src_valid_mark/d' /usr/bin/wg-quick

# ==========================================
# 拉起内核网卡
# ==========================================
echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
wg-quick up wg0 > /dev/null 2>&1

echo "==> [MicroWARP] 当前出口 IP 已成功变更为："
curl -s https://1.1.1.1/cdn-cgi/trace | grep ip=

# ==========================================
# 启动 SOCKS5 代理服务
# ==========================================
echo "==>[MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 0.0.0.0:1080"
exec microsocks -i 0.0.0.0 -p 1080
