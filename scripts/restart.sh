#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f 'dashboard-linux-(amd64|arm64|s390x)' 2>/dev/null || true
echo "Dashboard 已停止；请让容器编排器重新启动它。"
