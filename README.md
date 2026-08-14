# 哪吒面板 V2 Northflank 部署

本项目用于构建哪吒监控 V2 容器，仅支持 `nezhahq/nezha` V2，不兼容 V1、V0 或旧版 `naiba/nezha`。

容器启动时会完成以下工作：

- 下载指定版本的哪吒 Dashboard 二进制；
- 可选下载哪吒 Agent，用于监控面板所在的容器；
- 生成并修补 `data/config.yaml`；
- 使用 nginx 将 Web、WebSocket 和 gRPC 转发到 Dashboard 的 `8008` 端口；
- 可选启用 Cloudflare Tunnel、TSDB 和 GitHub 加密备份。

## 部署前的重要结论

Northflank 部署时请遵循下面三点：

1. 只把容器端口 `80` 配置为公开端口，并将协议设置为 `HTTP/2`；
2. 将 Northflank 持久卷挂载到 `/app/data`，服务副本数保持为 `1`；
3. Agent 连接地址使用 Northflank 公网域名的 `443` 端口，例如 `xxx.code.run:443`。

Northflank 会在边缘自动提供 HTTPS，并把请求转发到容器的 `80` 端口。容器内部的 nginx `443` 监听仅用于普通 VPS 场景，在 Northflank 中不要将容器 `443` 配置为公网端口。

## 工作原理

```text
浏览器 / Agent
      │ HTTPS / HTTP2 / gRPC
      ▼
Northflank 公网域名 :443
      │ Northflank 边缘终止 TLS
      ▼
容器 :80（nginx，HTTP/2）
      ├── Web / REST / WebSocket  ──► Dashboard :8008
      └── /proto.NezhaService/    ──► Dashboard :8008（gRPC）
```

Dashboard、WebSocket 和 gRPC 共用内部 `8008` 端口。Northflank 的公网端口是容器端口的映射，不需要让 Dashboard 直接监听公网端口。

## 版本与兼容性

- 默认 Dashboard 版本：`v2.3.4`；
- 默认 Agent 版本：`v2.3.3`；
- 自动更新只跟踪 `v2.x`，不会自动升级到 V3；
- Dashboard 下载文件名为 `dashboard-linux-${ARCH}.zip`；
- Agent 下载文件名为 `nezha-agent_linux_${ARCH}.zip`；
- 支持 `amd64`、`arm64` 和 `s390x` 架构。

官方发布页：

