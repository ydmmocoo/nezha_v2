#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
DATA_DIR="${ROOT}/data"
STATE_DIR="${DATA_DIR}/state"
CF_DIR="${ROOT}/cloudflared"
LOG_DIR="${ROOT}/logs"
DASHBOARD_PORT="${DASHBOARD_PORT:-8008}"
HTTP_PORT="${PORT:-${HTTP_PORT:-8080}}"
GRPC_TLS_PORT="${GRPC_TLS_PORT:-443}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
AGENT_INSTALL_HOST="${AGENT_INSTALL_HOST:-${ARGO_DOMAIN}:443}"
AGENT_INSTALL_TLS="${AGENT_INSTALL_TLS:-true}"

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

# Northflank's free filesystem is ephemeral. Restore the last GitHub backup
# before generating config or starting Dashboard when sqlite.db is absent.
"${ROOT}/scripts/restore-on-start.sh"

write_if_missing "${DATA_DIR}/config.yaml" \
    "debug: false" \
    "listen_port: ${DASHBOARD_PORT}" \
    "language: ${NZ_LANGUAGE:-zh_CN}" \
    "site_name: \"${NZ_SITE_NAME:-Nezha V2}\"" \
    "install_host: \"${AGENT_INSTALL_HOST}\"" \
    "tls: ${AGENT_INSTALL_TLS}" \
    "reserved_hosts: \"${ARGO_DOMAIN}\""

TLS_DIR="${ROOT}/tls"
mkdir -p "${TLS_DIR}"
if [ ! -s "${TLS_DIR}/grpc.pem" ] || [ ! -s "${TLS_DIR}/grpc.key" ]; then
    echo "[info] 生成 gRPC TLS 证书"
    openssl req -x509 -nodes -newkey rsa:2048 -days 36500 \
        -subj "/CN=${ARGO_DOMAIN}" \
        -keyout "${TLS_DIR}/grpc.key" \
        -out "${TLS_DIR}/grpc.pem" >/dev/null 2>&1
fi

cat > "${ROOT}/Caddyfile" <<EOF
:${HTTP_PORT} {
    encode gzip

    reverse_proxy 127.0.0.1:${DASHBOARD_PORT}
}

:${GRPC_TLS_PORT} {
    tls ${TLS_DIR}/grpc.pem ${TLS_DIR}/grpc.key
    reverse_proxy {
        to 127.0.0.1:${DASHBOARD_PORT}
        transport http {
            versions h2c 2
        }
    }
}
EOF

write_agent_config() {
    local agent_server="${LOCAL_AGENT_SERVER:-127.0.0.1:${DASHBOARD_PORT}}"
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
tls: ${LOCAL_AGENT_TLS:-false}
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
        cloudflared tunnel --no-autoupdate --protocol http2 run --token "${ARGO_TOKEN}" &
    else
        printf '%s' "${ARGO_AUTH}" > "${CF_DIR}/credentials.json"
        local tunnel_id
        tunnel_id="$(jq -er '.TunnelID // .tunnel_id // .tunnelId' "${CF_DIR}/credentials.json")" \
            || die "ARGO_AUTH JSON 中找不到 TunnelID"
        cat > "${CF_DIR}/config.yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CF_DIR}/credentials.json
no-autoupdate: true
protocol: http2
ingress:
  - hostname: ${ARGO_DOMAIN}
    path: /proto.NezhaService/*
    service: https://127.0.0.1:${GRPC_TLS_PORT}
    originRequest:
      http2Origin: true
      noTLSVerify: true
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
    if [ -z "${LOCAL_AGENT_SECRET:-}" ] && [ ! -s "${DATA_DIR}/agent-config.yml" ]; then
        echo "[warn] 未设置 LOCAL_AGENT_SECRET，且没有备份恢复的 agent-config.yml；本机 Agent 暂不启动"
        return
    fi
    if [ -z "${LOCAL_AGENT_SECRET:-}" ]; then
        echo "[info] 使用 GitHub 备份恢复的本机 Agent 配置"
    else
        write_agent_config
    fi
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
