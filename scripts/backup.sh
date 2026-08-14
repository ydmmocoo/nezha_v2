#!/usr/bin/env bash
set -Eeuo pipefail
out="${1:-/tmp/nezha-v2-$(date +%Y%m%d-%H%M%S).tar.gz}"
mkdir -p "$(dirname "$out")"
tar -czf "$out" -C /app data
echo "备份已生成: $out"
