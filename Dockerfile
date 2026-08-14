FROM caddy:2-alpine AS caddy

FROM alpine:3.22

ARG TARGETARCH=amd64

ENV TZ=Asia/Shanghai \
    NEZHA_ROOT=/opt/nezha \
    DASHBOARD_PORT=8008 \
    HTTP_PORT=8080 \
    DASHBOARD_VERSION=latest \
    UPDATE_TIME="0 3 * * *" \
    BACKUP_TIME="0 4 * * *" \
    BACKUP_RETENTION=7 \
    LOCAL_AGENT_ENABLED=true \
    LOCAL_AGENT_TLS=true \
    LOCAL_AGENT_DISABLE_COMMAND_EXECUTE=true

RUN apk add --no-cache \
        bash ca-certificates curl git gzip jq sqlite tar tzdata unzip util-linux \
    && mkdir -p /opt/nezha/data /opt/nezha/scripts /opt/nezha/logs /opt/nezha/cloudflared \
    && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) NZ_ARCH=amd64; CF_ARCH=amd64 ;; \
        arm64) NZ_ARCH=arm64; CF_ARCH=arm64 ;; \
        arm) NZ_ARCH=arm; CF_ARCH=arm ;; \
        386) NZ_ARCH=386; CF_ARCH=386 ;; \
        s390x) NZ_ARCH=s390x; CF_ARCH=s390x ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${DASHBOARD_VERSION}" = "latest" ]; then \
        DASHBOARD_VERSION="$(curl -fsSL --retry 3 https://api.github.com/repos/nezhahq/nezha/releases/latest | jq -r .tag_name)"; \
    fi; \
    test -n "${DASHBOARD_VERSION}" && test "${DASHBOARD_VERSION}" != "null"; \
    curl -fsSL --retry 3 "https://github.com/nezhahq/nezha/releases/download/${DASHBOARD_VERSION}/dashboard-linux-${NZ_ARCH}.zip" -o /tmp/dashboard.zip; \
    unzip -q /tmp/dashboard.zip -d /tmp/dashboard; \
    install -m 0755 "/tmp/dashboard/dashboard-linux-${NZ_ARCH}" /opt/nezha/app; \
    curl -fsSL --retry 3 "https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${NZ_ARCH}.zip" -o /tmp/agent.zip; \
    unzip -q /tmp/agent.zip -d /tmp/agent; \
    install -m 0755 /tmp/agent/nezha-agent /opt/nezha/agent; \
    curl -fsSL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o /usr/local/bin/cloudflared; \
    chmod 0755 /usr/local/bin/cloudflared; \
    rm -rf /tmp/dashboard /tmp/agent /tmp/*.zip

COPY scripts /opt/nezha/scripts
COPY entrypoint.sh dashboard-runner.sh caddy/Caddyfile /opt/nezha/

RUN chmod 0755 /opt/nezha/entrypoint.sh /opt/nezha/dashboard-runner.sh /opt/nezha/scripts/*.sh \
    && touch /opt/nezha/data/.keep

WORKDIR /opt/nezha
EXPOSE 8080
VOLUME ["/opt/nezha/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${HTTP_PORT}/api/v1/setting" >/dev/null || exit 1

ENTRYPOINT ["/opt/nezha/entrypoint.sh"]
