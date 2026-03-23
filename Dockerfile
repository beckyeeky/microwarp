# ==========================================
# 阶段 1：固定版本编译 MicroSOCKS 引擎
# - 不再直接 git clone 默认分支，避免上游 HEAD 漂移
# - 改为固定 release tarball，尽量提升构建可复现性
# ==========================================
FROM alpine:3.20 AS builder

# 固定 MicroSOCKS 版本；如需升级，请显式修改该参数
ARG MICROSOCKS_REF=v1.0.5

# 仅安装构建阶段所需工具
RUN apk add --no-cache build-base curl tar

# 拉取固定版本源码并编译出 microsocks 二进制
RUN curl -fsSL "https://github.com/rofl0r/microsocks/archive/refs/tags/${MICROSOCKS_REF}.tar.gz" -o /tmp/microsocks.tar.gz \
    && mkdir -p /src \
    && tar -xzf /tmp/microsocks.tar.gz -C /src --strip-components=1 \
    && make -C /src

# ==========================================
# 阶段 2：极简运行环境
# - 仅保留 WireGuard、网络工具、下载工具与 healthcheck 依赖
# - 运行期不再包含编译工具链，减小镜像体积与攻击面
# ==========================================
FROM alpine:3.20

# wireguard-tools: 拉起 wg0
# iptables/iproute2: 保留 WireGuard 运行期常用网络能力
# wget/curl: 首次初始化下载 wgcf 与做连通性探测
# netcat-openbsd: 给 HEALTHCHECK 检测 SOCKS5 端口使用
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl netcat-openbsd

# 从构建阶段复制最终二进制，避免把源码与编译环境带入运行镜像
COPY --from=builder /src/microsocks /usr/local/bin/microsocks

WORKDIR /app

# 拷贝启动脚本与健康检查脚本
COPY entrypoint.sh healthcheck.sh ./
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh

# 暴露标准 SOCKS5 端口
EXPOSE 1080

# 健康检查同时覆盖：WireGuard 网卡、出口探测、SOCKS5 端口监听
HEALTHCHECK --interval=30s --timeout=15s --start-period=20s --retries=3 CMD ["/app/healthcheck.sh"]

# 启动容器时执行统一入口脚本
CMD ["/app/entrypoint.sh"]
