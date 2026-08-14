#!/usr/bin/env bash
set -Eeuo pipefail
archive="${1:-}"
[[ -n "$archive" && -f "$archive" ]] || { echo "用法: restore.sh /path/to/nezha-v2.tar.gz" >&2; exit 2; }
tar -tzf "$archive" | grep -qE '(^|/)data/' || { echo "备份中未找到 data 目录" >&2; exit 1; }
tar -xzf "$archive" -C /app --no-absolute-names
echo "恢复完成，请重启容器"
