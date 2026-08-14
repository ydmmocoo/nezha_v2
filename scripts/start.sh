#!/bin/bash
# =============================================================================
# Nezha v2 Dashboard Container - entrypoint
# 仅兼容哪吒面板 V2（nezhahq/nezha），不兼容 legacy v0（naiba/nezha）与 V1。
#
# 关键修正（避免「配置探针后页面不显示服务器 / 页面报错」）：
#   V2 把 agent 认证从「全局 agent_secret_key」改为「连接密钥与用户绑定」。
#   但 V2 仍向后兼容全局密钥——它在启动时把 config.yaml 的 agent_secret_key
#   注册为 user 0（见 nezhahq/nezha service/singleton/user.go:
#   AgentSecretToUserId[Conf.AgentSecretKey] = 0）。
#   因此必须把 NZ_AGENTKEY 同时写入 agent_secret_key 与 agent 的 client_secret，
#   否则 agent 认证失败（「客户端认证失败」/ WAF 封 IP），服务器永远不显示。
#
# 启动顺序：
#   1. 检查必需变量
#   2. (可选) GitHub 恢复备份
#   3. 生成自签证书 -> 下载 dashboard/agent 二进制（V2 线）
#   4. (首次) 运行 dashboard 生成默认 config.yaml
#   5. patch_config：强制 agent_secret_key / listen_port / force_auth / tsdb
#   6. 启动 dashboard / nginx / (tunnel) / (agent)
#   7. 看门狗 + 每小时备份/更新判断，保持容器常驻
# =============================================================================

WORK_DIR=/app
CONFIG_FILE="$WORK_DIR/data/config.yaml"
AGENT_CONFIG="$WORK_DIR/config.yml"
DASH_PORT=8008
DEFAULT_DASHBOARD_VERSION="v2.3.4"
DEFAULT_AGENT_VERSION="v2.3.3"
export TZ="${TZ:-Asia/Shanghai}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --------------------------------------------------------------------------- #
# 架构 / 工具函数
# --------------------------------------------------------------------------- #
case $(uname -m) in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  s390x)   ARCH=s390x ;;
  *) log "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

is_true()  { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac; }
is_false() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in ""|0|false|no|off) return 0;; *) return 1;; esac; }

# 设置顶层 YAML 字符串键（带引号）
set_yaml_key() {
  local key="$1" val="$2" esc
  esc=$(printf '%s' "$val" | sed -e 's/[\\/&]/\\&/g')
  if grep -q "^${key}:" "$CONFIG_FILE"; then
    sed -i "s|^${key}:.*|${key}: \"${esc}\"|" "$CONFIG_FILE"
  else
    printf '%s: "%s"\n' "$key" "$esc" >> "$CONFIG_FILE"
  fi
}
# 设置顶层 YAML 原始值（数字 / 布尔，不带引号）
set_yaml_key_raw() {
  local key="$1" val="$2"
  if grep -q "^${key}:" "$CONFIG_FILE"; then
    sed -i "s|^${key}:.*|${key}: ${val}|" "$CONFIG_FILE"
  else
    printf '%s: %s\n' "$key" "$val" >> "$CONFIG_FILE"
  fi
}
# 删除顶层 YAML 块（用于重写 tsdb）
remove_yaml_block() {
  local block="$1" tmp
  tmp=$(mktemp)
  awk -v b="$block" 'BEGIN{s=0} $0 ~ ("^" b ":"){s=1;next} s{if($0 ~ /^[[:space:]]+/ || $0 ~ /^$/){next} s=0} {print}' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}
has_tsdb_env() {
  [ -n "${NZ_TSDB_DATA_PATH+x}" ] || [ -n "${NZ_TSDB_RETENTION_DAYS+x}" ] || \
  [ -n "${NZ_TSDB_MIN_FREE_DISK_SPACE_GB+x}" ] || [ -n "${NZ_TSDB_MAX_MEMORY_MB+x}" ] || \
  [ -n "${NZ_TSDB_WRITE_BUFFER_SIZE+x}" ] || [ -n "${NZ_TSDB_WRITE_BUFFER_FLUSH_INTERVAL+x}" ]
}
# 跟踪 v2.x 最新 tag（避免误升到 v3）
get_latest_v2_tag() {
  curl -s --max-time 20 "https://api.github.com/repos/$1/tags?per_page=100" 2>/dev/null \
    | grep -oE 'v2\.[0-9]+\.[0-9]+' | sort -V | tail -1
}
wait_for_config_file() {
  local r=30
  while [ ! -f "$CONFIG_FILE" ] && [ "$r" -gt 0 ]; do sleep 1; r=$((r-1)); done
}
check_env() {
  [ -z "$NZ_AGENTKEY" ] && { log "ERROR: 必须设置环境变量 NZ_AGENTKEY"; exit 1; }
}

