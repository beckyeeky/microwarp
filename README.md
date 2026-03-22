# MicroWARP

[English](#english) | [中文说明](#chinese)

MicroWARP 是一个尽量保持“薄封装”的 Cloudflare WARP SOCKS5 容器：
- 使用 `wgcf` 注册并生成 WireGuard 配置。
- 使用 Linux 内核态 `wireguard-tools` 建立 WARP 隧道。
- 使用 `microsocks` 提供极轻量 SOCKS5 出口。

它适合 Telegram bot、Pixiv 抓取脚本、Pixiv-XP-Pusher 这类**只需要稳定出站代理**的场景；它不是完整的代理平台，也不提供 ACL、统计、控制面和自动切换策略。

## 设计目标

- **低资源占用**：代理侧只保留最小组件。
- **部署简单**：提供一个本地 SOCKS5 出口给业务进程使用。
- **更稳妥的默认值**：默认仅监听 `127.0.0.1`，避免误暴露开放代理。
- **更可控的供应链**：构建时固定 `microsocks` 版本；运行时固定 `wgcf` 版本并校验 SHA256。
- **更可观测**：提供容器 `HEALTHCHECK`，同时检查 `wg0`、出口探测和 SOCKS5 监听状态。

---

<a name="english"></a>
## English

### What it is

MicroWARP is a lightweight Docker image that turns Cloudflare WARP into a local SOCKS5 proxy. It is designed for outbound-only workloads such as:
- Telegram bots.
- Pixiv crawlers / downloaders.
- Pixiv-XP-Pusher sidecar proxying.
- Small scripts that only need a clean egress path.

### Security-first defaults

This project now uses safer defaults for production-style sidecar usage:
- Default bind address is `127.0.0.1`.
- If you bind to `0.0.0.0` or `::`, `SOCKS_USER` and `SOCKS_PASS` are required.
- The image includes a `HEALTHCHECK` that verifies WireGuard, egress probing, and the SOCKS5 port.
- The container no longer patches `/usr/bin/wg-quick` at runtime.

### Quick Start

```yaml
services:
  microwarp:
    build: .
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - warp-data:/etc/wireguard

volumes:
  warp-data:
```

Start it:

```bash
docker compose up -d --build
```

### Environment variables

```yaml
environment:
  - BIND_ADDR=127.0.0.1
  - BIND_PORT=1080
  - SOCKS_USER=admin
  - SOCKS_PASS=change-me
  - ENDPOINT_IP=162.159.193.10:2408
  - HEALTHCHECK_URL=https://1.1.1.1/cdn-cgi/trace
  - HEALTHCHECK_TIMEOUT=10
```

Notes:
- `BIND_ADDR` defaults to `127.0.0.1`.
- `ENDPOINT_IP` is optional and can be used when you already have a preferred WARP endpoint.
- `HEALTHCHECK_URL` is used both for startup egress logging and container health checks.

### Pixiv-XP-Pusher / bot integration

Common patterns:

1. **Use local SOCKS5 directly**
   - `ALL_PROXY=socks5://127.0.0.1:1080`
   - `HTTPS_PROXY=socks5://127.0.0.1:1080`

2. **Python**

```python
proxy_url = "socks5://127.0.0.1:1080"
```

3. **Node.js / Telegraf / GramJS**

Point the library's SOCKS5 option to `127.0.0.1:1080`, or export `ALL_PROXY=socks5://127.0.0.1:1080` if the runtime honors it.

### What this image does not do

- No HTTP proxy server built in.
- No traffic accounting or dashboard.
- No automatic account rotation.
- No multi-tenant isolation.

If you need those features, treat MicroWARP as a sidecar component and place it behind a more complete proxy layer.

---

<a name="chinese"></a>
## 中文说明

### 它适合什么场景

MicroWARP 适合以下场景：
- Telegram bot 只需要一个本机 SOCKS5 出口。
- Pixiv-XP-Pusher 通过代理降低直连高并发请求被风控的概率。
- Python / Node / Go 脚本需要低成本出海代理。
- 机器配置较小，希望代理本身尽量少占资源。

它的定位是 **sidecar 代理组件**，不是完整代理平台。

### 这次加固后的主要变化

- **默认更安全**：默认监听 `127.0.0.1`，避免一启动就暴露公网开放代理。
- **公网绑定强制认证**：如果监听 `0.0.0.0` 或 `::`，必须同时设置 `SOCKS_USER` / `SOCKS_PASS`，否则容器拒绝启动。
- **供应链更可控**：
  - 构建阶段固定 `microsocks` 版本。
  - 运行阶段固定 `wgcf` 版本，并在首次下载时校验 SHA256。
- **不再运行时篡改系统脚本**：移除了对 `/usr/bin/wg-quick` 的 `sed` 魔改。
- **加入健康检查**：同时检查 `wg0` 是否存在、探测出口请求是否成功、SOCKS5 端口是否可连接。

### 快速启动

```yaml
services:
  microwarp:
    build: .
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - warp-data:/etc/wireguard
    environment:
      - BIND_ADDR=127.0.0.1
      - BIND_PORT=1080
      # 如果需要公网暴露，务必配置下面两项
      # - SOCKS_USER=admin
      # - SOCKS_PASS=change-me
      # 可选：指定优选 Endpoint
      # - ENDPOINT_IP=162.159.193.10:2408

volumes:
  warp-data:
```

启动：

```bash
docker compose up -d --build
```

### 给 Pixiv-XP-Pusher / Telegram bot 的接法

#### 1. 最简单的方式：用环境变量

```bash
export ALL_PROXY=socks5://127.0.0.1:1080
export HTTPS_PROXY=socks5://127.0.0.1:1080
```

如果你的程序支持认证，则写成：

```bash
export ALL_PROXY=socks5://username:password@127.0.0.1:1080
```

#### 2. Python 项目

很多 HTTP 客户端、bot 库都可以直接接 SOCKS5。核心思路就是把代理地址配置成：

```python
proxy_url = "socks5://127.0.0.1:1080"
```

#### 3. Node.js 项目

Telegraf、GramJS 或其他请求库，如果支持 SOCKS5，直接填 `127.0.0.1:1080` 即可；如果运行时支持通用代理变量，也可以直接读取 `ALL_PROXY`。

### 生产使用建议

如果你准备用它给 Pixiv-XP-Pusher 降低风控概率，建议至少做到：

1. **把代理与业务放在同机或同内网**，优先走 `127.0.0.1` / 私网，不要裸暴露公网端口。
2. **持久化 `/etc/wireguard`**，避免频繁重新注册 WARP 账户。
3. **控制业务并发**，WARP 只能改善出口特征，不能替代应用层限速、重试和退避。
4. **在编排层启用健康重启**，配合容器 `HEALTHCHECK` 使用。
5. **如果必须公网开放**，一定开启认证，并额外配合防火墙限制来源 IP。

### 已知边界

- 没有内建 HTTP/HTTPS 代理。
- 没有自动轮换账号、自动切换 endpoint。
- 没有连接统计、审计和仪表盘。
- 更适合“你自己维护的小型稳定服务”，不适合作为多租户公共代理平台。
