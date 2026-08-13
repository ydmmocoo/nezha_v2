# Argo-Nezha-Service-Container (哪吒面板 **V2**)

使用 Cloudflare Argo 隧道的**哪吒监控面板 V2**（`nezhahq/nezha`）服务端容器。
只要能联网即可部署，无需公网 IP / 开放端口，适合 PaaS（Northflank、Render、Koyeb、Hugging Face、dashboard.suga.app 等）、LXC / OpenVZ、NAT 机器。

> **仅兼容哪吒面板 V2，已彻底移除 V0 / V1 兼容代码。**
> 相比参考项目（fscarmen2 / Kiritocyz / IonRh 的 V0·V1 分支），本镜像：
> - 只从 `nezhahq/nezha`（V2）下载 Dashboard，不再按 `naiba/nezha` / `nap0o` / `railzen/nezha-zero` 做版本分支；
> - 使用 V2 **统一端口 8008**（Web + gRPC + WebSocket 共用），不再维护独立的 5555 gRPC 端口；
> - 移除旧的 `sqlite.db` `servers` 表 hack —— V2 首次启动会自动建库与初始化管理员；
> - 反代默认仅保留 **Caddy**（h2c 回源 8008），移除 Nginx / grpcwebproxy 兼容分支。

---

## 架构

```
哪吒 Agent（被控端）
      │  gRPC  /proto.NezhaService/*
      ▼
Cloudflare Argo Tunnel（公网，自动 TLS）
      │  https://localhost:443  (noTLSVerify, http2Origin)
      ▼
Caddy 反向代理（自签证书，h2c → 127.0.0.1:8008）
      │
      ▼
Nezha Dashboard V2（nezhahq/nezha，监听 8008）
```

V2 的 Web、gRPC、WebSocket 都由 Dashboard 在 **8008** 一个端口处理，Caddy 仅做 TLS 终结与 gRPC 的 h2c 回源，Argo 隧道把公网流量回源到 Caddy 的 443。

---

## 准备变量

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `GH_USER` | 是 | GitHub 用户名，作为面板管理员（OAuth 登录） |
| `GH_CLIENTID` | 是 | GitHub OAuth App 的 Client ID |
| `GH_CLIENTSECRET` | 是 | GitHub OAuth App 的 Client Secret |
| `ARGO_AUTH` | 是 | Argo 隧道认证：Cloudflare 控制台生成的 **json**（推荐）或 **token** |
| `ARGO_DOMAIN` | 是 | Argo 隧道绑定的域名（需提前在 Cloudflare 开启 gRPC） |

可选变量见下表。

### 获取 Argo 隧道

- **json（推荐）**：通过 <https://fscarmen.cloudflare.now.cc> 一键生成，或在 Cloudflare Zero Trust 创建隧道后复制 `Tunnel Secret` 完整 JSON。
- **token**：Cloudflare 控制台手动创建隧道，复制以 `ey` 开头的 token。

> 域名需在 Cloudflare 开启 **gRPC**（Network → gRPC）。

### GitHub OAuth App

<https://github.com/settings/developers/new> 创建应用：
- Homepage / Callback：`https://<你的ARGO域名>/oauth2/callback`
- 拿到 Client ID 与 Client Secret。

---

## 环境变量

| 变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `GH_USER` / `GH_CLIENTID` / `GH_CLIENTSECRET` | 是 | — | GitHub OAuth 管理员登录 |
| `ARGO_AUTH` / `ARGO_DOMAIN` | 是 | — | Argo 隧道 json 或 token |
| `DASHBOARD_VERSION` | 否 | 最新 | 固定面板版本，V2 格式如 `v2.3.4` |
| `LANGUAGE` | 否 | `zh-CN` | 后台语言 |
| `GH_PAT` / `GH_EMAIL` / `GH_REPO` | 否 | — | GitHub 备份库（私库），三者齐备才启用每日备份 |
| `GH_BACKUP_USER` | 否 | `=$GH_USER` | 备份库所属 GitHub 用户 |
| `NZ_AGENTKEY` / `IDU` / `NZ_DOMAIN` | 否 | — | 三者齐备才启用**内置本机探针** |
| `NO_AUTO_RENEW` | 否 | 未设置 | 设置任意值即关闭每日自动更新/备份同步 |

**内置探针说明**：`NZ_AGENTKEY` 是面板管理员账户的 Agent 密钥（登录面板后「个人中心 / 服务器安装命令」可获取），`IDU` 用 `uuidgen` 生成一个唯一 ID，`NZ_DOMAIN` 填 `127.0.0.1:8008`（本机直连，tls=false）或公网域名（如 `example.com:443`，tls=true）。三者缺一则不启动内置探针——此时可在面板「服务器 → 安装命令」添加任意被控端（V2 官方推荐方式）。

---

## Docker 镜像

### 构建镜像

```bash
# 在仓库根目录执行
docker build -t nezha-v2-argo:latest .
```