# --------------------------------------------------------------------------- #
# 证书 / 二进制 / 主题
# --------------------------------------------------------------------------- #
setup_ssl() {
  local cn="${NZ_DOMAIN:-localhost}"
  openssl genrsa -out "$WORK_DIR/nezha.key" 2048 2>/dev/null
  openssl req -new -key "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.csr" -subj "/CN=$cn" 2>/dev/null
  openssl x509 -req -days 3650 -in "$WORK_DIR/nezha.csr" -signkey "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.pem" 2>/dev/null
  chmod 600 "$WORK_DIR/nezha.key"
  chmod 644 "$WORK_DIR/nezha.pem"
}

download_binaries() {
  local dv="${DASHBOARD_VERSION:-}"
  [ -z "$dv" ] && dv=$(get_latest_v2_tag nezhahq/nezha)
  [ -z "$dv" ] && dv="$DEFAULT_DASHBOARD_VERSION"
  log "Dashboard 版本: $dv"
  wget -q "https://github.com/nezhahq/nezha/releases/download/$dv/dashboard-linux-${ARCH}.zip" -O dash.zip \
    || { log "ERROR: 下载 dashboard 失败 ($dv)"; exit 1; }
  unzip -qo dash.zip -d "$WORK_DIR" && rm -f dash.zip
  chmod +x "dashboard-linux-${ARCH}"

  if [ -n "$IDU" ] && [ -n "$NZ_DOMAIN" ]; then
    local av="${AGENT_VERSION:-}"
    [ -z "$av" ] && av=$(get_latest_v2_tag nezhahq/agent)
    [ -z "$av" ] && av="$DEFAULT_AGENT_VERSION"
    log "Agent 版本: $av"
    wget -q "https://github.com/nezhahq/agent/releases/download/$av/nezha-agent_linux_${ARCH}.zip" -O agent.zip \
      || { log "ERROR: 下载 agent 失败 ($av)"; exit 1; }
    unzip -qo agent.zip -d "$WORK_DIR" && rm -f agent.zip
    chmod +x nezha-agent
  fi
}

apply_extra_user_theme() {
  [ -z "$NZ_EXTRA_USER_THEME" ] && return 0
  local zip="$WORK_DIR/extra-theme.zip" tmp="$WORK_DIR/.extra-theme"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if ! wget -q "$NZ_EXTRA_USER_THEME" -O "$zip"; then
    log "WARN: 主题下载失败，跳过"; rm -f "$zip"; return 0
  fi
  if ! unzip -qo "$zip" -d "$tmp"; then
    log "WARN: 主题解压失败，跳过"; rm -f "$zip"; rm -rf "$tmp"; return 0
  fi
  local root
  root=$(find "$tmp" -mindepth 1 -maxdepth 2 -type f -name 'index.html' | head -n1 | xargs -r dirname)
  [ -z "$root" ] && root=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)
  [ -z "$root" ] && root="$tmp"
  rm -rf "$WORK_DIR/user-dist"; mkdir -p "$WORK_DIR/user-dist"
  cp -r "$root"/. "$WORK_DIR/user-dist/" && log "用户主题已应用: $NZ_EXTRA_USER_THEME"
  rm -f "$zip"; rm -rf "$tmp"
}

# --------------------------------------------------------------------------- #
# 配置 patch（环境变量为权威来源）
# --------------------------------------------------------------------------- #
patch_config() {
  # 【关键】V2 把 agent_secret_key 注册为 user 0（全局密钥，向后兼容）。
  # 必须把 NZ_AGENTKEY 写入此处，且自监控 agent 的 client_secret 也用同一值，
  # 否则 agent 认证失败、服务器不显示。这是 ydmmocoo/nezha_v1 报错的根因。
  set_yaml_key "agent_secret_key" "$NZ_AGENTKEY"
  grep -q "^agentsecretkey:" "$CONFIG_FILE" && set_yaml_key "agentsecretkey" "$NZ_AGENTKEY"

  # JWT 签名密钥：生产推荐用 NZ_JWTSECRETKEY 注入，避免 V2.0.13+ 自动轮转导致频繁登出
  [ -n "$NZ_JWTSECRETKEY" ] && set_yaml_key "jwt_secret_key" "$NZ_JWTSECRETKEY"

  # 访客可见性：FORCE_AUTH=true -> 强制登录（更安全，推荐）；false -> 允许访客查看公开状态页
  set_yaml_key_raw "force_auth" "$(is_true "$FORCE_AUTH" && echo true || echo false)"

  # 固定监听端口，nginx 反代到 8008（Web + gRPC 复用，V2 端点 /proto.NezhaService/）
  set_yaml_key_raw "listen_port" "$DASH_PORT"
  set_yaml_key "listen_host" "0.0.0.0"
  set_yaml_key "location" "${TZ}"
  if [ -n "$NZ_DOMAIN" ]; then
    set_yaml_key "install_host" "$NZ_DOMAIN"
    set_yaml_key_raw "tls" "true"
  fi
  # 反代 / 公网域名：声明 OAuth2 回调 Host 与 NAT 保留域名（Northflank 等反代场景建议设置）
  [ -n "$NZ_DASHBOARD_HOST" ] && set_yaml_key "dashboard_host" "$NZ_DASHBOARD_HOST"

  # TSDB 历史指标
  if [ -n "${NZ_ENABLE_TSDB+x}" ] || has_tsdb_env; then
    if is_false "$NZ_ENABLE_TSDB"; then
      remove_yaml_block "tsdb"
      log "TSDB 已按环境变量关闭"
    else
      local p="${NZ_TSDB_DATA_PATH:-/app/tsdb}" r="${NZ_TSDB_RETENTION_DAYS:-7}" \
            mf="${NZ_TSDB_MIN_FREE_DISK_SPACE_GB:-0.3}" mm="${NZ_TSDB_MAX_MEMORY_MB:-64}" \
            wb="${NZ_TSDB_WRITE_BUFFER_SIZE:-128}" wf="${NZ_TSDB_WRITE_BUFFER_FLUSH_INTERVAL:-5}"
      remove_yaml_block "tsdb"
      mkdir -p "$p"
      cat <<EOF >> "$CONFIG_FILE"
tsdb:
  data_path: "$p"
  retention_days: $r
  min_free_disk_space_gb: $mf
  max_memory_mb: $mm
  write_buffer_size: $wb
  write_buffer_flush_interval: $wf
EOF
      log "TSDB 已启用，数据目录: $p"
    fi
  else
    log "TSDB 未配置，保持原样"
  fi
}

