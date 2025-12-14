# ========================================================
# 3x-ui с поддержкой переменных окружения
# ========================================================
FROM ghcr.io/mhsanaei/3x-ui:latest

# Добавляем sqlite3 для конфигурации через init скрипт
RUN apk add --no-cache sqlite

# Копируем init скрипт
COPY init-config.sh /app/init-config.sh
RUN chmod +x /app/init-config.sh

# Переопределяем entrypoint для запуска init скрипта
COPY docker-entrypoint-wrapper.sh /app/docker-entrypoint-wrapper.sh
RUN chmod +x /app/docker-entrypoint-wrapper.sh

ENTRYPOINT ["/app/docker-entrypoint-wrapper.sh"]
