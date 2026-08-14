# =============================================================================
# Nezha v2 Dashboard Container  (仅 V2，不兼容 V1 / V0 / legacy naiba/nezha)
# 基于 nezhahq/nezha (v2 线) + nezhahq/agent (v2 线)
#
# 架构：
#   - dashboard 监听容器内部 8008 (HTTP + gRPC 复用同一端口)
#   - nginx 反代：:80 提供 Web，:443 用自签证书终结 agent gRPC TLS
#   - 可选 Cloudflare Tunnel (ARGO_AUTH) 暴露公网域名
#   - 可选自监控 agent (IDU + NZ_DOMAIN)
#   - 可选 TSDB 历史指标 / GitHub 备份恢复
# =============================================================================

FROM nginx:alpine

ENV TZ=Asia/Shanghai

# 基础工具：下载/解压/证书/压缩/sqlite
RUN apk add --no-cache \
        wget unzip bash curl git tar openssl jq procps tzdata zip \
        sqlite sqlite-libs ca-certificates

# 移除默认站点，使用本项目自带配置（证书路径 /app/nezha.pem）
RUN rm -f /etc/nginx/conf.d/default.conf

WORKDIR /app

COPY scripts/ /app/
COPY nginx/nezha.conf /etc/nginx/conf.d/nezha.conf

RUN chmod +x /app/*.sh

EXPOSE 80 443

ENTRYPOINT ["/app/start.sh"]