# --------------------------------------------------------------------------- #
# 服务启停
# --------------------------------------------------------------------------- #
start_dashboard() { nohup "./dashboard-linux-${ARCH}" >/dev/null 2>&1 & }
start_nginx()     { nginx >/dev/null 2>&1 & }

start_tunnel() {
  [ -z "$ARGO_AUTH" ] && return 0
  local cf="cloudflared-linux-${ARCH}"
  if [ ! -f "$cf" ]; then
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/$cf" -O "$cf" && chmod +x "$cf" || return 0
  fi
  nohup "./$cf" tunnel --protocol http2 run --token "$ARGO_AUTH" >/dev/null 2>&1 &
}

start_agent() {
  [ -z "$IDU" ] || [ -z "$NZ_DOMAIN" ] && return 0
  cat > "$AGENT_CONFIG" <<EOF
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
server: $NZ_DOMAIN:443
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: true
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $IDU
EOF
  nohup ./nezha-agent >/dev/null 2>&1 &
}

watchdog() {
  pgrep -f "dashboard-linux-${ARCH}" >/dev/null 2>&1 || { log "watchdog: dashboard 掉线，重启"; start_dashboard; }
  pgrep -f "nginx: master"       >/dev/null 2>&1 || { log "watchdog: nginx 掉线，重启"; start_nginx; }
  [ -n "$ARGO_AUTH" ] && { pgrep -f "cloudflared-linux-${ARCH}" >/dev/null 2>&1 || start_tunnel; }
  if [ -n "$IDU" ] && [ -n "$NZ_DOMAIN" ]; then pgrep -f "nezha-agent" >/dev/null 2>&1 || start_agent; fi
}

# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
main() {
  check_env
  [ -f "restore.sh" ] && bash restore.sh
  mkdir -p "$WORK_DIR/data"
  setup_ssl
  download_binaries
  apply_extra_user_theme

  if [ ! -f "$CONFIG_FILE" ]; then
    log "首次启动，先运行 dashboard 生成默认配置..."
    start_dashboard
    wait_for_config_file
    pkill -f "dashboard-linux-${ARCH}" 2>/dev/null || true
    sleep 1
  fi

  patch_config

  log "启动服务..."
  start_dashboard
  sleep 2
  start_nginx
  start_tunnel
  start_agent
  log "启动完成。Web 监听容器 80 端口；agent 经 443 / 隧道上报到 dashboard:8008。"
}

main

# --------------------------------------------------------------------------- #
# 常驻循环：看门狗（每分钟） + 备份/更新判断（每小时）
# --------------------------------------------------------------------------- #
tick=0
while true; do
  sleep 60
  watchdog
  tick=$((tick + 1))
  if [ "$tick" -ge 60 ]; then
    tick=0
    if [ -n "$GITHUB_USERNAME" ] && [ -n "$REPO_NAME" ] && [ -n "$GITHUB_TOKEN" ] && [ -n "$ZIP_PASSWORD" ]; then
      current_date=$(date +"%Y-%m-%d"); current_hour=$(date +"%H")
      readme_content=$(curl -s -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.raw" \
        "https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/contents/README.md" 2>/dev/null)
      file_date=$(echo "$readme_content" | sed -n 's/^data-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-.*\.zip$/\1/p')
      if { [ "$file_date" != "$current_date" ] && [ "$current_hour" -eq 4 ]; } || [ "$readme_content" = "backup" ]; then
        [ -f "backup.sh" ] && bash backup.sh
        [ -z "$DASHBOARD_VERSION" ] && [ -f "renew.sh" ] && bash renew.sh
      fi
    else
      [ -z "$DASHBOARD_VERSION" ] && [ -f "renew.sh" ] && bash renew.sh
    fi
  fi
done
