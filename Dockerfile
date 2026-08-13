FROM debian:bookworm-slim

WORKDIR /dashboard

# 基础依赖：supervisor 进程守护、证书、解压、时区、cron（可选备份）
RUN apt-get update && \
    apt-get -y install --no-install-recommends \
        supervisor wget curl unzip openssl ca-certificates \
        cron procps tzdata vim-tiny git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 复制初始化脚本（V2 only）
COPY entrypoint.sh /dashboard/entrypoint.sh
COPY backup.sh /dashboard/backup.sh
COPY restore.sh /dashboard/restore.sh
COPY renew.sh /dashboard/renew.sh
RUN chmod +x /dashboard/*.sh

# 暴露统一端口（Argo 隧道实际走 443 回源，这里仅作文档说明）
EXPOSE 8008 443

ENTRYPOINT ["/dashboard/entrypoint.sh"]
