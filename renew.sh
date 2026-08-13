#!/usr/bin/env bash
# 更新 Dashboard 二进制到最新 V2（保留 data/ 数据目录）
set -euo pipefail

WORK_DIR=/dashboard
case "$(uname -m)" in
  x86_64|amd64 )  ARCH=amd64 ;;
  aarch64|arm64 ) ARCH=arm64 ;;
  s390x )         ARCH=s390x ;;
  * ) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

if [[ -z "${DASHBOARD_VERSION:-}" ]]; then
  URL="https://github.com/nezhahq/nezha/releases/latest/download/dashboard-linux-${ARCH}.zip"
else
  URL="https://github.com/nezhahq/nezha/releases/download/${DASHBOARD_VERSION}/dashboard-linux-${ARCH}.zip"
fi

wget -q "$URL" -O /tmp/dashboard.zip || { echo "下载失败"; exit 1; }
unzip -o /tmp/dashboard.zip -d /tmp >/dev/null 2>&1
[ -d /tmp/dist ] && mv /tmp/dist/dashboard-linux-"$ARCH" /tmp/dashboard-linux-"$ARCH"
pkill -f "/dashboard/app" || true
sleep 1
mv -f /tmp/dashboard-linux-"$ARCH" "$WORK_DIR/app"
chmod +x "$WORK_DIR/app"
rm -f /tmp/dashboard.zip
echo "dashboard renewed to ${DASHBOARD_VERSION:-latest}"
