#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
DATA_DIR="${ROOT}/data"
STATE_DIR="${DATA_DIR}/state"
BACKUP_DIR="${STATE_DIR}/backup-work"
RETENTION="${BACKUP_RETENTION:-7}"
BRANCH="${GH_BRANCH:-main}"

log() { echo "[backup] $*"; }

if [ -z "${GH_REPO:-}" ] || [ -z "${GH_PAT:-}" ]; then
    log "未配置 GH_REPO/GH_PAT，跳过 GitHub 备份"
    exit 0
fi

case "${GH_REPO}" in
    */*) ;;
    *) echo "[backup] GH_REPO 必须是 owner/repository" >&2; exit 1 ;;
esac

LOCK="${STATE_DIR}/backup.lock"
if ! mkdir "${LOCK}" 2>/dev/null; then
    log "已有备份任务运行，跳过本次"
    exit 0
fi
trap 'rm -rf "${LOCK}" "${BACKUP_DIR}"' EXIT

mkdir -p "${BACKUP_DIR}"
AUTH="$(printf 'x-access-token:%s' "${GH_PAT}" | base64 | tr -d '\n')"
REMOTE="https://github.com/${GH_REPO}.git"

rm -rf "${BACKUP_DIR}/repo"
if ! git -c "http.extraheader=AUTHORIZATION: Basic ${AUTH}" clone --quiet --depth 1 --branch "${BRANCH}" "${REMOTE}" "${BACKUP_DIR}/repo"; then
    remote_refs=""
    if ! remote_refs="$(git -c "http.extraheader=AUTHORIZATION: Basic ${AUTH}" ls-remote "${REMOTE}" 2>/dev/null)"; then
        log "无法访问备份仓库；请确认 GH_PAT 有效且 GH_REPO 正确"
        exit 1
    fi
    if [ -z "${remote_refs}" ]; then
        mkdir -p "${BACKUP_DIR}/repo"
        git -C "${BACKUP_DIR}/repo" init --quiet
        git -C "${BACKUP_DIR}/repo" checkout -b "${BRANCH}" --quiet
        git -C "${BACKUP_DIR}/repo" remote add origin "${REMOTE}"
    else
        log "无法克隆备份仓库；请确认仓库存在、PAT 有 repo 权限且分支为 ${BRANCH}"
        exit 1
    fi
fi

rm -rf "${BACKUP_DIR}/payload"
mkdir -p "${BACKUP_DIR}/payload"
cp -a "${DATA_DIR}" "${BACKUP_DIR}/payload/data"
rm -rf "${BACKUP_DIR}/payload/data/state/backup-work" "${BACKUP_DIR}/payload/data/state/backup.lock" "${BACKUP_DIR}/payload/data/state/dashboard.pid"
if [ -f "${DATA_DIR}/sqlite.db" ]; then
    rm -f "${BACKUP_DIR}/payload/data/sqlite.db"
    sqlite3 "${DATA_DIR}/sqlite.db" ".backup '${BACKUP_DIR}/payload/data/sqlite.db'"
fi
if [ -d "${ROOT}/cloudflared" ]; then
    cp -a "${ROOT}/cloudflared" "${BACKUP_DIR}/payload/cloudflared"
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="nezha-v2-${STAMP}.tar.gz"
if [ -d "${BACKUP_DIR}/payload/cloudflared" ]; then
    tar -czf "${BACKUP_DIR}/${ARCHIVE}" -C "${BACKUP_DIR}/payload" data cloudflared
else
    tar -czf "${BACKUP_DIR}/${ARCHIVE}" -C "${BACKUP_DIR}/payload" data
fi

cp "${BACKUP_DIR}/${ARCHIVE}" "${BACKUP_DIR}/repo/${ARCHIVE}"
{
    echo "# Nezha V2 backup repository"
    echo
    echo "Last backup: ${ARCHIVE}"
    echo
    echo "This repository is managed by the Nezha V2 Argo container. Keep it private."
} > "${BACKUP_DIR}/repo/README.md"

find "${BACKUP_DIR}/repo" -maxdepth 1 -type f -name 'nezha-v2-*.tar.gz' -printf '%f\n' \
    | sort -r \
    | tail -n +$((RETENTION + 1)) \
    | while read -r old; do rm -f "${BACKUP_DIR}/repo/${old}"; done

git -C "${BACKUP_DIR}/repo" config user.name "${GH_COMMIT_NAME:-nezha-backup-bot}"
git -C "${BACKUP_DIR}/repo" config user.email "${GH_COMMIT_EMAIL:-nezha-backup-bot@users.noreply.github.com}"
git -C "${BACKUP_DIR}/repo" add README.md nezha-v2-*.tar.gz
if git -C "${BACKUP_DIR}/repo" diff --cached --quiet; then
    log "备份内容未变化"
    exit 0
fi
git -C "${BACKUP_DIR}/repo" commit -m "backup: ${ARCHIVE}" --quiet
git -c "http.extraheader=AUTHORIZATION: Basic ${AUTH}" -C "${BACKUP_DIR}/repo" push --quiet origin "HEAD:${BRANCH}"
log "已上传 ${ARCHIVE}，保留最近 ${RETENTION} 份"
