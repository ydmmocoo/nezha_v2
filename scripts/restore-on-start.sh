#!/usr/bin/env bash
set -Eeuo pipefail

# Restore the latest GitHub backup before Dashboard starts. This is intended
# for platforms whose filesystem is ephemeral, such as a free Northflank
# service without a persistent volume.

ROOT="${NEZHA_ROOT:-/opt/nezha}"
DATA_DIR="${ROOT}/data"
STATE_DIR="${DATA_DIR}/state"
BRANCH="${GH_BRANCH:-main}"

log() { echo "[startup-restore] $*"; }
warn() { echo "[startup-restore] warning: $*" >&2; }

clean_legacy_config() {
    if [ -f "${DATA_DIR}/config.yaml" ] && grep -Eqi \
        '^[[:space:]]*(type|admin|clientid|clientsecret|endpoint|oidc[a-z]+):' \
        "${DATA_DIR}/config.yaml"; then
        rm -f "${DATA_DIR}/config.yaml"
        log "ignored incompatible legacy oauth2 config; a clean V2 config will be generated"
    fi
}

if [ "${AUTO_RESTORE_ON_START:-true}" != "true" ]; then
    log "AUTO_RESTORE_ON_START is not true; skipping"
    exit 0
fi

# Also repair a legacy config left by an earlier deployment, even when the
# current container filesystem still contains sqlite.db.
clean_legacy_config

# A valid local database means this is a normal process restart. Do not
# overwrite live data with an older remote archive in that case.
if [ -s "${DATA_DIR}/sqlite.db" ]; then
    log "local sqlite.db found; skipping remote restore"
    exit 0
fi

if [ -z "${GH_REPO:-}" ] || [ -z "${GH_PAT:-}" ]; then
    warn "GH_REPO/GH_PAT is not configured; no backup is available for restore"
    exit 0
fi

case "${GH_REPO}" in
    */*) ;;
    *) warn "GH_REPO must be owner/repository; skipping restore"; exit 0 ;;
esac

WORK="$(mktemp -d /tmp/nezha-startup-restore.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

AUTH_HEADER="Authorization: Bearer ${GH_PAT}"
RAW_BASE="https://raw.githubusercontent.com/${GH_REPO}/${BRANCH}"
API_URL="https://api.github.com/repos/${GH_REPO}/contents/?ref=${BRANCH}"

README="${WORK}/README.md"
if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
    -H "${AUTH_HEADER}" -H 'Accept: application/vnd.github+json' \
    "${RAW_BASE}/README.md" -o "${README}"; then
    warn "cannot read backup repository README.md; leaving a fresh data directory"
    exit 0
fi

# Only restore archives produced by this V2 project. The reference project's
# dashboard-*.tar.gz archives may contain legacy V0/V1 OAuth configuration and
# must not be fed to the V2 Dashboard.
ARCHIVE="$(grep -Eo 'nezha-v2-[^[:space:]]+\.tar\.gz' "${README}" | head -n 1 || true)"

# If README.md has no selected archive, fall back to the newest archive in the
# repository. This also handles older/hand-edited backup repositories.
if [ -z "${ARCHIVE}" ]; then
    LIST="${WORK}/contents.json"
    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
        -H "${AUTH_HEADER}" -H 'Accept: application/vnd.github+json' \
        "${API_URL}" -o "${LIST}"; then
        ARCHIVE="$(jq -r '[.[] | select(.type == "file" and (.name | test("^nezha-v2-.*\\.tar\\.gz$"))) | .name] | sort | if length > 0 then .[-1] else "" end' "${LIST}")"
    fi
fi

if [ -z "${ARCHIVE}" ]; then
    warn "no supported backup archive was found; leaving a fresh data directory"
    exit 0
fi

ARCHIVE_FILE="${WORK}/${ARCHIVE}"
if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
    -H "${AUTH_HEADER}" -H 'Accept: application/vnd.github+json' \
    "${RAW_BASE}/${ARCHIVE}" -o "${ARCHIVE_FILE}"; then
    warn "cannot download ${ARCHIVE}; leaving a fresh data directory"
    exit 0
fi

EXTRACT="${WORK}/extract"
mkdir -p "${EXTRACT}"
if ! tar -tzf "${ARCHIVE_FILE}" | grep -Eq '(^|/)data/sqlite\.db$'; then
    warn "${ARCHIVE} is not a valid Nezha V2 backup; leaving a fresh data directory"
    exit 0
fi

tar -xzf "${ARCHIVE_FILE}" -C "${EXTRACT}"
SOURCE_DATA="${EXTRACT}/data"
if [ ! -s "${SOURCE_DATA}/sqlite.db" ]; then
    warn "${ARCHIVE} does not contain data/sqlite.db; leaving a fresh data directory"
    exit 0
fi

mkdir -p "${DATA_DIR}" "${STATE_DIR}"
cp -a "${SOURCE_DATA}/." "${DATA_DIR}/"
if [ -d "${EXTRACT}/cloudflared" ]; then
    mkdir -p "${ROOT}/cloudflared"
    cp -a "${EXTRACT}/cloudflared/." "${ROOT}/cloudflared/"
fi

# Older configuration files can be present in a backup created before the V2
# schema was used. Keep the database, but let entrypoint.sh generate a clean
# V2 config instead of repeatedly crashing on legacy flat oauth2 fields.
clean_legacy_config

printf '%s\n' "${ARCHIVE}" > "${STATE_DIR}/startup-restored.archive"
log "restored ${ARCHIVE} from GitHub before Dashboard startup"
