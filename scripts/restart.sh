#!/bin/bash
# 重启 dashboard（供手动/外部调用）。

case $(uname -m) in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  s390x)   ARCH=s390x ;;
  *) ARCH=amd64 ;;
esac

echo "stop dashboard ..."
pkill -f "dashboard-linux-${ARCH}" 2>/dev/null || true
sleep 1
echo "start dashboard ..."
nohup "./dashboard-linux-${ARCH}" >/dev/null 2>&1 &
