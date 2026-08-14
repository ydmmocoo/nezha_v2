#!/bin/bash
# 自动更新：仅跟踪 v2.x（绝不升级到 v3），且 DASHBOARD_VERSION 未固定时才生效。
# 由 start.sh 每小时调用一次。

WORK_DIR=/app
cd "$WORK_DIR" || exit 1

case $(uname -m) in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  s390x)   ARCH=s390x ;;
  *) echo "Unsupported arch"; exit 1 ;;
esac

get_latest_v2_tag() {
  curl -s --max-time 20 "https://api.github.com/repos/$1/tags?per_page=100" 2>/dev/null \
    | grep -oE 'v2\.[0-9]+\.[0-9]+' | sort -V | tail -1
}
ver_of() { "$1" -v 2>/dev/null | grep -oE 'v[0-9.]+' | head -1; }

dashboard_updated=0
agent_updated=0
agent_enabled=0

if [ -z "$DASHBOARD_VERSION" ]; then
  dv=$(get_latest_v2_tag nezhahq/nezha)
  if [ -n "$dv" ]; then
    lv=$(ver_of "./dashboard-linux-${ARCH}")
    if [ "$lv" != "$dv" ]; then
      echo "更新 dashboard: $lv -> $dv"
      if wget -q "https://github.com/nezhahq/nezha/releases/download/$dv/dashboard-linux-${ARCH}.zip" -O d.zip \
         && unzip -qo d.zip -d "$WORK_DIR" && rm -f d.zip; then
        chmod +x "dashboard-linux-${ARCH}"
        dashboard_updated=1
      fi
    else
      echo "dashboard 已是最新 ($lv)"
    fi
  fi
fi

if [ -n "$IDU" ] && [ -n "$NZ_DOMAIN" ]; then
  agent_enabled=1
  av=$(get_latest_v2_tag nezhahq/agent)
  if [ -n "$av" ]; then
    lv=$(ver_of "./nezha-agent")
    if [ "$lv" != "$av" ]; then
      echo "更新 agent: $lv -> $av"
      if wget -q "https://github.com/nezhahq/agent/releases/download/$av/nezha-agent_linux_${ARCH}.zip" -O a.zip \
         && unzip -qo a.zip -d "$WORK_DIR" && rm -f a.zip; then
        chmod +x nezha-agent
        agent_updated=1
      fi
    else
      echo "agent 已是最新 ($lv)"
    fi
  fi
fi

if [ "$dashboard_updated" -eq 1 ]; then
  pkill -f "dashboard-linux-${ARCH}" 2>/dev/null || true
  sleep 1
  nohup "./dashboard-linux-${ARCH}" >/dev/null 2>&1 &
fi
if [ "$agent_enabled" -eq 1 ] && [ "$agent_updated" -eq 1 ]; then
  pkill -f "nezha-agent" 2>/dev/null || true
  sleep 1
  nohup ./nezha-agent >/dev/null 2>&1 &
fi

echo "renew 完成"
