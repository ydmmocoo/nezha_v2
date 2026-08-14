# Nezha Monitoring V2 container for Northflank.
# This image intentionally supports only nezhahq/nezha V2.

FROM nginx:alpine

ENV TZ=Asia/Shanghai

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssl \
        procps \
        sqlite \
        tar \
        tzdata \
        unzip \
        wget \
        zip \
    && rm -f /etc/nginx/conf.d/default.conf

WORKDIR /app

COPY nginx/nezha.conf /etc/nginx/conf.d/nezha.conf
COPY scripts/ /app/

RUN chmod +x /app/*.sh

# Northflank should expose port 80 as HTTP/2. Port 443 is available for
# standalone Docker/VPS use and is not required on Northflank.
EXPOSE 80 443

ENTRYPOINT ["/app/start.sh"]
