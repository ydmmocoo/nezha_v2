#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
TARGET="${ROOT}/data/upstream-scripts"
mkdir -p "${TARGET}"

fetch() {
    local name="$1"
    local url="$2"
    local tmp="${TARGET}/${name}.tmp"
    if curl -fsSL --retry 3 "${url}" -o "${tmp}"; then
        test -s "${tmp}"
        mv -f "${tmp}" "${TARGET}/${name}"
        chmod 0755 "${TARGET}/${name}" || true
        echo "[scripts] 已更新 ${name}"
    else
        rm -f "${tmp}"
        echo "[scripts] 更新 ${name} 失败，保留旧文件" >&2
    fi
}

fetch nezha-dashboard-install.sh "${UPSTREAM_DASHBOARD_SCRIPT_URL:-https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh}"
fetch nezha-agent-install.sh "${UPSTREAM_AGENT_SCRIPT_URL:-https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh}"

if [ -n "${SELF_UPDATE_REPO:-}" ]; then
    branch="${SELF_UPDATE_BRANCH:-main}"
    auth_args=()
    if [ -n "${SELF_UPDATE_TOKEN:-}" ]; then
        auth_args=(-H "Authorization: Bearer ${SELF_UPDATE_TOKEN}")
    fi
    for name in backup.sh restore.sh update.sh update-scripts.sh; do
        url="https://raw.githubusercontent.com/${SELF_UPDATE_REPO}/${branch}/scripts/${name}"
        tmp="${ROOT}/scripts/${name}.tmp"
        if curl "${auth_args[@]}" -fsSL --retry 3 "${url}" -o "${tmp}" && grep -q '^#!/' "${tmp}"; then
            chmod 0755 "${tmp}"
            mv -f "${tmp}" "${ROOT}/scripts/${name}"
            echo "[scripts] 已更新自定义脚本 ${name}"
        else
            rm -f "${tmp}"
            echo "[scripts] 自定义脚本 ${name} 不可用，保留当前版本" >&2
        fi
    done
fi
