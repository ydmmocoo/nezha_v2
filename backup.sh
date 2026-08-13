#!/usr/bin/env bash
# 备份 /dashboard/data（含 config.yaml 与 sqlite 数据库）到 GitHub 私库
# 仅当设置了 GH_PAT 与 GH_REPO 时生效；其余情况直接退出。
set -euo pipefail

WORK_DIR=/dashboard
GH_PAT=${GH_PAT:-}
GH_EMAIL=${GH_EMAIL:-}
GH_BACKUP_USER=${GH_BACKUP_USER:-${GH_USER:-}}
GH_REPO=${GH_REPO:-}

[ -z "$GH_PAT" ] || [ -z "$GH_REPO" ] && { echo "未配置 GH_PAT/GH_REPO，跳过备份"; exit 0; }

cd "$WORK_DIR"
TS=$(date +"%Y-%m-%d-%H:%M:%S")
BAK="dashboard-${TS}.tar.gz"

# 备份数据目录（面板数据库 + 配置）；Caddyfile 一并带上
tar czf "/tmp/${BAK}" data Caddyfile 2>/dev/null \
  || tar czf "/tmp/${BAK}" data

rm -rf /tmp/nezha_backup_repo
git clone -q "https://${GH_BACKUP_USER}:${GH_PAT}@github.com/${GH_BACKUP_USER}/${GH_REPO}.git" /tmp/nezha_backup_repo
cp "/tmp/${BAK}" /tmp/nezha_backup_repo/
cd /tmp/nezha_backup_repo
git config user.email "$GH_EMAIL"
git config user.name "$GH_BACKUP_USER"
git add -A
git commit -q -m "backup ${TS}" && git push -q
echo "backup ${BAK} done"
