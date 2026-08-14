#!/bin/bash
# GitHub 恢复：容器启动时若四个备份变量都填，则从专用仓库拉取最新备份恢复。
# 缺失变量则直接跳过（不报错）。

if [ -z "$GITHUB_USERNAME" ] || [ -z "$REPO_NAME" ] || [ -z "$GITHUB_TOKEN" ] || [ -z "$ZIP_PASSWORD" ]; then
  echo "Restore: 缺少备份相关环境变量，跳过恢复"
  exit 0
fi

WORK_DIR=/app
GITHUB_REPO="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${REPO_NAME}.git"

LATEST_BACKUP=$(curl -s -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/contents/README.md" 2>/dev/null | tr -d '[:space:]')

if [ -z "$LATEST_BACKUP" ] || [ "$LATEST_BACKUP" = "backup" ]; then
  echo "Restore: 无有效备份文件，跳过"
  exit 0
fi

echo "Restore: 正在恢复 $LATEST_BACKUP ..."

rm -rf "$WORK_DIR/temp_repo"
git clone --depth 1 "$GITHUB_REPO" "$WORK_DIR/temp_repo"

if [ ! -f "$WORK_DIR/temp_repo/$LATEST_BACKUP" ]; then
  echo "Restore: 备份文件不存在，跳过"
  rm -rf "$WORK_DIR/temp_repo"
  exit 0
fi

rm -rf "$WORK_DIR/data" "$WORK_DIR/config.yml"
unzip -P "$ZIP_PASSWORD" "$WORK_DIR/temp_repo/$LATEST_BACKUP" -d "$WORK_DIR"

rm -rf "$WORK_DIR/temp_repo"
echo "Restore: 恢复完成"
