#!/usr/bin/env bash
#
# Argo-Nezha-Service-Container (Nezha Panel V2)
# 仅兼容哪吒面板 V2（nezhahq/nezha），不兼容 V0 / V1。
# 架构：Dashboard(8008, 统一端口)  ←  Caddy(443, 自签证书, h2c 反代)  ←  Cloudflare Argo Tunnel  ←  公网
# 首次运行下载应用并生成配置；之后若 /etc/supervisor/conf.d/damon.conf 存在则直接拉起守护进程。
#
set -euo pipefail

WORK_DIR=/dashboard
DAEMON_CONF=/etc/supervisor/conf.d/damon.conf

# 统一端口（V2 web + gRPC + WebSocket 共用 8008）
WEB_PORT=8008
GRPC_PORT=8008
# Argo 隧道回源端口（Caddy 在此监听，使用自签证书）
GRPC_PROXY_PORT=443
# Caddy 占用的明文端口（仅本地管理用，避免与 80 冲突）
CADDY_HTTP_PORT=8080

error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info()  { echo -e "\033[32m\033[01m$*\033[0m"; }
hint()  { echo -e "\033[33m\033[01m$*\033[0m"; }

# 带 GitHub 加速网兜底的下载（适合大陆 / IPv6 only 机器）
gh_download() {
  local out="$1" url="$2"
  local proxies=('' 'https://ghproxy.net/' 'https://gh-proxy.com/' 'https://mirror.ghproxy.com/' 'https://ghproxy.lvedong.eu.org/')
  for p in "${proxies[@]}"; do
    if wget -q -T 60 -O "$out" "${p}${url}"; then
      [ -s "$out" ] && return 0
      rm -f "$out"
    fi
  done
  return 1
}

