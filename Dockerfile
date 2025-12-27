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

ENTRYPOINT ["/app/docker-entrypoint-wrapper.sh"]