- [哪吒 Dashboard Releases](https://github.com/nezhahq/nezha/releases)
- [哪吒 Agent Releases](https://github.com/nezhahq/agent/releases)

生产环境建议固定版本，避免上游发布新版本后自动更新导致行为变化：

```text
DASHBOARD_VERSION=v2.3.4
AGENT_VERSION=v2.3.3
```

## 目录结构

```text
.
├── Dockerfile              # 基于 nginx:alpine 构建容器
├── nginx/
│   └── nezha.conf          # nginx 反向代理配置
├── docker-compose.yml      # 本地测试配置
├── scripts/
│   ├── start.sh            # 容器入口、初始化、看门狗
│   ├── renew.sh            # V2 自动更新
│   ├── backup.sh           # GitHub 加密备份
│   ├── restore.sh           # GitHub 启动恢复
│   └── restart.sh           # 手动重启 Dashboard
└── README.md
```

推送到 GitHub 前，确认 `nginx/` 和 `scripts/` 已经加入 Git。可以执行：

```bash
git status
git add Dockerfile docker-compose.yml README.md nginx scripts .dockerignore
git commit -m "prepare nezha v2 northflank deployment"
git push
```

## 环境变量

### 必填变量

| 变量            | 示例                         | 说明                                                                                                  |
| ------------- | -------------------------- | --------------------------------------------------------------------------------------------------- |
| `NZ_AGENTKEY` | `use-a-long-random-secret` | Dashboard 与 Agent 的通信密钥。会写入 `data/config.yaml` 的 `agent_secret_key`，也是容器内置 Agent 的 `client_secret`。 |

`NZ_AGENTKEY` 必须使用长随机字符串，不要使用 Compose 文件里的示例值，也不要公开提交到 Git 仓库。

### 推荐变量

| 变量                  | 示例                           | 说明                                                        |
| ------------------- | ---------------------------- | --------------------------------------------------------- |
| `FORCE_AUTH`        | `true`                       | `true` 强制登录；`false` 允许访客查看公开状态页。生产环境建议使用 `true`。          |
| `NZ_JWTSECRETKEY`   | `another-long-random-secret` | 固定 JWT 签名密钥，避免 Dashboard 自动轮换后用户频繁掉线。                     |
| `NZ_DASHBOARD_HOST` | `xxx.code.run`               | Dashboard 对外访问域名，不带 `https://`、路径或端口。用于 OAuth2 回调和反向代理场景。 |
| `DASHBOARD_VERSION` | `v2.3.4`                     | 固定 Dashboard 版本。设置后不会自动更新 Dashboard。                      |
| `AGENT_VERSION`     | `v2.3.3`                     | 固定容器内置 Agent 版本。设置后不会自动更新 Agent。                          |

### 可选变量

| 变量                               | 说明                                                               |
| -------------------------------- | ---------------------------------------------------------------- |
| `NZ_DOMAIN`                      | 配置给 Agent 使用的公网域名。与 `IDU` 同时填写时，容器会启动内置 Agent。只填写域名，不要填写 `https://`；如果使用 Cloudflare Tunnel，需要与 Public Hostname 完全一致。 |
| `IDU`                            | 面板自监控服务器对应的 UUID。建议使用哪吒面板中该服务器的实际 UUID。                          |
| `ARGO_AUTH`                      | Cloudflare Tunnel Token。当前脚本只支持 Token，不支持 JSON；设置后会启动 cloudflared。 |
| `NZ_EXTRA_USER_THEME`            | 自定义用户主题 ZIP 下载地址。                                                |
| `NZ_ENABLE_TSDB`                 | 设置为 `true` 启用 TSDB 历史指标，设置为 `false` 关闭。                          |
| `NZ_TSDB_DATA_PATH`              | TSDB 路径。Northflank 建议设置为 `/app/data/tsdb`。                       |
| `NZ_TSDB_RETENTION_DAYS`         | TSDB 保留天数，默认值为脚本配置的值。                                            |
| `NZ_TSDB_MIN_FREE_DISK_SPACE_GB` | TSDB 最低剩余磁盘空间。                                                   |
| `NZ_TSDB_MAX_MEMORY_MB`          | TSDB 最大缓存内存。                                                     |
| `GITHUB_USERNAME`                | GitHub 用户名。备份功能四个变量必须同时填写。                                       |
| `REPO_NAME`                      | GitHub 专用备份仓库名。建议使用私有仓库。                                         |
| `GITHUB_TOKEN`                   | 具有目标仓库读写权限的 Token。                                               |
| `ZIP_PASSWORD`                   | 备份 ZIP 的密码。请保存好，丢失后无法恢复备份。                                       |
| `TZ`                             | 时区，默认 `Asia/Shanghai`。                                           |

## 使用 Northflank 从 Git 部署

这是推荐方式。Northflank 会从 GitHub 拉取代码、构建 Dockerfile，并运行生成的镜像。

### 1. 准备 Git 仓库

将本目录推送到 GitHub 或 Northflank 支持的 Git 仓库。仓库根目录必须包含：

```text
Dockerfile
docker-compose.yml
nginx/nezha.conf
scripts/start.sh
```

不要把 `data/`、真实密钥或 GitHub Token 提交到仓库。

### 2. 创建 Northflank 服务

1. 登录 Northflank，创建一个 Project；
2. 添加 Deployment Service；
3. 选择 **Build from Git**；
4. 连接包含本项目的 Git 仓库；
5. 选择分支，例如 `main`；
6. 构建方式选择 Dockerfile；
7. Dockerfile 路径填写 `/Dockerfile`；
8. Build Context 使用仓库根目录；
9. 创建并等待首次构建。

Dockerfile 不需要 Build Arguments。所有配置都通过运行时环境变量注入。

### 3. 配置公网端口

进入服务的 **Ports & DNS** 页面，手动配置以下端口：

| 项目             | 配置                         |
| -------------- | -------------------------- |
| Container port | `80`                       |
| Protocol       | `HTTP/2`                   |
| Public         | 开启                         |
| Domain         | 使用 Northflank 自动域名或绑定自己的域名 |

哪吒 Agent 的连接是 gRPC，因此这里必须选择 `HTTP/2`。普通 HTTP/1.1 端口虽然可以打开网页，但可能导致 Agent 连接失败。

Dockerfile 中声明了 `80` 和 `443` 两个端口。Northflank 可能会自动检测出两个端口，请删除或不要公开容器 `443`，只保留容器 `80` 的 HTTP/2 公网端口。

Northflank 对外会使用 `80/443`，但内部请求会被转发到你配置的容器端口 `80`。因此 Agent 使用：

```text
https://你的Northflank域名
Agent server: 你的Northflank域名:443
```

参考：

- [Northflank 配置端口](https://northflank.com/docs/v1/application/network/configure-ports)
- [Northflank 网络说明](https://northflank.com/docs/v1/application/network/networking-on-northflank)

### 4. 配置持久化磁盘

哪吒 Dashboard 的数据库和配置位于 `/app/data`，至少需要持久化：

```text
Container mount path: /app/data
```

建议容量从 `1 GB` 开始，根据监控服务器数量和历史数据量调整。

Northflank 持久卷默认是单实例读写模式，因此：

- Service replicas 必须设置为 `1`；
- 不要启用水平扩容；
- 不要同时挂载同一个 SQLite 数据卷到多个实例；
- 重新部署或重启时保留该 Volume。

如果启用 TSDB，建议同时设置：

```text
NZ_ENABLE_TSDB=true
NZ_TSDB_DATA_PATH=/app/data/tsdb
```

否则脚本默认使用 `/app/tsdb`，该路径不在 `/app/data` 持久卷内，重建容器后可能丢失 TSDB 历史数据。

参考：[Northflank 持久卷](https://northflank.com/docs/v1/application/databases-and-persistence/add-a-volume)

### 5. 配置运行时环境变量

在 Northflank 的 **Environment** 或 **Runtime Variables** 页面添加以下变量。

最小可用配置：

```text
NZ_AGENTKEY=<一段长随机字符串>
FORCE_AUTH=true
NZ_DASHBOARD_HOST=<Northflank分配的公网域名>
DASHBOARD_VERSION=v2.3.4
AGENT_VERSION=v2.3.3
```

示例：

```text
NZ_AGENTKEY=replace-with-a-long-random-secret
FORCE_AUTH=true
NZ_JWTSECRETKEY=replace-with-another-long-random-secret
NZ_DASHBOARD_HOST=web--nezha--abc123.code.run
DASHBOARD_VERSION=v2.3.4
AGENT_VERSION=v2.3.3
TZ=Asia/Shanghai
```

其中 `NZ_AGENTKEY` 和 `NZ_JWTSECRETKEY` 应在 Northflank 中标记为 Secret，不要放在公开仓库或 README 中。

如果使用自定义域名，`NZ_DASHBOARD_HOST` 填最终用户访问的域名，例如：

```text
NZ_DASHBOARD_HOST=nezha.example.com
```

不要填写：

```text
https://nezha.example.com/
```

### 6. 配置健康检查

推荐配置一个 HTTP 健康检查：

```text
Protocol: HTTP
Port: 80
Path: /
```

首次启动需要下载二进制并生成配置，时间可能比普通 Web 服务更长。建议使用 Startup Probe，或者给健康检查预留至少 120 秒启动时间：

```text
Initial delay: 120s
Period: 30s
Timeout: 10s
Failure threshold: 6
```

不要在首次部署时配置过于激进的 Liveness Probe，否则容器可能在下载完成前被反复重启。

参考：[Northflank 健康检查](https://northflank.com/docs/v1/application/observe/configure-health-checks)

### 7. 部署并查看日志

点击 Deploy，打开 Northflank 的 Logs 页面。

正常启动时大致会经历：

1. 检查 `NZ_AGENTKEY`；
2. 尝试恢复 GitHub 备份（如果配置了备份变量）；
3. 生成自签证书；
4. 下载 Dashboard 和可选的 Agent；
5. 首次运行 Dashboard 生成 `data/config.yaml`；
6. 写入 `agent_secret_key`、`listen_port`、`force_auth` 等配置；
7. 启动 Dashboard、nginx 和可选 Agent；
8. 开始监听容器 `80` 端口。

如果日志出现下载失败，优先检查容器是否可以访问：

```text
https://github.com
https://api.github.com
```

### 8. 首次访问面板

1. 打开 Northflank 分配的公网域名；
2. 等待初始化页面加载；
3. 设置管理员账号和密码；
4. 登录后立即修改默认或临时密码；
5. 确认面板首页可以正常加载服务器列表和监控数据。

如果页面可以打开但一直转圈，先检查 Northflank 端口是否为 `HTTP/2`，然后检查日志中是否有 gRPC 或 WebSocket 错误。

## 添加被监控服务器

### 推荐方式：使用面板生成安装命令

1. 登录 Dashboard；
2. 进入服务器管理页面；
3. 新建服务器；
4. 选择对应操作系统；
5. 复制面板生成的 Agent 安装命令；
6. 在被控服务器上执行命令；
7. 等待服务器出现在 Dashboard 首页。

V2 的 Agent 连接密钥绑定到用户。使用面板生成命令时，应使用命令里的 `NZ_CLIENT_SECRET`，不要擅自把容器的 `NZ_AGENTKEY` 当成外部服务器的 `client_secret`。

哪吒 Agent 文档：[安装 Agent](https://nezha.wiki/en_US/guide/agent)

### 面板通信地址

在哪吒 Dashboard 的系统设置中，填写 Agent 连接地址：

```text
你的Northflank域名:443
```

例如：

```text
web--nezha--abc123.code.run:443
```

如果使用自定义域名：

```text
nezha.example.com:443
```

不要在这里填写容器内部的 `8008`，也不要填写 Northflank 的内部服务名。

## 配置容器自监控

如果希望哪吒面板同时监控自己所在的 Northflank 容器，可以设置：

```text
NZ_DOMAIN=<Northflank公网域名>
IDU=<面板中自监控服务器的UUID>
```

例如：

```text
NZ_DOMAIN=web--nezha--abc123.code.run
IDU=11111111-2222-3333-4444-555555555555
```

两个变量必须同时填写。脚本会在容器内生成 `/app/config.yml`，并启动 `nezha-agent` 连接：

```text
${NZ_DOMAIN}:443
```

自监控 Agent 使用 `NZ_AGENTKEY` 作为 `client_secret`。如果 Agent 连接不上，依次检查：

- `NZ_DOMAIN` 是否只包含域名；
- Northflank 容器端口 `80` 是否配置为 HTTP/2；
- `IDU` 是否对应 Dashboard 中的服务器 UUID；
- Dashboard 的 `agent_secret_key` 是否已经写入；
- Northflank 日志中是否出现 Agent 认证失败。

## 使用 Cloudflare Tunnel 自定义域名（Token 模式）

本项目支持通过 Cloudflare Tunnel 使用自定义域名访问面板。

本项目当前只支持 **Cloudflare Tunnel Token**，不使用 JSON 配置。启动脚本实际执行的是：

```bash
cloudflared tunnel --protocol http2 run --token "$ARGO_AUTH"
```

因此不要把 JSON 配置、`cert.pem`、Cloudflare API Token 或 Global API Key 填入 `ARGO_AUTH`。

域名由 Cloudflare 的 **Public Hostname** 配置，以及本项目的 `NZ_DOMAIN`、`NZ_DASHBOARD_HOST` 两个变量共同完成。

### 变量关系

| 变量 | 用途 | 示例 |
|---|---|---|
| `NZ_DOMAIN` | 哪吒 Agent 的连接域名；同时用于生成安装地址和容器自监控 Agent 的连接地址 | `nazha.example.com` |
| `NZ_DASHBOARD_HOST` | Dashboard 对外访问域名，主要用于 OAuth2 回调、反向代理和 NAT 保留域名 | `nazha.example.com` |
| `ARGO_AUTH` | Cloudflare Tunnel Token，只填 Token 字符串 | `eyJhIjoi...` |
| `IDU` | 可选。填写后启动容器内置自监控 Agent | `11111111-2222-3333-4444-555555555555` |

如果使用同一个域名访问面板并连接 Agent，推荐四项这样填写：

```text
NZ_DOMAIN=nazha.example.com
NZ_DASHBOARD_HOST=nazha.example.com
ARGO_AUTH=<Cloudflare Tunnel Token>
IDU=<可选的自监控服务器UUID>
```

`NZ_DOMAIN` 和 `NZ_DASHBOARD_HOST` 只填写域名，不要包含：

```text
https://
http://
/
:443
```

### 第一步：在 Cloudflare 创建 Tunnel

1. 登录 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)；
2. 进入 **Networks → Tunnels**；
3. 创建一个 Named Tunnel；
4. 在 Tunnel 的连接器页面选择 Docker 或 Token 方式；
5. 复制 Cloudflare 生成的 Tunnel Token；
6. 将 Token 写入 Northflank 的 Secret 环境变量：

   ```text
   ARGO_AUTH=<完整的Cloudflare Tunnel Token>
   ```

Token 通常是一段很长的字符串，常见形式以 `eyJ` 开头。不要手动添加换行，也不要把 Token 截断。

### 第二步：配置 Public Hostname

在刚创建的 Tunnel 中添加 **Published application / Public Hostname**：

```text
Hostname: nazha.example.com
```

当前容器内 nginx 同时监听 `80` 和 `443`。如果要尝试让 Cloudflare Tunnel 同时承载网页和 Agent 的 TLS/gRPC 流量，回源 Service 可设置为：

```text
https://localhost:443
```

容器的 `443` 使用启动脚本生成的自签名证书，因此在 Cloudflare Tunnel 的 Origin Parameters 中关闭源站证书校验：

```text
No TLS Verify: Enabled
HTTP/2 to Origin: Enabled（如果控制台提供此选项）
```

如果只需要通过 Tunnel 访问网页，也可以将 Service 设置为：

```text
http://localhost:80
```

该配置只适合网页访问；哪吒 Agent 使用 gRPC，网页能打开并不代表 Agent 一定能通过 Tunnel 上线。生产环境请优先准备 Northflank 的 HTTP/2 公网域名作为 Agent 回退地址，详见下方“关于 gRPC 的兼容性”。

`ARGO_AUTH` 只负责让容器内的 `cloudflared` 连接到已有 Tunnel，不会自动创建 Public Hostname、DNS 记录或回源 Service；这些仍需在 Cloudflare 控制台完成。

Cloudflare 官方文档中，Published application 的核心就是把公网 hostname 映射到本地服务，例如 `http://localhost:80`；如果使用 HTTPS 回源，则需要配置 `https://localhost:443` 及源站 TLS 参数。[Cloudflare Tunnel 路由文档](https://developers.cloudflare.com/tunnel/routing/)

### 第三步：检查 DNS

如果通过 Cloudflare 控制台为 Tunnel 添加 Public Hostname，Cloudflare 通常会自动创建指向 Tunnel 的 DNS 记录。

手动配置时，应创建：

```text
Type: CNAME
Name: nazha
Target: <Tunnel UUID>.cfargotunnel.com
Proxy status: Proxied
```

最终访问域名应为：

```text
https://nazha.example.com
```

不要只创建一个普通 A 记录指向 Northflank 或其他服务器 IP。Cloudflare Tunnel 需要将域名指向对应的 `<Tunnel UUID>.cfargotunnel.com`。 [Cloudflare Tunnel DNS 文档](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/)

### 第四步：配置 Northflank

Northflank 中建议保留一个容器 `80` 的公网 HTTP/2 端口，用于健康检查和备用访问：

```text
Container port: 80
Protocol: HTTP/2
Public: Enabled
```

不要把容器 `443` 再配置成 Northflank 公网端口。Cloudflare Tunnel 访问的是同一个容器内部的 `localhost:443`，不是 Northflank 的公网端口。

推荐的完整环境变量：

```text
NZ_AGENTKEY=<哪吒Agent密钥>
NZ_JWTSECRETKEY=<固定JWT密钥>
FORCE_AUTH=true
NZ_DOMAIN=nazha.example.com
NZ_DASHBOARD_HOST=nazha.example.com
ARGO_AUTH=<Cloudflare Tunnel Token>
```

如果不需要容器自监控，不填写 `IDU`。如果需要自监控，将哪吒面板中对应服务器的 UUID 填入：

```text
IDU=<服务器UUID>
```

### 第五步：验证访问链路

部署完成后，按顺序检查：

1. Cloudflare Tunnel 状态为 **Healthy**；
2. Tunnel 至少有一个在线 Connector；
3. Public Hostname 与 `NZ_DOMAIN` 完全一致；
4. Service URL 为 `https://localhost:443` 或 `http://localhost:80`；
5. Northflank 容器正在运行；
6. 容器内 nginx 已监听 `80/443`；
7. 访问：

   ```text
   https://nazha.example.com
   ```

如果网页打不开，可以在 Northflank Terminal 中检查容器内部服务：

```bash
pgrep -af cloudflared
wget -S -O - http://127.0.0.1:80/
wget --no-check-certificate -S -O - https://127.0.0.1:443/
```

结果判断：

| 现象 | 常见原因 |
|---|---|
| `404` | Public Hostname 没有配置为 `nazha.example.com`，或 Hostname 拼写不一致 |
| `502` | Tunnel 已连接，但 `localhost:80/443` 回源失败 |
| `1016` | DNS 指向 Tunnel，但没有在线 Connector |
| 网页能打开、Agent 不上线 | gRPC/HTTP2 回源未开启，或 Agent 密钥不匹配 |
| 容器没有 `cloudflared` 进程 | Token 无效、下载失败或 Tunnel 启动失败 |

注意：当前脚本会将 cloudflared 的标准输出写入 `/dev/null`。如果需要查看 Tunnel 的详细错误，建议先检查进程状态和 Cloudflare Tunnel 控制台中的 Connector 日志。

### 关于 gRPC 的兼容性

哪吒 Agent 通过 gRPC 连接 Dashboard。Cloudflare 当前文档说明，Tunnel 的 gRPC 支持主要面向私网路由，Public Hostname 的公网发布场景存在产品限制；因此如果网页可以访问但 Agent 始终不上线，最稳妥的方式是：

- Cloudflare 域名用于浏览器访问；
- Northflank 的 HTTP/2 公网域名用于 Agent 通信；
- 将 `NZ_DOMAIN` 改为 Northflank 公网域名；
- 将 `NZ_DASHBOARD_HOST` 保留为 Cloudflare 自定义域名。

例如：

```text
NZ_DOMAIN=web--nezha--abc123.code.run
NZ_DASHBOARD_HOST=nazha.example.com
ARGO_AUTH=<Cloudflare Tunnel Token>
```

这样可以同时保留 Cloudflare 自定义域名访问，并避免 Agent 依赖 Cloudflare Tunnel 的 gRPC 公网转发。详见 [Cloudflare gRPC 文档](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/)。

## 备份与恢复

Northflank 持久卷可以保存正常重启和重新部署的数据，但生产环境仍建议启用异地备份。

同时设置以下四个变量才会启用 GitHub 备份和启动恢复：

```text
GITHUB_USERNAME=<GitHub用户名>
REPO_NAME=<专用私有仓库名>
GITHUB_TOKEN=<具有仓库读写权限的Token>
ZIP_PASSWORD=<备份压缩包密码>
```

备份内容包括：

- `/app/data`；
- Dashboard 配置；
- SQLite 数据库；
- 必要的 Agent 配置。

脚本会在容器运行期间定期检查备份状态，并按 Asia/Shanghai 时区执行每日备份逻辑。备份仓库建议使用专用私有仓库，不要与源代码仓库混用。

注意：

- `GITHUB_TOKEN` 不要提交到 Git；
- `ZIP_PASSWORD` 丢失后无法解密备份；
- GitHub 仓库被删除或 Token 失效时，恢复功能会跳过并继续启动；
- `/app/data` 持久卷和 GitHub 备份最好同时保留。

## 升级与回滚

### 固定版本升级

修改 Northflank 环境变量：

```text
DASHBOARD_VERSION=v2.3.4
AGENT_VERSION=v2.3.3
```

然后触发 Redeploy。只要 `/app/data` 持久卷没有被删除，Dashboard 数据不会因为重新构建镜像而丢失。

### 使用 V2 自动更新

如果不设置 `DASHBOARD_VERSION`，脚本会查询哪吒仓库的最新 `v2.x` 标签，并在运行期间执行更新检查。

生产环境更建议固定版本，确认新版本稳定后再手动修改环境变量并重新部署。

### 回滚

1. 将 `DASHBOARD_VERSION` 改回之前的版本；
2. 将 `AGENT_VERSION` 改回匹配的 Agent 版本；
3. 保留原有 `/app/data` Volume；
4. 重新部署；
5. 如果数据库已经发生不可逆迁移，从 GitHub 备份恢复数据。

## 故障排查

### 1. Northflank 构建失败

检查：

- 构建上下文是否为仓库根目录；
- Dockerfile 路径是否为 `/Dockerfile`；
- `nginx/nezha.conf` 和 `scripts/start.sh` 是否已经提交到 Git；
- Northflank 构建节点是否可以访问 Docker Hub 和 Alpine 软件仓库。

### 2. 容器启动后反复重启

优先查看日志中的第一条 `ERROR`。常见原因：

- 没有设置 `NZ_AGENTKEY`；
- GitHub 下载失败；
- Dockerfile 架构和运行节点不匹配；
- 健康检查启动时间过短；
- 持久卷权限或挂载路径错误。

### 3. 网页打不开

检查：

- Northflank 是否配置了容器端口 `80`；
- 公网协议是否为 HTTP/2；
- 是否错误地只配置了容器端口 `443`；
- nginx 是否已经启动；
- 健康检查是否误判容器未就绪。

### 4. 网页能打开，但 Agent 不上线

检查：

- Northflank 公网端口是否为 HTTP/2；
- Agent 地址是否为 `域名:443`；
- 是否使用了面板生成命令中的 `NZ_CLIENT_SECRET`；
- 自监控场景的 `NZ_DOMAIN` 是否填写了正确域名；
- 是否把 `https://` 或路径错误地写入 `NZ_DOMAIN`；
- 是否将容器 `443` 错误地作为 Northflank 后端端口。

### 5. 页面显示“后端 API 无法访问”或一直转圈

哪吒实时数据使用 WebSocket，Agent 使用 gRPC。检查 nginx 反代路径：

```text
/proto.NezhaService/  -> gRPC -> 127.0.0.1:8008
/api/v1/ws/           -> WebSocket -> 127.0.0.1:8008
/                    -> HTTP -> 127.0.0.1:8008
```

Northflank 端口类型配置错误时，通常网页仍可能打开，但 gRPC 或 WebSocket 会失败。

### 6. 重启后数据丢失

检查：

- Volume 是否挂载到 `/app/data`；
- 是否误挂载到 `/app` 或 `/dashboard/data`；
- 是否删除了原 Volume；
- 是否启用了多个副本；
- TSDB 是否写入了未持久化的 `/app/tsdb`。

### 7. 升级后频繁掉线

设置固定 JWT 密钥：

```text
NZ_JWTSECRETKEY=<固定的长随机字符串>
```

修改后重新部署一次，之后不要随意更换该值。更换 JWT 密钥会使已有登录会话失效。

## 本地 Docker 测试

本地测试使用 `docker-compose.yml`：

```bash
docker compose build
docker compose up -d
docker compose logs -f nezha-v2
```

默认访问地址：

```text
http://localhost:8080
```

本地 Compose 会把：

```text
宿主机 ./data  -> 容器 /app/data
宿主机 8080    -> 容器 80
```

启动前请将 Compose 中的 `NZ_AGENTKEY` 替换为真实随机值。停止服务：

```bash
docker compose down
```

## 参考文档

- [Northflank 配置端口](https://northflank.com/docs/v1/application/network/configure-ports)
- [Northflank 网络](https://northflank.com/docs/v1/application/network/networking-on-northflank)
- [Northflank 持久卷](https://northflank.com/docs/v1/application/databases-and-persistence/add-a-volume)
- [Northflank 健康检查](https://northflank.com/docs/v1/application/observe/configure-health-checks)
- [哪吒 Dashboard 配置](https://nezha.wiki/en_US/configuration/dashboard.html)
- [哪吒 Agent 安装](https://nezha.wiki/en_US/guide/agent)
- [哪吒 Dashboard Releases](https://github.com/nezhahq/nezha/releases)
- [哪吒 Agent Releases](https://github.com/nezhahq/agent/releases)

## 免责声明

本项目仅供学习和部署测试使用。哪吒面板包含监控、命令和文件传输等高权限功能，请使用强密码、私有备份仓库和最小权限 Token，并遵守服务器所在地及用户所在地的法律法规。

## 许可证

本项目采用 MIT 许可证。完整的许可证文本如下：

```text
MIT License

Copyright (c) 2026 ydmmocoo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