镜像名约定为 `nezha-v2-argo:latest`，内部包含 Debian + supervisor 守护进程、Caddy 反代、以及 `entrypoint.sh` 初始化逻辑。**镜像本身不含面板二进制**——V2 Dashboard（与可选 Agent）在容器首次启动时按需从 GitHub 下载，所以构建很快、体积很小，但运行时需能访问 `github.com`。

### 多架构构建（CI 自动）

`.github/workflows/Build.yml` 借助 `docker/setup-qemu-action` + `docker/setup-buildx-action`，在 push 到 `main` 时自动构建并推送 `linux/amd64` 与 `linux/arm64` 双架构镜像到容器 registry（GHCR / Docker Hub）。在 GitHub 仓库 `Settings → Secrets` 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`（或 `GHCR_TOKEN`）后启用。

```bash
# 本地模拟多架构构建（需 buildx + qemu）
docker buildx build --platform linux/amd64,linux/arm64 -t nezha-v2-argo:latest . --load
```

### 推送到镜像仓库

```bash
# Docker Hub
docker tag nezha-v2-argo:latest <用户名>/nezha-v2-argo:latest
docker push <用户名>/nezha-v2-argo:latest

# 或 GHCR
docker tag nezha-v2-argo:latest ghcr.io/<用户名>/nezha-v2-argo:latest
docker push ghcr.io/<用户名>/nezha-v2-argo:latest
```

> 标签约定：`latest` 跟随仓库 `main`；如需固定版本可额外打 `vX.Y.Z` 标签。该标签**只标识容器镜像**，与 `DASHBOARD_VERSION`（控制面板版本）解耦。

### 直接拉取运行

构建并推送后，后续部署可跳过构建步骤，直接 `docker pull` 再 `docker run`（见下方「部署 → Docker Run」）：

```bash
docker pull <用户名>/nezha-v2-argo:latest
```

---

## 部署

### 1. Docker Run

```bash
docker run -dit \
  --name nezha_v2 \
  --restart always \
  -e GH_USER=<github用户名> \
  -e GH_CLIENTID=<client id> \
  -e GH_CLIENTSECRET=<client secret> \
  -e ARGO_AUTH='<argo json 或 token>' \
  -e ARGO_DOMAIN=<你的argo域名> \
  -e DASHBOARD_VERSION=v2.3.4 \
  -v "$PWD/data:/dashboard/data" \
  nezha-v2-argo:latest
