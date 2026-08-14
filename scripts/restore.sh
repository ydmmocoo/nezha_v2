#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
STATE_DIR="${ROOT}/data/state"
WORK="${STATE_DIR}/restore-work"
FILE="${1:-${RESTORE_FILE:-}}"

if [ -z "${FILE}" ]; then
    echo "用法: restore.sh nezha-v2-YYYYMMDDTHHMMSSZ.tar.gz" >&2
    exit 2
fi
if [ -z "${GH_REPO:-}" ] || [ -z "${GH_PAT:-}" ]; then
    echo "需要 GH_REPO 和 GH_PAT" >&2
    exit 1
fi
case "${FILE}" in
    nezha-v2-*.tar.gz) ;;
    *) echo "拒绝恢复非 Nezha V2 备份文件" >&2; exit 1 ;;
esac

mkdir -p "${WORK}"
trap 'rm -rf "${WORK}"' EXIT
AUTH="$(printf 'x-access-token:%s' "${GH_PAT}" | base64 | tr -d '\n')"
git -c "http.extraheader=AUTHORIZATION: Basic ${AUTH}" clone --quiet --depth 1 --branch "${GH_BRANCH:-main}" "https://github.com/${GH_REPO}.git" "${WORK}/repo"
test -f "${WORK}/repo/${FILE}"

if [ -f "${STATE_DIR}/dashboard.pid" ]; then
    kill -TERM "$(cat "${STATE_DIR}/dashboard.pid")" 2>/dev/null || true
    sleep 2
fi

tar -tzf "${WORK}/repo/${FILE}" | grep -Eq '(^|/)data/' || {
    echo "备份归档缺少 data 目录，拒绝恢复" >&2
    exit 1
}
tar -xzf "${WORK}/repo/${FILE}" -C "${ROOT}" --no-same-owner
echo "已恢复 ${FILE}；Dashboard runner 会自动重新启动面板"
