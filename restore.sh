#!/usr/bin/env bash
# 从 GitHub 私库还原最新备份（解压到 /dashboard）
# 用法：bash restore.sh            # 还原最新
#       bash restore.sh <文件名>    # 还原指定备份
set -euo pipefail

WORK_DIR=/dashboard
GH_PAT=${GH_PAT:-}
GH_BACKUP_USER=${GH_BACKUP_USER:-${GH_USER:-}}
GH_REPO=${GH_REPO:-}

[ -z "$GH_PAT" ] || [ -z "$GH_REPO" ] && { echo "未配置 GH_PAT/GH_REPO，跳过还原"; exit 0; }

rm -rf /tmp/nezha_restore_repo
git clone -q "https://${GH_BACKUP_USER}:${GH_PAT}@github.com/${GH_BACKUP_USER}/${GH_REPO}.git" /tmp/nezha_restore_repo

if [ -n "${1:-}" ]; then
  BAK="/tmp/nezha_restore_repo/${1}"
else
  BAK=$(ls -t /tmp/nezha_restore_repo/dashboard-*.tar.gz 2>/dev/null | head -n1)
fi

[ -z "${BAK:-}" ] && { echo "无可用备份"; exit 0; }
tar xzf "$BAK" -C "$WORK_DIR/"
echo "restored from $BAK"
