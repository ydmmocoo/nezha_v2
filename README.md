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
| `NZ_agentsecretkey` / `IDU` / `NZ_DOMAIN` | 否 | — | 三者齐备才启用**内置本机探针** |
| `NO_AUTO_RENEW` | 否 | 未设置 | 设置任意值即关闭每日自动更新/备份同步 |

**内置探针说明**：`NZ_agentsecretkey` 是面板管理员账户的 Agent 密钥（登录面板后「个人中心 / 服务器安装命令」可获取），`IDU` 用 `uuidgen` 生成一个唯一 ID，`NZ_DOMAIN` 填 `127.0.0.1:8008`（本机直连，tls=false）或公网域名（如 `example.com:443`，tls=true）。三者缺一则不启动内置探针——此时可在面板「服务器 → 安装命令」添加任意被控端（V2 官方推荐方式）。

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

- 源码仓库连接本仓库，构建命令 `docker build -t nezha-v2 .`，运行命令即容器入口（`entrypoint.sh` 自动执行）。
- 在平台的环境变量面板填入上述 `GH_*` / `ARGO_*` 必填项。
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
