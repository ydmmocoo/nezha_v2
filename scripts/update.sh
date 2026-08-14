#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
STATE_DIR="${ROOT}/data/state"
LOCK="${STATE_DIR}/update.lock"
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    armv7l|armv6l) ARCH=arm ;;
    i686) ARCH=386 ;;
    s390x) ARCH=s390x ;;
    *) echo "[update] 不支持的架构: ${ARCH}" >&2; exit 1 ;;
esac

log() { echo "[update] $*"; }
if ! mkdir "${LOCK}" 2>/dev/null; then
    log "已有更新任务运行，跳过本次"
    exit 0
fi
trap 'rm -rf "${LOCK}"' EXIT

if [ "${DASHBOARD_VERSION:-latest}" = "latest" ]; then
    latest="$(curl -fsSL --retry 3 https://api.github.com/repos/nezhahq/nezha/releases/latest | jq -er .tag_name)"
else
    latest="${DASHBOARD_VERSION}"
fi

if [ "${DASHBOARD_VERSION:-latest}" != "latest" ]; then
    log "DASHBOARD_VERSION 已固定为 ${latest}，跳过面板更新"
else
    current="$(cat "${STATE_DIR}/dashboard.version" 2>/dev/null || true)"
    if [ "${current}" = "${latest}" ]; then
        log "Dashboard 已是 ${latest}"
    else
        tmp="$(mktemp -d "${STATE_DIR}/dashboard.XXXXXX")"
        trap 'rm -rf "${LOCK}" "${tmp:-}"' EXIT
        curl -fsSL --retry 3 "https://github.com/nezhahq/nezha/releases/download/${latest}/dashboard-linux-${ARCH}.zip" -o "${tmp}/dashboard.zip"
        unzip -q "${tmp}/dashboard.zip" -d "${tmp}/unpacked"
        test -x "${tmp}/unpacked/dashboard-linux-${ARCH}"
        install -m 0755 "${tmp}/unpacked/dashboard-linux-${ARCH}" "${ROOT}/app.new"
        mv -f "${ROOT}/app.new" "${ROOT}/app"
        printf '%s\n' "${latest}" > "${STATE_DIR}/dashboard.version"
        if [ -f "${STATE_DIR}/dashboard.pid" ]; then
            kill -TERM "$(cat "${STATE_DIR}/dashboard.pid")" 2>/dev/null || true
        fi
        log "Dashboard 已从 ${current:-初始版本} 更新到 ${latest}"
        rm -rf "${tmp}"
    fi
fi

/opt/nezha/scripts/update-scripts.sh
