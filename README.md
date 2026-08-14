# 哪吒监控 V2 Northflank 容器

这是一个面向 Northflank 的哪吒监控 V2 容器方案。它基于官方 `nezhahq/nezha` Dashboard 和 `nezhahq/agent` Release，在容器内使用 Nginx 转发 Web、WebSocket 与 gRPC。

本项目只支持哪吒监控 V2：

- 只下载 `nezhahq/nezha` 的 `v2.x.y` Dashboard；
- 只下载 `nezhahq/agent` 的 `v2.x.y` Agent；
- 不包含 V0、V1 或旧版 `naiba/nezha` 的下载地址、配置字段、数据库迁移和兼容分支；
- REST API 仍可能出现 `/api/v1` 路径，这是 V2 当前的 API 路由命名，不代表使用的是 V1 产品。

## 方案概览

```text
浏览器 / 哪吒 Agent
          │ HTTPS，Northflank 自动签发证书
          ▼
Northflank 公网域名 :443
          │ 边缘 TLS 终止，HTTP/2 / gRPC 转发
          ▼
容器 :80（Nginx，HTTP/2）
     ├── Web / REST / WebSocket ──► Dashboard :8008
     └── /proto.NezhaService/ ────► Dashboard :8008
```

Dashboard 的 SQLite 配置、用户、服务器和任务数据写入 `/app/data`。Northflank 必须将持久卷挂载到这个路径，并且服务只运行一个副本。

## 当前默认版本

截至本文档编写时，官方稳定 Release 为：

