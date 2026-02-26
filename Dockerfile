# ========================================================
# 3x-ui с поддержкой переменных окружения
# ========================================================
FROM ghcr.io/mhsanaei/3x-ui:latest

# Добавляем sqlite3 и jq для конфигурации
RUN apk add --no-cache sqlite jq

# Копируем скрипты (ARG инвалидирует кэш при сборке с --build-arg CACHEBUST=$(date +%s))
ARG CACHEBUST=1
COPY init-config.sh docker-entrypoint-wrapper.sh /app/
RUN chmod +x /app/init-config.sh /app/docker-entrypoint-wrapper.sh

# Симлинки: ./access.log → shared volume /app/xray-logs/
# Xray пишет в ./access.log, а файл попадает в shared volume для torrent/iplimit блокировщиков
RUN mkdir -p /app/xray-logs && \
    ln -sf /app/xray-logs/access.log /app/access.log && \
    ln -sf /app/xray-logs/error.log /app/error.log

ENTRYPOINT ["/app/docker-entrypoint-wrapper.sh"]
