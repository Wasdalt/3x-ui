#!/bin/sh
# ============================================================================
# Скрипт инициализации 3x-ui
# Применяет переменные окружения к базе данных панели
# 
# Логика:
# - SSL и порт: ВСЕГДА перезаписываются из .env (серверо-специфичные)
# - Остальные настройки: применяются только если их нет в БД (сохраняются из бекапа)
# ============================================================================

set -e

DB_PATH="/etc/x-ui/x-ui.db"

# Ждём создания БД (если это первый запуск)
for i in $(seq 1 30); do
    if [ -f "$DB_PATH" ]; then
        break
    fi
    echo "Waiting for database to be created... ($i/30)"
    sleep 1
done

if [ ! -f "$DB_PATH" ]; then
    echo "Database not found, skipping configuration"
    exit 0
fi

echo "Applying environment configuration to database..."

# Функция для ВСЕГДА установки значения (перезаписывает)
set_always() {
    key=$1
    value=$2
    if [ -n "$value" ]; then
        # Сначала удаляем все старые записи с этим ключом
        sqlite3 "$DB_PATH" "DELETE FROM settings WHERE key='$key';"
        # Затем вставляем новое значение
        sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('$key', '$value');"
        echo "[FORCE] $key = $value"
    fi
}

# Функция для установки ТОЛЬКО если нет в БД (не перезаписывает бекап)
set_if_empty() {
    key=$1
    value=$2
    if [ -n "$value" ]; then
        existing=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='$key';" 2>/dev/null || echo "")
        if [ -z "$existing" ]; then
            sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('$key', '$value');"
            echo "[NEW] $key = $value"
        else
            echo "[SKIP] $key (already set: $existing)"
        fi
    fi
}

# ============================================================================
# СЕРВЕРО-СПЕЦИФИЧНЫЕ НАСТРОЙКИ (всегда перезаписываются)
# ============================================================================

# Автоматически формируем пути к сертификатам из XUI_DOMAIN если не указаны явно
CERT_FILE="${XUI_CERT_FILE:-/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem}"
KEY_FILE="${XUI_KEY_FILE:-/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem}"

# SSL для подписки
# Если XUI_SUB_DOMAIN указан — используем его, иначе те же серты что для панели
if [ -n "$XUI_SUB_DOMAIN" ] && [ "$XUI_SUB_DOMAIN" != "$XUI_DOMAIN" ]; then
    SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/fullchain.pem}"
    SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/privkey.pem}"
else
    SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-$CERT_FILE}"
    SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-$KEY_FILE}"
fi

# Панель
set_always "webPort" "$XUI_PORT"
set_always "webCertFile" "$CERT_FILE"
set_always "webKeyFile" "$KEY_FILE"
set_always "webBasePath" "$XUI_BASE_PATH"

# Подписка SSL (те же серты что и панель, или свои)
set_always "subCertFile" "$SUB_CERT_FILE"
set_always "subKeyFile" "$SUB_KEY_FILE"

# ============================================================================
# НАСТРОЙКИ ИЗ БЕКАПА (сохраняются если уже есть)
# ============================================================================

# Подписка
set_if_empty "subEnable" "${XUI_SUB_ENABLE:-true}"
set_if_empty "subPort" "$XUI_SUB_PORT"
set_if_empty "subPath" "$XUI_SUB_PATH"
set_if_empty "subDomain" "$XUI_DOMAIN"

# Сессия и безопасность
set_if_empty "sessionMaxAge" "$XUI_SESSION_TIMEOUT"
set_if_empty "timeLocation" "${XUI_TIMEZONE:-Local}"

# Telegram бот
set_if_empty "tgBotEnable" "$XUI_TG_ENABLE"
set_if_empty "tgBotToken" "$XUI_TG_TOKEN"
set_if_empty "tgBotChatId" "$XUI_TG_ADMIN_ID"

# UI настройки
set_if_empty "pageSize" "${XUI_PAGE_SIZE:-25}"
set_if_empty "expireDiff" "${XUI_EXPIRE_DIFF:-7}"
set_if_empty "trafficDiff" "${XUI_TRAFFIC_DIFF:-80}"

echo "Configuration applied successfully!"