```

### 2. Docker Compose

```bash
docker compose up -d
```
（变量写在 `.env` 或 shell 环境中，见 `docker-compose.yml` 注释。）

### 3. PaaS（Northflank / dashboard.suga.app / Render / Koyeb）

> **不要**在「Deploy from image」里直接填 `nezha-v2-argo:latest` —— 这只是本地/未推送的镜像标签，PaaS 拉不到会报“无法获取”。必须二选一：
> - **A. 从源码构建（推荐）**：选「Build from a Git Repository」，连接本 GitHub 仓库，Build Method 选 Dockerfile（路径 `/Dockerfile`）。Northflank 自动 build 并托管镜像，无需手动 push。
> - **B. 推送到 registry**：先把镜像 push 到 Docker Hub / GHCR / 平台自带 registry，再填**完整地址**（如 `docker.io/<用户名>/nezha-v2-argo:latest` 或 `ghcr.io/<用户名>/nezha-v2-argo:latest`）。`.github/workflows/Build.yml` 会在 push 到 main 时自动构建推送（需配 `DOCKERHUB_*` 或 `GHCR_TOKEN` secrets）。

- 在平台的环境变量面板填入上述 `GH_*` / `ARGO_*` 必填项。
- **Build arguments 留空**（Dockerfile 无任何 `ARG`，所有配置都在运行时通过 Runtime variables 注入，不在 build 阶段）。
- **Runtime variables** 填法见上方「环境变量」表：`GH_USER` / `GH_CLIENTID` / `GH_CLIENTSECRET` / `ARGO_AUTH` / `ARGO_DOMAIN` 为必填；`GH_CLIENTSECRET` / `ARGO_AUTH` / `GH_PAT` / `NZ_AGENTKEY` 建议标为 Secret。`ARCH` / `CADDY_VER` / `DASH_VER_TAG` 为脚本内部自动计算，切勿手动填。
- **务必配置 `GH_PAT` + `GH_REPO` + `GH_EMAIL` 备份**：PaaS 文件系统是临时性的，重启会丢失 `/dashboard/data`，靠 GitHub 备份恢复。
- 平台一般无需映射端口（Argo 隧道出站 443 即可）。

---

## 客户端接入（被控端）

在面板「服务器 → 安装命令」复制对应系统的命令，在被控机执行即可。V2 Agent 连接地址为你的 Argo 域名（如 `example.com:443`，tls=true）。

手动示例（Linux）：

```bash
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh && \
chmod +x agent.sh && \
env NZ_SERVER=example.com:443 NZ_TLS=true NZ_CLIENT_SECRET=<密钥> NZ_UUID=<uuid> ./agent.sh
```

---

## 备份 / 还原 / 更新

配置 `GH_PAT`/`GH_REPO`/`GH_EMAIL` 后：

- **每日 04:00（北京时间）自动备份** `/dashboard/data` 到 GitHub 私库；
- **每日 03:30 自动检测并更新** Dashboard 到最新 V2（保留数据）；
- 手动备份：`bash /dashboard/backup.sh`
- 手动还原：`bash /dashboard/restore.sh`（还原最新）或 `bash /dashboard/restore.sh dashboard-xxxx.tar.gz`
- 手动更新面板：`bash /dashboard/renew.sh`

---

## 排错

**`nezha` 进程反复 `exit status 1`、supervisor 报 `too many start retries`**
几乎都是 `data/config.yaml` 不符合 V2 schema 导致。V2 面板**只认以下 6 个字段**（全小写）：

```yaml
debug: false
listen_port: 8008
language: zh-CN
site_name: "Nezha Probe"
install_host: <你的ARGO域名>
tls: false
```

- 切勿使用 V0/V1 的 `HTTPPort` / `GRPCPort` / `Oauth2` / `site` 字段——V2 不识别，且 `listen_port` 缺省为 `0`，面板绑定端口 0 失败直接退出。
- **OAuth（GitHub 登录）不是写在 config.yaml 里**，而是由容器通过 `OAUTH2_*` 环境变量注入（`OAUTH2_TYPE` / `OAUTH2_ADMIN` / `OAUTH2_CLIENTID` / `OAUTH2_CLIENTSECRET` / `OAUTH2_ENDPOINT`），值来自你填的 `GH_*` 变量。
- 若仍异常，进容器看面板真实报错：`docker exec -it <容器> tail -f /dashboard/data/../*.log` 或检查 supervisor 中 `nezha` 的 stdout（本镜像已将其输出到容器 stdout，部署平台日志即可见）。

**页面能打开，但提示「后端 API 无法访问 / 无法加载监控数据」，控制台报 `Unexpected token '<', "<!DOCTYPE>"... is not valid JSON`**

根因：哪吒 V2 的**实时监控数据走 WebSocket**（`/api/v1/ws/server`）。若反代把 WebSocket 升级请求用 `h2c`（HTTP/2 明文）传输转发，Cloudflare/Argo 回源会得到 **502**，前端拿不到数据并连锁命中 Cloudflare 的 HTML 错误页，被当成 JSON 解析。

验证：`curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" https://<你的域名>/api/v1/ws/server` 若返回 `502 Bad Gateway` 即为此问题。

修复：反代必须**按路径分流**——仅 gRPC 路径 `/proto.NezhaService/*` 用 `h2c`（HTTP/2），Web/REST API/WebSocket 一律走 **HTTP/1.1**（支持 Upgrade）。本镜像 `entrypoint.sh` 已默认如此生成 Caddyfile；若你曾手改过 Caddyfile，请确认包含：

```caddyfile
reverse_proxy /proto.NezhaService/* localhost:8008 {
    transport http { versions h2c 2 }
}
reverse_proxy localhost:8008 {
    transport http { versions h1 }
}
```

> 附带提醒：SPA 会从 `fastly.jsdelivr.net` 加载图标/字体 CSS，国内网络常被墙会变慢或加载不全（仅影响样式，不影响数据）。如需彻底离线可把 `index.html` 里的 cdn 引用改为自托管。

---

## 与参考项目的差异（为何是 V2-only）

参考仓库（fscarmen2 / Kiritocyz / IonRh）的 `init.sh` 内含大量 V0/V1 兼容分支：
`naiba/nezha`（<0.20.13）、`nap0o/nezha-dashboard`（=0.20.13）、`railzen/nezha-zero`（>0.20.13）三源切换，
以及 `sqlite.db` 的 `servers` 表预置密钥。本镜像**全部删除**，仅保留 `nezhahq/nezha`（V2）单一来源，
并使用 V2 的统一端口与自动建库机制，逻辑更干净、维护更省心。

---

## 文件结构

```
.
├── Dockerfile            # debian + supervisor 基础镜像
├── entrypoint.sh         # 核心初始化（V2 only）：下载/配置/守护
├── backup.sh             # 备份到 GitHub 私库
├── restore.sh            # 从 GitHub 私库还原
├── renew.sh              # 更新 Dashboard 二进制
├── docker-compose.yml    # 本地/VPS 部署示例
└── .github/workflows/Build.yml  # 多架构镜像构建推送
```

---

## 免责声明

本项目仅供学习交流，非盈利目的。使用本程序须遵守服务器所在地及用户所在国家/地区的法律法规。
面板含高权限，请务必修改默认密码、使用强 OAuth 配置，并将备份库设为私有。
