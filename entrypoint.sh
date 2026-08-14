#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
DATA_DIR="${ROOT}/data"
STATE_DIR="${DATA_DIR}/state"
CF_DIR="${ROOT}/cloudflared"
LOG_DIR="${ROOT}/logs"
DASHBOARD_PORT="${DASHBOARD_PORT:-8008}"
HTTP_PORT="${PORT:-${HTTP_PORT:-8080}}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"

mkdir -p "${DATA_DIR}" "${STATE_DIR}" "${CF_DIR}" "${LOG_DIR}"
ln -snf "/usr/share/zoneinfo/${TZ:-Asia/Shanghai}" /etc/localtime

die() {
    echo "[fatal] $*" >&2
    exit 1
}

require_env() {
    local name="$1"
    [ -n "${!name:-}" ] || die "缺少必填环境变量: ${name}"
}

write_if_missing() {
    local path="$1"
    shift
    if [ ! -s "${path}" ]; then
        umask 077
        printf '%s\n' "$@" > "${path}"
    fi
}

require_env ARGO_DOMAIN
if [ -z "${ARGO_TOKEN:-}" ] && [ -z "${ARGO_AUTH:-}" ]; then
    die "ARGO_TOKEN 或 ARGO_AUTH 至少设置一个"
fi

write_if_missing "${DATA_DIR}/config.yaml" \
    "debug: false" \
    "listen_port: ${DASHBOARD_PORT}" \
    "language: ${NZ_LANGUAGE:-zh_CN}" \
    "site_name: \"${NZ_SITE_NAME:-Nezha V2}\"" \
    "install_host: \"${ARGO_DOMAIN}:443\"" \
    "tls: true" \
    "reserved_hosts: \"${ARGO_DOMAIN}\""

cat > "${ROOT}/Caddyfile" <<EOF
:${HTTP_PORT} {
    encode gzip

    @grpc header Content-Type application/grpc*
    reverse_proxy @grpc h2c://127.0.0.1:${DASHBOARD_PORT}
    reverse_proxy 127.0.0.1:${DASHBOARD_PORT}
}
EOF

write_agent_config() {
    local agent_server="${LOCAL_AGENT_SERVER:-${ARGO_DOMAIN}:443}"
    local agent_uuid="${LOCAL_AGENT_UUID:-}"
    if [ -z "${agent_uuid}" ] && [ -s "${STATE_DIR}/local-agent.uuid" ]; then
        agent_uuid="$(cat "${STATE_DIR}/local-agent.uuid")"
    fi
    if [ -z "${agent_uuid}" ]; then
        agent_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
        printf '%s\n' "${agent_uuid}" > "${STATE_DIR}/local-agent.uuid"
    fi

    cat > "${DATA_DIR}/agent-config.yml" <<EOF
client_secret: "${LOCAL_AGENT_SECRET:-}"
debug: false
disable_auto_update: false
disable_command_execute: ${LOCAL_AGENT_DISABLE_COMMAND_EXECUTE:-true}
disable_force_update: false
disable_nat: true
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 3
server: "${agent_server}"
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: ${LOCAL_AGENT_TLS:-true}
use_atomgit_to_upgrade: false
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: "${agent_uuid}"
EOF
}

start_dashboard() {
    "${ROOT}/dashboard-runner.sh" &
    DASHBOARD_PID=$!
}

start_proxy() {
    caddy run --config "${ROOT}/Caddyfile" --adapter caddyfile &
    PROXY_PID=$!
}

start_tunnel() {
    if [ -n "${ARGO_TOKEN:-}" ]; then
        echo "[info] 启动 Cloudflare Tunnel token 模式"
        cloudflared tunnel --no-autoupdate run --token "${ARGO_TOKEN}" &
    else
        printf '%s' "${ARGO_AUTH}" > "${CF_DIR}/credentials.json"
        local tunnel_id
        tunnel_id="$(jq -er '.TunnelID // .tunnel_id // .tunnelId' "${CF_DIR}/credentials.json")" \
            || die "ARGO_AUTH JSON 中找不到 TunnelID"
        cat > "${CF_DIR}/config.yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CF_DIR}/credentials.json
no-autoupdate: true
ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://127.0.0.1:${HTTP_PORT}
  - service: http_status:404
EOF
        echo "[info] 启动 Cloudflare Tunnel JSON 模式"
        cloudflared tunnel --config "${CF_DIR}/config.yml" run &
    fi
    TUNNEL_PID=$!
}

start_agent() {
    if [ "${LOCAL_AGENT_ENABLED:-true}" != "true" ]; then
        echo "[info] LOCAL_AGENT_ENABLED 非 true，跳过本机 Agent"
        return
    fi
    if [ -z "${LOCAL_AGENT_SECRET:-}" ]; then
        echo "[warn] 未设置 LOCAL_AGENT_SECRET，本机 Agent 已内置但暂不启动；请在 V2 面板添加服务器后填写该密钥"
        return
    fi
    write_agent_config
    "${ROOT}/agent" -c "${DATA_DIR}/agent-config.yml" &
    AGENT_PID=$!
}

install_cron() {
    cat > /etc/crontabs/root <<EOF
${UPDATE_TIME:-0 3 * * *} /opt/nezha/scripts/update.sh >> /proc/1/fd/1 2>&1
${BACKUP_TIME:-0 4 * * *} /opt/nezha/scripts/backup.sh >> /proc/1/fd/1 2>&1
EOF
    crond -f -l 2 &
    CRON_PID=$!
}

cleanup() {
    trap - TERM INT EXIT
    for pid in "${AGENT_PID:-}" "${TUNNEL_PID:-}" "${PROXY_PID:-}" "${DASHBOARD_PID:-}" "${CRON_PID:-}"; do
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    wait || true
}
trap cleanup TERM INT EXIT

echo "[info] Nezha V2 Argo container starting"
start_dashboard
start_proxy
start_tunnel
start_agent
install_cron

while true; do
    sleep 10
    for name in DASHBOARD_PID PROXY_PID TUNNEL_PID CRON_PID; do
        pid="${!name:-}"
        if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
            echo "[fatal] ${name} exited; container will restart"
            exit 1
        fi
    done
    if [ -n "${AGENT_PID:-}" ] && ! kill -0 "${AGENT_PID}" 2>/dev/null; then
        echo "[warn] local Agent exited; retrying in 10 seconds"
        unset AGENT_PID
        start_agent
    fi
done