| 组件 | 默认版本 | 官方仓库 |
| --- | --- | --- |
| Dashboard | `v2.3.4` | [nezhahq/nezha](https://github.com/nezhahq/nezha/releases) |
| Agent | `v2.3.1` | [nezhahq/agent](https://github.com/nezhahq/agent/releases) |

启动时如果没有设置版本变量，脚本会从 GitHub Releases 自动选择最新的稳定 `v2.x.y`。如果设置了版本变量，脚本会拒绝 `v0.*`、`v1.*` 和 `v3.*`。

生产环境建议固定版本：

```text
DASHBOARD_VERSION=v2.3.4
AGENT_VERSION=v2.3.1
```

Dashboard 与 Agent 独立发布，不要求补丁版本号相同；升级前应查看两个仓库的 Release Notes，并先备份 `/app/data`。

## 为什么没有 `NZ_AGENTKEY`

哪吒 V2 当前使用“连接密钥与用户绑定”的 Agent 认证方式。外部服务器的 Agent 必须从 Dashboard 的“服务器 → 安装命令”获取 `NZ_CLIENT_SECRET`，不能照搬旧版教程里的全局 `NZ_AGENTKEY`。

本项目不会把旧版全局密钥伪装成 V2 的外部 Agent 密钥。若需要让容器自己作为一台服务器上报，使用单独的 `NZ_SELF_CLIENT_SECRET`，其值同样应来自 Dashboard 为该服务器生成的 V2 安装命令。

## 文件说明

```text
.
├── Dockerfile
├── docker-compose.yml       # 本地测试示例
├── nginx/nezha.conf         # Web、WebSocket、gRPC 反向代理
├── scripts/start.sh         # 初始化、下载、配置、启动和看门狗
├── scripts/backup.sh        # 打包 /app/data
├── scripts/restore.sh       # 恢复 V2 数据包
├── scripts/restart.sh       # 手动停止 Dashboard
└── README.md
```

## 环境变量

### 运行所需

没有必须填写的业务密钥。首次启动时 V2 Dashboard 会生成默认配置和 JWT 密钥；但生产环境建议设置 `NZ_JWTSECRETKEY`，使重启和版本升级不会因为密钥轮换导致登录态失效。

### 推荐变量

| 变量 | 示例 | 说明 |
| --- | --- | --- |
| `NZ_JWTSECRETKEY` | `一段随机长字符串` | V2 JWT 签名密钥。请在 Northflank Secret 中保存，不要提交到 Git。 |
| `FORCE_AUTH` | `true` | `true` 要求登录后才能查看监控数据；生产环境建议为 `true`。 |
| `DASHBOARD_VERSION` | `v2.3.4` | 固定 V2 Dashboard 版本。 |
| `AGENT_VERSION` | `v2.3.1` | 固定容器自监控 Agent 版本。只有启用自监控时才下载。 |
| `NZ_DOMAIN` | `your-app.code.run` | Agent 对接域名，只填域名，不含协议、路径和端口。填写后会把安装地址设置为 `${NZ_DOMAIN}:${NZ_AGENT_PORT}`。 |
| `NZ_AGENT_PORT` | `443` | Agent 对接端口，Northflank 使用 `443`。 |
| `NZ_DASHBOARD_HOST` | `your-app.code.run` | Dashboard 对外域名，用于 V2 `reserved_hosts`。使用自定义域名时填写最终域名。 |

### 可选功能

| 变量 | 说明 |
| --- | --- |
| `IDU` | 容器自监控服务器的 UUID。必须同时填写 `NZ_DOMAIN` 和 `NZ_SELF_CLIENT_SECRET`。 |
| `NZ_SELF_CLIENT_SECRET` | V2 面板为容器自监控服务器生成的连接密钥。只给容器内 Agent 使用。 |
| `NZ_SELF_AGENT_DEBUG` | 设为 `true` 输出容器自监控 Agent 调试信息。 |
| `NZ_AGENT_DISABLE_COMMAND_EXECUTE` | 默认 `true`，禁止容器自监控 Agent 执行远程命令。 |
| `NZ_AGENT_DISABLE_NAT` | 默认 `true`，禁止容器自监控 Agent 使用 NAT 能力。 |
| `NZ_ENABLE_TSDB` | 设为 `true` 启用 V2 TSDB 历史指标，默认关闭。 |
| `NZ_TSDB_DATA_PATH` | 默认 `/app/data/tsdb`，建议保持在持久卷内。 |
| `NZ_TSDB_RETENTION_DAYS` | TSDB 保留天数，默认 `30`。 |
| `NZ_TSDB_MIN_FREE_DISK_SPACE_GB` | 最低剩余磁盘空间，默认 `1`。 |
| `NZ_TSDB_MAX_MEMORY_MB` | TSDB 缓存上限，默认 `256`。 |
| `NZ_TSDB_WRITE_BUFFER_SIZE` | 写入缓冲条数，默认 `512`。 |
| `NZ_TSDB_WRITE_BUFFER_FLUSH_INTERVAL` | 写入刷新间隔秒数，默认 `5`。 |
| `ARGO_AUTH` | Cloudflare Tunnel Token。设置后启动 Token 模式 `cloudflared`。 |
| `TZ` | 时区，默认 `Asia/Shanghai`。 |

## Northflank 部署（推荐）

### 1. 准备代码仓库

将本项目推送到 GitHub 或 Northflank 支持的 Git 仓库。仓库根目录必须有 `Dockerfile`、`nginx/` 和 `scripts/`。

不要提交以下内容：

- `NZ_JWTSECRETKEY`、`NZ_SELF_CLIENT_SECRET` 等真实密钥；
- GitHub Token、Cloudflare Tunnel Token；
- 本地 `data/` 目录和生产数据库。

### 2. 创建服务

在 Northflank 中：

1. 创建 Project；
2. 创建 **Combined service** 或 **Deployment service**；
3. 选择 **Build from Git**；
4. 选择仓库和分支；
5. 构建方式选择 **Dockerfile**；
6. Dockerfile 路径填写 `/Dockerfile`；
7. Build context 使用仓库根目录；
8. 创建服务并等待构建完成。

本项目不需要 Build Arguments。所有配置都作为运行时变量注入。

### 3. 配置公网端口

在服务的 **Ports & DNS** 中只公开容器端口 `80`：

| 项目 | 值 |
| --- | --- |
| Container port | `80` |
| Protocol | `HTTP(S)/2` 或界面中的 `HTTP/2` |
| Public | 开启 |
| Domain | 使用 Northflank 自动域名或绑定自己的域名 |

HTTP/2 是关键设置，因为哪吒 Agent 使用 gRPC。Northflank 会在边缘提供 `80/443` 公网入口、自动生成 TLS 证书，再把请求路由到容器端口 `80`。

Dockerfile 同时声明了 `443`，它仅用于普通 Docker/VPS 或 Cloudflare Tunnel 的 HTTPS origin。Northflank 部署时不要把容器 `443` 再创建为第二个公网入口，否则容易把 Agent 流量绕到不需要的自签证书上。

### 4. 添加持久卷

在服务的 **Volumes** 中创建一个 Northflank persistent volume：

```text
Container mount path: /app/data
```

建议至少从 `1 GB` 开始。由于 SQLite 和 TSDB 都是单实例本地存储：

- 副本数保持为 `1`；
- 不要水平扩容；
- 不要把同一卷挂到多个副本；
- 删除服务时保留 Volume；
- 迁移或升级前先备份 `/app/data`。

Northflank 的单读写卷会在重启时先停止旧容器再挂载新容器，这是本项目使用 SQLite 时的正确部署方式。

### 5. 设置运行时变量

在 **Environment / Runtime variables** 添加：

```text
FORCE_AUTH=true
NZ_JWTSECRETKEY=<随机生成的长字符串>
DASHBOARD_VERSION=v2.3.4
AGENT_VERSION=v2.3.1
TZ=Asia/Shanghai
```

部署完成后，在 Ports & DNS 页面复制 Northflank 的完整公网域名，例如：

```text
web--nezha--abc123.code.run
```

再追加：

```text
NZ_DOMAIN=web--nezha--abc123.code.run
NZ_DASHBOARD_HOST=web--nezha--abc123.code.run
NZ_AGENT_PORT=443
```

这三个域名变量均不能写成 `https://web--...`，也不能带 `/` 或 `:443`。脚本会自动把安装地址拼成 `域名:443`。

如果使用自己的域名，例如 `nezha.example.com`，将 `NZ_DOMAIN` 和 `NZ_DASHBOARD_HOST` 改成该域名，并把它绑定到容器 `80` 这个公网端口。

### 6. 配置健康检查

建议使用 TCP 健康检查（不会依赖 Northflank 到容器的 HTTP/2 cleartext 协商）：

```text
Protocol: TCP
Port: 80
```

首次启动要下载 Dashboard，并可能生成配置，建议给启动留出至少 120 秒，不要用过短的存活检查反复重启容器。构建结束后检查 Northflank Runtime logs，正常日志至少应包含 Dashboard V2 已就绪、Dashboard 启动和 nginx 启动后的常驻进程。

### 7. 首次访问

访问 Northflank 公网域名，进入管理页 `/dashboard`。官方 V2 文档说明首次默认用户名和密码通常都是 `admin`；首次登录后立即修改密码，并建议使用至少 18 位、包含大小写、数字和符号的密码。

若修改过 `NZ_JWTSECRETKEY`，需要重新部署/重启服务，旧登录态可能失效，这是主动轮换密钥的预期行为。

## 添加外部服务器 Agent

外部服务器不要手写旧版 Agent 命令，按 V2 官方流程操作：

1. 登录 Dashboard；
2. 进入“服务器”；
3. 新建服务器；
4. 点击“安装命令”；
5. 选择目标操作系统；
6. 在目标服务器执行生成的命令；
7. 返回 Dashboard 确认服务器上线。

V2 Agent 的 `client_secret` 与用户绑定，安装命令中的 `NZ_CLIENT_SECRET` 才是正确密钥。V2 Dashboard 和 Agent 的版本号不要求完全相同，但建议使用两个仓库各自的稳定 Release。

面板“系统设置”中的 Agent 对接地址应设置为：

```text
你的 Northflank 域名:443
```

例如：

```text
web--nezha--abc123.code.run:443
```

不要填写容器内部的 `8008`，也不要填写 Northflank 内部服务名。Agent 连接失败时，先确认 Northflank 端口协议是 HTTP/2，而不是普通 HTTP/1.1。

## 容器自监控（可选）

如果希望面板自己也显示为一台被监控服务器：

1. 先完成一次 Dashboard 部署；
2. 在“服务器”中创建一个用于面板容器的服务器；
3. 复制该服务器 UUID；
4. 从该服务器的 V2 安装命令中提取 `NZ_CLIENT_SECRET`；
5. 在 Northflank 设置：

```text
IDU=<服务器 UUID>
NZ_DOMAIN=<Northflank 公网域名>
NZ_AGENT_PORT=443
NZ_SELF_CLIENT_SECRET=<该服务器的 NZ_CLIENT_SECRET>
```

重新部署后，容器会下载 V2 Agent，并使用：

```text
nezha-agent -c /app/config.yml
```

默认关闭命令执行和 NAT，只采集基础指标。若明确需要远程运维，再将 `NZ_AGENT_DISABLE_COMMAND_EXECUTE=false` 或 `NZ_AGENT_DISABLE_NAT=false`，并确认 Dashboard 用户权限和安全策略。

## Cloudflare Tunnel（可选）

Northflank 已经可以提供公网 HTTP/2 和 TLS，所以通常不需要 Argo Tunnel。若你仍要参考 Argo 项目使用 Cloudflare Tunnel：

1. 在 Cloudflare Zero Trust 创建 Named Tunnel；
2. 选择 Docker/Token 连接器方式；
3. 将 Token 放入 Northflank Secret：

```text
ARGO_AUTH=<Cloudflare Tunnel Token>
```

4. 在 Cloudflare Public Hostname 的 Service 中把源站指向：

```text
http://127.0.0.1:80
```

5. 将 `NZ_DOMAIN`、`NZ_DASHBOARD_HOST` 设置为 Cloudflare Public Hostname；
6. Agent 仍连接 `Cloudflare域名:443`。

本项目只支持 Cloudflare Tunnel Token，不支持把 JSON、`cert.pem`、Global API Key 或 Cloudflare API Token 填进 `ARGO_AUTH`。如果 Tunnel 的源站设置为 `https://127.0.0.1:443`，必须在 Cloudflare 中关闭 origin certificate 校验，因为容器内 443 使用的是自签证书；优先使用上面的 HTTP `:80` 源站。

## TSDB 历史指标（可选）

V2 TSDB 默认关闭。要让服务器详情页保存历史指标：

```text
NZ_ENABLE_TSDB=true
NZ_TSDB_DATA_PATH=/app/data/tsdb
NZ_TSDB_RETENTION_DAYS=30
```

路径必须位于持久卷中，否则重建容器后历史指标会丢失。启用 TSDB 前先备份，因为官方说明启用后可能删除旧的 `service_histories` 表，已有服务历史不会自动迁移。

## 数据备份与恢复

最重要的数据都在 `/app/data`。Northflank Volume 是主持久化手段；`scripts/backup.sh` 和 `scripts/restore.sh` 是辅助工具。

在容器 Shell 中执行：

```bash
/app/backup.sh /tmp/nezha-v2-backup.tar.gz
/app/restore.sh /tmp/nezha-v2-backup.tar.gz
```

恢复后重启服务。备份包只包含 `data/`，不包含运行时下载的二进制和自签证书；容器下次启动会重新下载 V2 二进制并重新生成内部证书。

如果需要迁移：

1. 停止旧服务或确保 Dashboard 不再写入数据库；
2. 备份旧的 `/app/data`；
3. 在新 Northflank 服务挂载新的 `/app/data` Volume；
4. 恢复数据；
5. 使用同一套 `NZ_JWTSECRETKEY`、域名和 V2 版本启动；
6. 登录 Dashboard 检查用户、服务器和设置。

只把 V2 数据迁移到 V2。不要直接用 V0/V1 数据库覆盖本项目的数据目录。

## 本地测试

本机需要 Docker：

```bash
docker compose up -d --build
```

访问 `http://127.0.0.1:8080`。本地 Compose 只映射 Web 端口，Agent 对接和 HTTPS 反向代理应按 Northflank 或正式域名环境测试。

## 排障

### 页面打不开

- 查看 Northflank Runtime logs；
- 确认公开的是容器 `80`；
- 确认服务内部监听是 `0.0.0.0`；
- 确认没有把 Northflank 公网域名反向填成容器内部地址。

### 页面能打开，但 Agent 离线

- Northflank 端口协议改为 HTTP/2；
- Dashboard 系统设置中的 Agent 地址使用 `域名:443`；
- 外部 Agent 使用 V2 页面生成的命令和 `NZ_CLIENT_SECRET`；
- 检查 Cloudflare/CDN 是否真正支持 gRPC 和长连接；
- 查看 Agent 日志中的 TLS、认证和连接地址错误。

### WebSocket、终端或文件管理失败

确认请求经过同一个公网域名，且 Nginx 配置中的 `/api/v1/ws/server`、`/terminal`、`/file` 路径没有被其他路由覆盖。Northflank 公网端口需要允许 WebSocket。

### Dashboard 每次重启都像新安装

检查 Volume 是否挂载到准确的 `/app/data`，并确认服务没有误配置为多个副本。容器文件系统中的 `/app` 不是持久化存储，只有 `/app/data` 应被视为数据库和配置的持久位置。

### 启动时下载失败

容器需要访问 `github.com`、`api.github.com` 和 GitHub Release 资源。可以固定 `DASHBOARD_VERSION` / `AGENT_VERSION`，但仍需要在首次启动时下载对应资产。

## 参考资料

- [哪吒 V2 官方文档](https://nezha.wiki/)
- [安装 Dashboard](https://nezha.wiki/guide/dashboard.html)
- [安装 Agent](https://nezha.wiki/guide/agent.html)
- [Dashboard 反向代理配置](https://nezha.wiki/guide/q3.html)
- [哪吒 V2 配置说明](https://nezha.wiki/configuration/dashboard.html)
- [哪吒 V2 版本与兼容性](https://nezha.wiki/guide/version-compatibility.html)
- [Northflank：构建 Dockerfile](https://northflank.com/docs/v1/application/build/build-with-a-dockerfile)
- [Northflank：配置端口](https://northflank.com/docs/v1/application/network/configure-ports)
- [Northflank：公网网络](https://northflank.com/docs/v1/application/network/networking-on-northflank)
- [Northflank：持久卷](https://northflank.com/docs/v1/application/databases-and-persistence/add-a-volume)
- [fscarmen2/Argo-Nezha-Service-Container](https://github.com/fscarmen2/Argo-Nezha-Service-Container)
- [Kiritocyz/Argo-Nezha-Service-Container](https://github.com/Kiritocyz/Argo-Nezha-Service-Container)
- [IonRh/nezha_v1](https://github.com/IonRh/nezha_v1)