# ============ 仅在首次运行时执行 ============
if [ ! -s "$DAEMON_CONF" ]; then
  info "首次启动：开始初始化哪吒面板 V2 容器 ..."

  # 必备环境变量
  [[ -z "${GH_USER:-}" || -z "${GH_CLIENTID:-}" || -z "${GH_CLIENTSECRET:-}" || -z "${ARGO_AUTH:-}" || -z "${ARGO_DOMAIN:-}" ]] \
    && error "缺少必填环境变量：GH_USER / GH_CLIENTID / GH_CLIENTSECRET / ARGO_AUTH / ARGO_DOMAIN"

  # Argo Auth 容错：json 去掉引号缺失；token 只取 ey 开头的那段
  [[ "$ARGO_AUTH" =~ TunnelSecret ]] && grep -qv '"' <<< "$ARGO_AUTH" && ARGO_AUTH=$(sed 's@{@{"@g;s@[,:]@"\0"@g;s@}@"}@g' <<< "$ARGO_AUTH")
  [[ "$ARGO_AUTH" =~ ey[A-Z0-9a-z=]{120,250}$ ]] && ARGO_AUTH=$(awk '{print $NF}' <<< "$ARGO_AUTH")

  # 架构判定（V2 官方支持 amd64 / arm64 / s390x）
  case "$(uname -m)" in
    x86_64|amd64 )  ARCH=amd64 ;;
    aarch64|arm64 ) ARCH=arm64 ;;
    s390x )         ARCH=s390x ;;
    * ) error "不支持的架构: $(uname -m)（V2 仅支持 amd64 / arm64 / s390x）" ;;
  esac
  info "检测到架构: $ARCH"

  # 时区（北京时间）
  ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true
  dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true

  # ---- 1. 下载 Caddy（反代，V2 统一端口使用 h2c 回源）----
  info "下载 Caddy 反向代理 ..."
  CADDY_VER=$(wget -qO- https://api.github.com/repos/caddyserver/caddy/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"v([0-9.]+)".*/\1/') || true
  CADDY_VER=${CADDY_VER:-2.11.3}
  gh_download "$WORK_DIR/caddy.tar.gz" "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VER}/caddy_${CADDY_VER}_linux_${ARCH}.tar.gz" \
    || error "Caddy 下载失败"
  tar xz -C "$WORK_DIR" -f "$WORK_DIR/caddy.tar.gz" caddy && rm -f "$WORK_DIR/caddy.tar.gz"
  chmod +x "$WORK_DIR/caddy"

  # ---- 2. 下载 cloudflared（Argo 隧道）----
  info "下载 cloudflared ..."
  gh_download "$WORK_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
    || error "cloudflared 下载失败"
  chmod +x "$WORK_DIR/cloudflared"

  # ---- 3. 下载哪吒面板 V2 Dashboard（nezhahq/nezha）----
  info "下载哪吒面板 V2 Dashboard ..."
  if [[ -z "${DASHBOARD_VERSION:-}" ]]; then
    DASH_VER_TAG="latest/download"
  else
    DASH_VER_TAG="download/${DASHBOARD_VERSION}"
  fi
  gh_download "/tmp/dashboard.zip" "https://github.com/nezhahq/nezha/releases/${DASH_VER_TAG}/dashboard-linux-${ARCH}.zip" \
    || error "Dashboard 下载失败（请检查 DASHBOARD_VERSION 是否正确，V2 格式如 v2.3.4）"
  unzip -o /tmp/dashboard.zip -d /tmp >/dev/null 2>&1
  [ -d /tmp/dist ] && mv /tmp/dist/dashboard-linux-"$ARCH" /tmp/dashboard-linux-"$ARCH"
  chmod +x /tmp/dashboard-linux-"$ARCH"
  mv -f /tmp/dashboard-linux-"$ARCH" "$WORK_DIR/app"
  rm -rf /tmp/dashboard.zip /tmp/dist

  # ---- 4. 可选：下载内置本机探针 Agent（nezhahq/agent）----
  if [[ -n "${NZ_AGENTKEY:-}" && -n "${IDU:-}" && -n "${NZ_DOMAIN:-}" ]]; then
    info "下载哪吒 Agent（内置探针）..."
    gh_download "$WORK_DIR/nezha-agent.zip" "https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${ARCH}.zip" \
      || error "Agent 下载失败"
    unzip -o "$WORK_DIR/nezha-agent.zip" -d "$WORK_DIR/" >/dev/null 2>&1
    rm -f "$WORK_DIR/nezha-agent.zip"
    chmod +x "$WORK_DIR/nezha-agent"
    BUILTIN_AGENT=1
  else
    BUILTIN_AGENT=0
    hint "未设置 NZ_AGENTKEY / IDU / NZ_DOMAIN，跳过内置探针；可在面板后台“服务器-安装命令”添加被控端。"
  fi

  # ---- 5. 生成 V2 配置文件 data/config.yaml ----
  [ ! -d "$WORK_DIR/data" ] && mkdir -p "$WORK_DIR/data"
  LANG_VAL=${LANGUAGE:-zh-CN}
  cat > "$WORK_DIR/data/config.yaml" << EOF
Debug: false
HTTPPort: $WEB_PORT
Language: $LANG_VAL
GRPCPort: $GRPC_PORT
GRPCHost: $ARGO_DOMAIN
ProxyGRPCPort: $GRPC_PROXY_PORT
TLS: false
Oauth2:
  Type: "github"
  Admin: "$GH_USER"
  ClientID: "$GH_CLIENTID"
  ClientSecret: "$GH_CLIENTSECRET"
  Endpoint: ""
site:
  Brand: "Nezha Probe"
  Cookiename: "nezha-dashboard"
  Theme: "default"
EOF
  info "已生成 data/config.yaml"

  # ---- 6. 生成自签证书（供 Caddy 回源 Argo 使用）----
  openssl genrsa -out "$WORK_DIR/nezha.key" 2048 2>/dev/null
  openssl req -new -subj "/CN=$ARGO_DOMAIN" -key "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.csr" 2>/dev/null
  openssl x509 -req -days 36500 -in "$WORK_DIR/nezha.csr" -signkey "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.pem" 2>/dev/null

  # ---- 7. 生成 Caddyfile（V2 单端口 h2c 反代）----
  cat > "$WORK_DIR/Caddyfile" << EOF
{
    http_port $CADDY_HTTP_PORT
    admin off
}

:$GRPC_PROXY_PORT {
    reverse_proxy localhost:$GRPC_PORT {
        transport http {
            versions h2c 2
        }
    }
    tls $WORK_DIR/nezha.pem $WORK_DIR/nezha.key
}
EOF

  # ---- 8. 生成 Argo 隧道配置 ----
  if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
    echo "$ARGO_AUTH" > "$WORK_DIR/argo.json"
    cat > "$WORK_DIR/argo.yml" << EOF
tunnel: $(cut -d '"' -f12 <<< "$ARGO_AUTH")
credentials-file: $WORK_DIR/argo.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: https://localhost:$GRPC_PROXY_PORT
    path: /proto.NezhaService/*
    originRequest:
      http2Origin: true
      noTLSVerify: true
  - hostname: $ARGO_DOMAIN
    service: https://localhost:$GRPC_PROXY_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    ARGO_RUN="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/argo.yml run"
  elif [[ "$ARGO_AUTH" =~ ^ey[A-Z0-9a-z=]{120,250}$ ]]; then
    ARGO_RUN="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
  else
    error "ARGO_AUTH 格式无法识别（应是 TunnelSecret json 或 ey... token）"
  fi

  # ---- 9. 可选：内置探针 Agent 配置 ----
  if [ "$BUILTIN_AGENT" = "1" ]; then
    cat > "$WORK_DIR/agent.yml" << EOF
client_secret: $NZ_AGENTKEY
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 4
server: $NZ_DOMAIN
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $([ "$NZ_DOMAIN" = "127.0.0.1:8008" ] && echo false || echo true)
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $IDU
EOF
    AGENT_RUN="$WORK_DIR/nezha-agent -c $WORK_DIR/agent.yml"
  fi

  # ---- 10. 备份/还原/更新脚本（已随镜像内置，直接使用）----
  # 这三个脚本随镜像提供，可直接阅读 /dashboard/backup.sh 等。
  chmod +x "$WORK_DIR"/{backup.sh,restore.sh,renew.sh} 2>/dev/null || true

  # ---- 11. 定时任务（仅当配置了备份变量时启用）----
  if [[ -n "${GH_PAT:-}" && -n "${GH_REPO:-}" && -n "${GH_EMAIL:-}" ]]; then
    [ -z "${NO_AUTO_RENEW:-}" ] && ! grep -q "$WORK_DIR/renew.sh" /etc/crontab 2>/dev/null \
      && echo "30 3 * * * root bash $WORK_DIR/renew.sh" >> /etc/crontab
    ! grep -q "$WORK_DIR/backup.sh" /etc/crontab 2>/dev/null \
      && echo "0 4 * * * root bash $WORK_DIR/backup.sh" >> /etc/crontab
    service cron restart 2>/dev/null || true
  fi

  # ---- 12. 生成 supervisor 守护配置 ----
  {
    echo "[supervisord]"
    echo "nodaemon=true"
    echo "logfile=/dev/null"
    echo "pidfile=/run/supervisord.pid"
    echo ""
    echo "[program:caddy]"
    echo "command=$WORK_DIR/caddy run --config $WORK_DIR/Caddyfile"
    echo "autostart=true"
    echo "autorestart=true"
    echo "stderr_logfile=/dev/null"
    echo "stdout_logfile=/dev/null"
    echo ""
    echo "[program:nezha]"
    echo "command=$WORK_DIR/app"
    echo "directory=$WORK_DIR"
    echo "autostart=true"
    echo "autorestart=true"
    echo "stderr_logfile=/dev/null"
    echo "stdout_logfile=/dev/null"
    echo ""
    if [ "$BUILTIN_AGENT" = "1" ]; then
      echo "[program:agent]"
      echo "command=$AGENT_RUN"
      echo "autostart=true"
      echo "autorestart=true"
      echo "stderr_logfile=/dev/null"
      echo "stdout_logfile=/dev/null"
      echo ""
    fi
    echo "[program:argo]"
    echo "command=$ARGO_RUN"
    echo "autostart=true"
    echo "autorestart=true"
    echo "stderr_logfile=/dev/null"
    echo "stdout_logfile=/dev/null"
  } > "$DAEMON_CONF"

  # 赋予执行权
  chmod +x "$WORK_DIR"/{app,cloudflared,caddy,nezha-agent,*.sh} 2>/dev/null || true
  info "初始化完成。"
fi

# ============ 拉起守护进程（真正的 PID 1）============
exec supervisord -c /etc/supervisor/supervisord.conf
