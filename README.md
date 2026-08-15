# Nezha V2 + Argo Tunnel Container

这是一个面向哪吒监控 V2 的单容器部署方案，参考了 [Kiritocyz/Argo-Nezha-Service-Container](https://github.com/Kiritocyz/Argo-Nezha-Service-Container) 的 Argo、反代和 GitHub 备份思路，并按 V2 当前的 Dashboard/Agent 发布包重新实现。

本项目只支持哪吒 V2，不兼容 V1 或 V0。容器内包含：

- 哪吒 V2 Dashboard
- 哪吒 V2 Agent（默认内置本机探针，配置密钥后启动）
- Caddy 反向代理，兼容普通 HTTP、WebSocket 和 gRPC/h2c 回源
- Cloudflare Tunnel（Argo）token 或 JSON 凭据模式
- 每日 Dashboard 更新
- 每日同步上游安装脚本，并可选同步本项目脚本
- 每日将哪吒数据、隧道凭据和本机 Agent 配置备份到 GitHub
- 保留指定数量的历史备份，并支持从 GitHub 手动恢复
- 无持久化磁盘时，启动前自动从 GitHub 恢复最近备份

## 运行结构

```text
Cloudflare Edge
      │  HTTPS / WebSocket / gRPC
      ▼
cloudflared Tunnel
      ▼
Caddy :8080  ── HTTP/2 h2c / WebSocket ──▶ Dashboard :8008
                                                  │
                                                  └── SQLite / data
```

Northflank 不需要额外公网入口。免费实例没有持久化卷时，容器会在启动前从 GitHub 私有备份仓库自动恢复最近的 SQLite 和配置；因此必须配置 `GH_REPO`、`GH_PAT`，并确保至少成功生成过一次备份。Cloudflare Tunnel 本身是由容器主动连接 Cloudflare 边缘的连接器。[Cloudflare Tunnel 文档](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) 和 [cloudflared 项目说明](https://github.com/cloudflare/cloudflared) 可供核对。

## 一、部署前准备

### 1. 准备 Cloudflare 域名

1. 将域名托管到 Cloudflare。
2. 准备一个单独的子域名，例如 `nezha.example.com`。
3. 在 Cloudflare Zero Trust → Networks → Tunnels 创建 Tunnel。
4. 为该 Tunnel 添加 Public Hostname：
   - Hostname：`nezha.example.com`
   - Service Type：`HTTP`
   - URL：任意可用的本地占位地址即可，例如 `http://127.0.0.1:8080`
5. 记录 Tunnel Token，或者下载 Tunnel JSON 凭据。

优先使用 `ARGO_TOKEN`。如果使用 JSON，请把 JSON 原文完整放入 `ARGO_AUTH`，不要额外套 Markdown 代码块。JSON 至少需要包含 `TunnelID`、`AccountTag`、`TunnelSecret` 等 Cloudflare 凭据字段。

如果要通过 Cloudflare CDN 传输 Agent 的 gRPC 流量，请在 Cloudflare 域名的 Network 设置中启用 gRPC。使用 HTTPS 入口时，Agent 的 `tls` 应为 `true`。

### 2. 准备 GitHub 备份仓库

1. 创建一个 GitHub 私有仓库，例如 `your-user/nezha-backup`。
2. 创建 PAT，并授予该私有仓库的 `repo` 权限；如果组织启用了 SSO，还要完成 SSO 授权。
3. 保存仓库全名和 PAT。

备份包含 SQLite 数据库、Dashboard 配置、Cloudflare Tunnel 凭据和本机 Agent 配置，必须使用私有仓库。不要把 `GH_PAT` 提交到本项目，也不要将备份仓库改为公开。

### 3. 准备本机 Agent 密钥

V2 的 `client_secret` 与用户绑定，不能使用 V0 时代的全局 `agent_secret_key`。第一次启动后：

1. 打开 `https://你的 ARGO_DOMAIN/dashboard`。
2. 使用初始账号 `admin` / `admin` 登录，并立即修改密码。
3. 进入服务器页面，点击“添加服务器”，名称填写 `本机探针`。
4. 复制生成的安装命令，从中取出 `NZ_CLIENT_SECRET` 的值。
5. 将该值填入 Northflank 的 `LOCAL_AGENT_SECRET`，重新部署/重启服务。

容器会使用这个密钥启动内置 Agent。由于 Agent 与 Dashboard 在同一个容器内，默认直接连接 `127.0.0.1:8008`，不经过 Argo 公网域名；这样可以避免 Cloudflare Public Hostname 对 gRPC 的限制。V2 官方文档也说明，Agent 连接密钥应从服务器页面生成的安装命令中取得。[Agent 配置](https://nezha.wiki/configuration/agent.html) 和 [服务器管理](https://nezha.wiki/guide/servers.html)。

## 二、Northflank 部署

下面以将本仓库直接部署到 Northflank 为例。

### 1. 创建项目和服务

1. 将本仓库推送到 GitHub。
2. 在 Northflank 创建 Project。
3. 选择 **Add service → Build service**。
4. 连接本项目 GitHub 仓库，分支选择 `main`。
5. Build method 选择 **Dockerfile**，路径填写 `/Dockerfile`。
6. Service port 添加 `8080`，协议选择 HTTP。
7. 持久化卷是可选的。免费实例无法挂载卷时，必须配置 GitHub 备份，并保持 `AUTO_RESTORE_ON_START=true`；如果可以使用卷，仍建议挂载到 `/opt/nezha/data` 以减少恢复等待时间。
8. CPU 建议至少 0.25 vCPU，内存建议至少 512 MiB。

Northflank 的端口只是容器健康检查和平台路由；实际的 Dashboard 公网地址使用 Argo 域名。若 Northflank 自动注入 `PORT`，入口脚本会优先使用该端口；否则使用 `HTTP_PORT=8080`。

### 2. 添加环境变量

在 Northflank 的 **Secrets / Environment variables** 中添加下面的变量。敏感值都应使用 Secret 类型。

| 变量 | 必填 | 示例 | 说明 |
|---|---:|---|---|
| `ARGO_DOMAIN` | 是 | `nezha.example.com` | Cloudflare Tunnel 的公网 Hostname，不要带 `https://` |
| `ARGO_TOKEN` | 与 JSON 二选一 | `eyJh...` | 推荐，Cloudflare Tunnel Token |
| `ARGO_AUTH` | 与 Token 二选一 | `{ "AccountTag": ... }` | JSON 凭据原文 |
| `GH_REPO` | 是（启用备份时） | `user/nezha-backup` | GitHub 私有备份仓库 |
| `GH_PAT` | 是（启用备份时） | `ghp_...` | GitHub PAT，建议只授予目标仓库权限 |
| `GH_BRANCH` | 否 | `main` | 备份分支，默认 `main` |
| `BACKUP_RETENTION` | 否 | `7` | GitHub 中保留的归档数量，默认 7 |
| `AUTO_RESTORE_ON_START` | 否 | `true` | 本地没有 `sqlite.db` 时，启动前从 GitHub 恢复最新备份 |
| `LOCAL_AGENT_ENABLED` | 否 | `true` | 默认启用内置本机 Agent |
| `LOCAL_AGENT_SECRET` | 本机探针需要 | `NZ_CLIENT_SECRET` | V2 “添加服务器”生成的连接密钥 |
| `LOCAL_AGENT_SERVER` | 否 | `127.0.0.1:8008` | 内置 Agent 默认直连同容器 Dashboard |
| `LOCAL_AGENT_TLS` | 否 | `false` | 本机直连 Dashboard 使用明文 h2c，不经过 Argo |
| `LOCAL_AGENT_DISABLE_COMMAND_EXECUTE` | 否 | `true` | 默认禁止本机 Agent 执行面板下发命令 |
| `NZ_SITE_NAME` | 否 | `Nezha V2` | 初始站点名称 |
| `NZ_LANGUAGE` | 否 | `zh_CN` | 初始后台语言 |
| `UPDATE_TIME` | 否 | `0 3 * * *` | 每日更新时间，容器时区为上海 |
| `BACKUP_TIME` | 否 | `0 4 * * *` | 每日备份时间，容器时区为上海 |
| `DASHBOARD_VERSION` | 否 | `latest` | 固定版本号时跳过自动面板升级 |
| `UPSTREAM_DASHBOARD_SCRIPT_URL` | 否 | 官方 raw URL | 每日同步哪吒 Dashboard 安装脚本 |
| `UPSTREAM_AGENT_SCRIPT_URL` | 否 | 官方 raw URL | 每日同步哪吒 Agent 安装脚本 |
| `SELF_UPDATE_REPO` | 否 | `user/this-repo` | 每日同步本项目 `scripts/` |
| `SELF_UPDATE_BRANCH` | 否 | `main` | 自定义脚本分支 |
| `SELF_UPDATE_TOKEN` | 否 | `ghp_...` | 自定义仓库为私有仓库时使用 |

保存环境变量后部署。首次启动日志应能看到：

```text
[info] Nezha V2 Argo container starting
[info] 启动 Cloudflare Tunnel token 模式
```

如果尚未填写 `LOCAL_AGENT_SECRET`，日志会出现 warning，但 Dashboard、反代和 Tunnel 仍会正常运行；填入密钥并重启后本机 Agent 才会上线。无持久化卷时，启动日志还应出现：

```text
[startup-restore] restored nezha-v2-...tar.gz from GitHub before Dashboard startup
```

如果没有可用备份，日志会明确提示，容器会使用全新的 `admin/admin` 数据库启动。

### 3. 访问面板

访问：

```text
https://nezha.example.com/dashboard
```

默认账号为 `admin`，默认密码为 `admin`。首次登录后立即修改密码，并建议启用强密码。哪吒官方安装文档也明确提醒默认密码较弱。[Dashboard 安装文档](https://nezha.wiki/guide/dashboard.html)。

## 三、Docker Compose 部署

本仓库已经提供 `docker-compose.yml` 和 `.env.example`：

```bash
cp .env.example .env
# 编辑 .env，至少填写 ARGO_DOMAIN、ARGO_TOKEN、GH_REPO、GH_PAT
docker compose up -d --build
docker compose logs -f nezha-v2-argo
```

如果使用 JSON 凭据，将 `ARGO_TOKEN` 留空并填入 `ARGO_AUTH`。数据保存在 Docker volume `nezha-data`。

## 四、自动任务说明

容器内置 Alpine cron，默认使用 `Asia/Shanghai` 时区：

| 时间 | 任务 |
|---|---|
| 每次启动 | 当 `data/sqlite.db` 不存在时，从 GitHub 恢复最近备份后再启动 Dashboard |
| 每日 03:00 | 检查并下载最新 Nezha V2 Dashboard；同步官方脚本，并按需同步本项目脚本 |
| 每日 04:00 | 在线生成 SQLite 一致性备份，打包 `data`、Tunnel 凭据和本机 Agent 配置，推送 GitHub |

Dashboard 更新采用临时目录下载、可执行文件检查和原子替换；更新后只重启 Dashboard runner，不会主动断开 Caddy 或 Tunnel。若更新失败，当前版本保持不变。

手动执行：

```bash
/opt/nezha/scripts/update.sh
/opt/nezha/scripts/backup.sh
```

## 五、备份内容与恢复

备份文件名形如：

```text
nezha-v2-20260814T040000Z.tar.gz
```

归档包括：

- `data/config.yaml`
- `data/sqlite.db`
- `data/agent-config.yml`
- `cloudflared/credentials.json`（JSON 模式时）
- Tunnel 配置及其它持久化状态

### 启动自动恢复

参考项目采用 GitHub 备份仓库作为无持久化容器的数据源。本项目在启动阶段也会执行同样的恢复逻辑：仅当本地不存在 `data/sqlite.db` 时读取备份仓库，优先使用备份仓库 `README.md` 中记录的 `nezha-v2-*.tar.gz`；如果 README 没有记录，则选择最新的 `nezha-v2-*.tar.gz`。参考项目的 `dashboard-*.tar.gz` 可能包含 V0/V1 旧版 OAuth 配置，因此本项目不会自动恢复这类归档。恢复完成后才启动 Dashboard，避免先生成新的 `admin/admin` 数据库。

因此，第一次部署必须先完成一次登录和配置，然后手动执行备份：

```bash
/opt/nezha/scripts/backup.sh
```

之后 Northflank 每次因修改环境变量而重新部署时，会自动恢复 GitHub 中最近一次成功备份。备份仓库必须保持私有，且 `GH_PAT` 需要有读写权限。

### 手动恢复

恢复前建议先备份当前状态。进入容器后执行：

```bash
/opt/nezha/scripts/restore.sh nezha-v2-20260814T040000Z.tar.gz
```

恢复脚本会从 `GH_REPO` 克隆备份仓库，校验文件名和归档中的 `data/` 目录，再覆盖数据。启动自动恢复只在本地没有 `sqlite.db` 时执行，不会在正常运行期间用旧备份覆盖在线数据库。

如果需要迁移到新的 Northflank 服务：

1. 新服务使用相同的 `GH_REPO`、`GH_PAT`、`ARGO_DOMAIN` 和 Argo 凭据。
2. 不挂载卷也可以直接启动，确认 `AUTO_RESTORE_ON_START=true`。
3. 查看日志，确认出现 `[startup-restore] restored ...`。
4. 检查登录、服务器列表、Tunnel 和本机 Agent。

## 六、排障

### Dashboard 打不开

检查：

```bash
curl -fsS http://127.0.0.1:8080/api/v1/setting
```

然后查看 Northflank 日志，确认 `cloudflared` 没有认证错误。若使用 JSON 模式，确认 `ARGO_AUTH` 是完整 JSON 且包含 `TunnelID`。

### Tunnel 在线但域名 502

确认 Cloudflare Public Hostname 的 URL 与容器内部一致，且入口脚本日志没有 `Caddy` 或 Dashboard 退出信息。Caddy 对 gRPC `Content-Type: application/grpc` 使用 h2c 回源，普通页面和 WebSocket 使用常规 HTTP 反代。

### 本机 Agent 不上线

确认：

1. `LOCAL_AGENT_SECRET` 来自 V2“添加服务器”安装命令的 `NZ_CLIENT_SECRET`。
2. `LOCAL_AGENT_SERVER` 应为 `127.0.0.1:8008`，不要填写 Argo 域名。
3. `LOCAL_AGENT_TLS=false`。
4. 如果仍不上线，打开 Agent debug 日志并检查容器日志；外部 Agent 走 Argo 时还需要检查 Cloudflare 的 gRPC/反代配置。

### GitHub 备份失败

确认：

1. `GH_REPO` 为 `owner/repository`，不是仓库网页 URL。
2. 仓库是私有仓库，PAT 对该仓库有写权限。
3. `GH_BRANCH` 存在且默认分支名称正确。
4. 如果没有持久化卷，确认 `AUTO_RESTORE_ON_START=true`，并确认 GitHub 私有仓库中已有 `nezha-v2-*.tar.gz` 归档。

### 固定 Dashboard 版本

设置：

```text
DASHBOARD_VERSION=v2.x.x
```

固定版本后，`update.sh` 不会覆盖 Dashboard，但仍会每日同步脚本和执行 GitHub 备份。恢复为自动更新时，删除该变量或设置为 `latest`。

## 七、文件说明

```text
Dockerfile              构建 V2 Dashboard、V2 Agent、Caddy、cloudflared
entrypoint.sh           生成配置并编排 Dashboard/Caddy/Tunnel/Agent/cron
dashboard-runner.sh     Dashboard 崩溃/升级后的自动重启包装器
caddy/Caddyfile         HTTP、WebSocket、gRPC/h2c 反向代理
scripts/backup.sh       GitHub 私有仓库备份
scripts/restore.sh      GitHub 备份恢复
scripts/restore-on-start.sh 无持久化磁盘时的启动前自动恢复
scripts/update.sh       Dashboard 每日更新
scripts/update-scripts.sh 每日同步官方及自定义脚本
docker-compose.yml      本地 Docker Compose 示例
```

## 八、许可证

本项目自身代码采用 MIT License，完整文本见 [LICENSE](LICENSE)。

本项目会在构建或运行时下载并组合哪吒 V2、哪吒 Agent、Caddy 和 cloudflared，它们仍分别受各自上游许可证约束：哪吒 Dashboard/Agent 使用其上游许可证，Caddy 使用 Apache-2.0，cloudflared 使用其上游 Apache-2.0 许可证。使用者应自行阅读并遵守这些上游项目的许可证、Cloudflare 服务条款以及 GitHub PAT 安全要求。

参考项目：[Kiritocyz/Argo-Nezha-Service-Container](https://github.com/Kiritocyz/Argo-Nezha-Service-Container)
