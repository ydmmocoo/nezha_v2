#!/usr/bin/env bash
set -Eeuo pipefail

# Nezha V2 only. V0/V1 URLs, flags, database formats and compatibility paths
# are intentionally absent from this image.
ROOT=/app
DATA="$ROOT/data"
CONFIG="$DATA/config.yaml"
PORT=8008
DASH_PID=""
AGENT_PID=""
TUNNEL_PID=""
DEFAULT_DASH=v2.3.4
DEFAULT_AGENT=v2.3.1
export TZ="${TZ:-Asia/Shanghai}"

log() { echo "[$(date '+%F %T %Z')] $*"; }
fail() { log "ERROR: $*"; exit 1; }
true_value() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac; }

case "$(uname -m)" in
  x86_64) ARCH=amd64;;
  aarch64) ARCH=arm64;;
  s390x) ARCH=s390x;;
  *) fail "不支持的架构: $(uname -m)";;
esac

v2_version() { [[ "$1" =~ ^v2\.[0-9]+\.[0-9]+$ ]] || fail "$2 必须是 v2.x.y: $1"; }
host_only() { [[ "$1" != *"://"* && "$1" != */* && "$1" != *:* ]] || fail "$2 必须只填写域名: $1"; }

latest_v2() {
  curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases?per_page=100" 2>/dev/null \
    | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
    | grep -E '^v2\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true
}

download() {
  local url="$1" out="$2" tmp="${2}.tmp"
  log "下载 $url"
  curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" || fail "下载失败: $url"
  mv "$tmp" "$out"
}

yaml_string() {
  local key="$1" value="$2" escaped tmp
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "$key 不能包含换行"
  escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g' -e 's/"/\\"/g')
  tmp=$(mktemp)
  awk -v k="$key" -v v="$escaped" 'BEGIN{r=0} $0 ~ ("^" k ":[[:space:]]*"){print k ": \"" v "\"";r=1;next}{print}END{if(!r)print k ": \"" v "\""}' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
}

yaml_raw() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" 'BEGIN{r=0} $0 ~ ("^" k ":[[:space:]]*"){print k ": " v;r=1;next}{print}END{if(!r)print k ": " v}' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
}

remove_block() {
  local key="$1" tmp
  tmp=$(mktemp)
  awk -v k="$key" '$0 ~ ("^" k ":[[:space:]]*$"){skip=1;next} skip && ($0 ~ /^[[:space:]]/ || $0 ~ /^$/){next}{skip=0;print}' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
}

setup_tls() {
  [[ -s "$ROOT/nezha.pem" && -s "$ROOT/nezha.key" ]] && return
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=${NZ_DOMAIN:-localhost}" \
    -keyout "$ROOT/nezha.key" -out "$ROOT/nezha.pem" >/dev/null 2>&1 || fail "生成 TLS 证书失败"
  chmod 600 "$ROOT/nezha.key"
}

get_dashboard() {
  local version="${DASHBOARD_VERSION:-}"
  [[ -n "$version" ]] || version=$(latest_v2 nezhahq/nezha)
  version="${version:-$DEFAULT_DASH}"
  v2_version "$version" DASHBOARD_VERSION
  download "https://github.com/nezhahq/nezha/releases/download/$version/dashboard-linux-${ARCH}.zip" "$ROOT/dashboard.zip"
  unzip -qo "$ROOT/dashboard.zip" -d "$ROOT" || fail "Dashboard 解压失败"
  rm -f "$ROOT/dashboard.zip"
  chmod +x "$ROOT/dashboard-linux-${ARCH}"
}

get_agent() {
  [[ -n "${IDU:-}" && -n "${NZ_DOMAIN:-}" ]] || return
  local version="${AGENT_VERSION:-}"
  [[ -n "$version" ]] || version=$(latest_v2 nezhahq/agent)
  version="${version:-$DEFAULT_AGENT}"
  v2_version "$version" AGENT_VERSION
  download "https://github.com/nezhahq/agent/releases/download/$version/nezha-agent_linux_${ARCH}.zip" "$ROOT/agent.zip"
  unzip -qo "$ROOT/agent.zip" -d "$ROOT" || fail "Agent 解压失败"
  rm -f "$ROOT/agent.zip"
  chmod +x "$ROOT/nezha-agent"
}

patch_config() {
  yaml_raw listen_port "$PORT"
  yaml_string listen_host 0.0.0.0
  yaml_string location "$TZ"
  yaml_raw force_auth "$(true_value "${FORCE_AUTH:-true}" && echo true || echo false)"
  yaml_string web_real_ip_header nz-realip
  yaml_string agent_real_ip_header nz-realip
  if [[ -n "${NZ_DOMAIN:-}" ]]; then
    local p="${NZ_AGENT_PORT:-443}"
    [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || fail "NZ_AGENT_PORT 无效"
    yaml_string install_host "${NZ_DOMAIN}:${p}"
    yaml_raw tls true
  fi
  [[ -z "${NZ_DASHBOARD_HOST:-}" ]] || yaml_string reserved_hosts "$NZ_DASHBOARD_HOST"
  [[ -z "${NZ_JWTSECRETKEY:-}" ]] || yaml_string jwt_secret_key "$NZ_JWTSECRETKEY"
  if [[ -n "${NZ_ENABLE_TSDB+x}" || -n "${NZ_TSDB_DATA_PATH+x}" || -n "${NZ_TSDB_RETENTION_DAYS+x}" ]]; then
    if true_value "${NZ_ENABLE_TSDB:-true}"; then
      local path="${NZ_TSDB_DATA_PATH:-$DATA/tsdb}"
      remove_block tsdb
      mkdir -p "$path"
      cat >> "$CONFIG" <<EOF
tsdb:
  data_path: "$path"
  retention_days: ${NZ_TSDB_RETENTION_DAYS:-30}
  min_free_disk_space_gb: ${NZ_TSDB_MIN_FREE_DISK_SPACE_GB:-1}
  max_memory_mb: ${NZ_TSDB_MAX_MEMORY_MB:-256}
  write_buffer_size: ${NZ_TSDB_WRITE_BUFFER_SIZE:-512}
  write_buffer_flush_interval: ${NZ_TSDB_WRITE_BUFFER_FLUSH_INTERVAL:-5}
EOF
    else
      remove_block tsdb
    fi
  fi
}

start_dashboard() {
  if [[ -n "$DASH_PID" ]] && kill -0 "$DASH_PID" 2>/dev/null; then return; fi
  "$ROOT/dashboard-linux-${ARCH}" >>/proc/1/fd/1 2>>/proc/1/fd/2 & DASH_PID=$!
}

start_agent() {
  [[ -n "${IDU:-}" && -n "${NZ_DOMAIN:-}" && -n "${NZ_SELF_CLIENT_SECRET:-}" ]] || return
  cat > "$ROOT/config.yml" <<EOF
client_secret: "$NZ_SELF_CLIENT_SECRET"
debug: ${NZ_SELF_AGENT_DEBUG:-false}
disable_auto_update: true
disable_command_execute: ${NZ_AGENT_DISABLE_COMMAND_EXECUTE:-true}
disable_force_update: true
disable_nat: ${NZ_AGENT_DISABLE_NAT:-true}
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 3
server: ${NZ_DOMAIN}:${NZ_AGENT_PORT:-443}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: true
use_atomgit_to_upgrade: false
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $IDU
EOF
  "$ROOT/nezha-agent" -c "$ROOT/config.yml" >>/proc/1/fd/1 2>>/proc/1/fd/2 & AGENT_PID=$!
}

start_tunnel() {
  [[ -n "${ARGO_AUTH:-}" ]] || return
  [[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || fail "Cloudflare Tunnel 不支持架构: $ARCH"
  local bin="$ROOT/cloudflared-linux-${ARCH}"
  [[ -x "$bin" ]] || { download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" "$bin"; chmod +x "$bin"; }
  "$bin" tunnel --no-autoupdate --protocol http2 run --token "$ARGO_AUTH" >>/proc/1/fd/1 2>>/proc/1/fd/2 & TUNNEL_PID=$!
}

stop_all() {
  trap - TERM INT EXIT
  [[ -z "$TUNNEL_PID" ]] || kill "$TUNNEL_PID" 2>/dev/null || true
  [[ -z "$AGENT_PID" ]] || kill "$AGENT_PID" 2>/dev/null || true
  [[ -z "$DASH_PID" ]] || kill "$DASH_PID" 2>/dev/null || true
  nginx -s quit >/dev/null 2>&1 || true
}
trap stop_all TERM INT EXIT

main() {
  cd "$ROOT"
  [[ -z "${NZ_SELF_CLIENT_SECRET:-}" || ( "$NZ_SELF_CLIENT_SECRET" != *$'\n'* && "$NZ_SELF_CLIENT_SECRET" != *$'\r'* ) ]] || fail "NZ_SELF_CLIENT_SECRET 不能包含换行"
  [[ -z "${NZ_DOMAIN:-}" ]] || host_only "$NZ_DOMAIN" NZ_DOMAIN
  [[ -z "${NZ_DASHBOARD_HOST:-}" ]] || host_only "$NZ_DASHBOARD_HOST" NZ_DASHBOARD_HOST
  [[ -z "${IDU:-}" || -n "${NZ_DOMAIN:-}" ]] || fail "设置 IDU 时必须同时设置 NZ_DOMAIN"
  [[ -z "${IDU:-}" || -n "${NZ_SELF_CLIENT_SECRET:-}" ]] || fail "设置 IDU 时必须同时设置 NZ_SELF_CLIENT_SECRET"
  mkdir -p "$DATA"
  setup_tls
  get_dashboard
  get_agent
  if [[ ! -s "$CONFIG" ]]; then
    log "首次运行，生成 V2 默认配置"
    start_dashboard
    local n=60
    while [[ ! -s "$CONFIG" && "$n" -gt 0 ]]; do sleep 1; n=$((n-1)); done
    [[ -s "$CONFIG" ]] || fail "Dashboard 未生成 $CONFIG"
    kill "$DASH_PID" 2>/dev/null || true; wait "$DASH_PID" 2>/dev/null || true; DASH_PID=""
  fi
  patch_config
  start_dashboard
  sleep 2
  nginx -t >/dev/null 2>&1 || fail "nginx 配置校验失败"
  nginx >/dev/null 2>&1 || fail "nginx 启动失败"
  start_tunnel
  start_agent
  log "Nezha V2 已启动，nginx :80 -> Dashboard :$PORT"
  while sleep 30; do
    if [[ -z "$DASH_PID" ]] || ! kill -0 "$DASH_PID" 2>/dev/null; then log "Dashboard 已退出，重启"; start_dashboard; fi
    if ! pgrep -x nginx >/dev/null 2>&1; then log "nginx 已退出，重启"; nginx >/dev/null 2>&1 || true; fi
    if [[ -n "$AGENT_PID" ]] && ! kill -0 "$AGENT_PID" 2>/dev/null; then AGENT_PID=""; start_agent; fi
    if [[ -n "$TUNNEL_PID" ]] && ! kill -0 "$TUNNEL_PID" 2>/dev/null; then TUNNEL_PID=""; start_tunnel; fi
  done
}
main "$@"
