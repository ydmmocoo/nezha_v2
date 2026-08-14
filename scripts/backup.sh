#!/bin/bash
# GitHub 备份：将 /app/data 与 /app/config.yml 打包加密推送到专用仓库。
# 仅当 GITHUB_USERNAME / REPO_NAME / GITHUB_TOKEN / ZIP_PASSWORD 四个变量都填时启用。

if [ -z "$GITHUB_USERNAME" ] || [ -z "$REPO_NAME" ] || [ -z "$GITHUB_TOKEN" ] || [ -z "$ZIP_PASSWORD" ]; then
  echo "Error: 请设置 GITHUB_USERNAME, REPO_NAME, GITHUB_TOKEN, ZIP_PASSWORD"
  exit 1
fi

WORK_DIR=/app
TEMP_DIR="$WORK_DIR/temp_backup"
GITHUB_REPO="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${REPO_NAME}.git"
TIMESTAMP=$(TZ='Asia/Shanghai' date +"%Y-%m-%d-%H-%M-%S")
BACKUP_FILE="data-${TIMESTAMP}.zip"

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

cp -R "$WORK_DIR/data" "$TEMP_DIR/" 2>/dev/null || true
cp "$WORK_DIR/config.yml" "$TEMP_DIR/" 2>/dev/null || true

# 压缩 sqlite，并清掉体积较大的历史表
if [ -f "$TEMP_DIR/data/sqlite.db" ]; then
  cd "$TEMP_DIR/data"
  sqlite3 sqlite.db ".recover" | sqlite3 sqlite.db.new 2>/dev/null && mv sqlite.db.new sqlite.db || true
  sqlite3 sqlite.db "DELETE FROM service_histories;" 2>/dev/null || true
  sqlite3 sqlite.db "DELETE FROM transfers;" 2>/dev/null || true
  cd "$WORK_DIR"
fi

cd "$TEMP_DIR"
echo "$BACKUP_FILE" > README.md
zip -r -P "$ZIP_PASSWORD" "$BACKUP_FILE" data config.yml 2>/dev/null || zip -r -P "$ZIP_PASSWORD" "$BACKUP_FILE" data

rm -rf temp_repo
git clone "$GITHUB_REPO" temp_repo
cd temp_repo
cp "../$BACKUP_FILE" "../README.md" ./

# 仅保留最新 5 个备份
BACKUPS_TO_REMOVE=$(ls data-*.zip 2>/dev/null | sort -r | tail -n +6)
for backup in $BACKUPS_TO_REMOVE; do
  rm -f "$backup"
done

rm -rf .git
git init
git branch -M main
git config user.name "Backup Script"
git config user.email "backup@localhost"
git add .
git commit -m "备份：$BACKUP_FILE"
git remote add origin "$GITHUB_REPO"
git push -u --force origin main

cd "$WORK_DIR"
rm -rf "$TEMP_DIR"
echo "备份完成：$BACKUP_FILE"
