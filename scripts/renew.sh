#!/usr/bin/env bash
set -Eeuo pipefail

echo "本项目只跟踪哪吒 V2。更新方式：修改 DASHBOARD_VERSION / AGENT_VERSION 后重新部署服务。"
echo "当前 DASHBOARD_VERSION=${DASHBOARD_VERSION:-auto-v2} AGENT_VERSION=${AGENT_VERSION:-auto-v2}"
