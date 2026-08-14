#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NEZHA_ROOT:-/opt/nezha}"
PID_FILE="${ROOT}/data/state/dashboard.pid"

while true; do
    cd "${ROOT}"
    "${ROOT}/app" &
    pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    status=0
    wait "${pid}" || status=$?
    rm -f "${PID_FILE}"
    if [ "${status}" -eq 0 ]; then
        exit 0
    fi
    echo "[warn] Dashboard exited with status ${status}; restarting"
    sleep 2
done
