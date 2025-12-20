# ========================================================
# 3x-ui с поддержкой переменных окружения
# ========================================================
FROM ghcr.io/mhsanaei/3x-ui:latest

# Добавляем sqlite3 для конфигурации
RUN apk add --no-cache sqlite

# Копируем скрипты в конце (изменение любого файла инвалидирует кеш)
COPY init-config.sh docker-entrypoint-wrapper.sh /app/
RUN chmod +x /app/init-config.sh /app/docker-entrypoint-wrapper.sh

ENTRYPOINT ["/app/docker-entrypoint-wrapper.sh"]
