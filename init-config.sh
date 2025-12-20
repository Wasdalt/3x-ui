#!/bin/sh
# ============================================================================
# 3x-ui Initialization Script / Скрипт инициализации 3x-ui
# Applies environment variables to panel database
# Применяет переменные окружения к базе данных панели
# ============================================================================

set -e

DB_PATH="/etc/x-ui/x-ui.db"

# Wait for database creation / Ждём создания БД
for i in $(seq 1 30); do
    if [ -f "$DB_PATH" ]; then
        break
    fi
    echo "Waiting for database... ($i/30)"
    sleep 1
done

if [ ! -f "$DB_PATH" ]; then
    echo "Database not found, skipping configuration"
    exit 0
fi

echo "Applying environment configuration..."

# Always set value (overwrites) / Всегда установить значение (перезаписывает)
set_always() {
    key=$1
    value=$2
    if [ -n "$value" ]; then
        sqlite3 "$DB_PATH" "DELETE FROM settings WHERE key='$key';"
        sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('$key', '$value');"
        echo "[SET] $key = $value"
    fi
}

# Set only if empty in DB / Установить только если нет в БД
set_if_empty() {
    key=$1
    value=$2
    if [ -n "$value" ]; then
        existing=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='$key';" 2>/dev/null || echo "")
        if [ -z "$existing" ]; then
            sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('$key', '$value');"
            echo "[NEW] $key = $value"
        fi
    fi
}

# ============================================================================
# Admin Credentials / Учётные данные администратора
# ============================================================================

hash_password() {
    echo -n "$1" | sha256sum | cut -d' ' -f1
}

if [ -n "$XUI_ADMIN_USERNAME" ]; then
    sqlite3 "$DB_PATH" "UPDATE users SET username='$XUI_ADMIN_USERNAME' WHERE id=1;"
    echo "[CREDS] Admin username set"
fi

if [ -n "$XUI_ADMIN_PASSWORD" ]; then
    HASHED_PASS=$(hash_password "$XUI_ADMIN_PASSWORD")
    sqlite3 "$DB_PATH" "UPDATE users SET password='$HASHED_PASS' WHERE id=1;"
    echo "[CREDS] Admin password set"
fi

if [ -n "$XUI_SECRET_KEY" ]; then
    set_always "secret" "$XUI_SECRET_KEY"
fi

# ============================================================================
# Domain Detection / Определение домена
# ============================================================================

# If XUI_DOMAIN empty - try to get from DB (for backups)
if [ -z "$XUI_DOMAIN" ]; then
    DB_DOMAIN=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
    if [ -n "$DB_DOMAIN" ]; then
        echo "[AUTO] Domain from database: $DB_DOMAIN"
        XUI_DOMAIN="$DB_DOMAIN"
        export XUI_DOMAIN
    fi
fi

if [ -z "$XUI_DOMAIN" ]; then
    echo "[WARN] No domain specified, SSL not configured"
    CERT_FILE=""
    KEY_FILE=""
    SUB_CERT_FILE=""
    SUB_KEY_FILE=""
else
    CERT_FILE="${XUI_CERT_FILE:-/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem}"
    KEY_FILE="${XUI_KEY_FILE:-/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem}"

    if [ -n "$XUI_SUB_DOMAIN" ] && [ "$XUI_SUB_DOMAIN" != "$XUI_DOMAIN" ]; then
        SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/fullchain.pem}"
        SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/privkey.pem}"
    else
        SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-$CERT_FILE}"
        SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-$KEY_FILE}"
    fi
fi

# ============================================================================
# Panel Settings / Настройки панели
# ============================================================================

set_always "webPort" "$XUI_PORT"
set_always "webCertFile" "$CERT_FILE"
set_always "webKeyFile" "$KEY_FILE"
set_always "webBasePath" "$XUI_BASE_PATH"

# Subscription / Подписка
set_always "subCertFile" "$SUB_CERT_FILE"
set_always "subKeyFile" "$SUB_KEY_FILE"
set_always "subEnable" "$XUI_SUB_ENABLE"
set_always "subPort" "$XUI_SUB_PORT"
set_always "subPath" "$XUI_SUB_PATH"
set_always "subDomain" "$XUI_SUB_DOMAIN"

# Session / Сессия
set_always "sessionMaxAge" "$XUI_SESSION_TIMEOUT"
set_always "timeLocation" "$XUI_TIMEZONE"

# Telegram
set_always "tgBotEnable" "$XUI_TG_ENABLE"
set_always "tgBotToken" "$XUI_TG_TOKEN"
set_always "tgBotChatId" "$XUI_TG_ADMIN_ID"

# UI
set_always "pageSize" "$XUI_PAGE_SIZE"
set_always "expireDiff" "$XUI_EXPIRE_DIFF"
set_always "trafficDiff" "$XUI_TRAFFIC_DIFF"

# ============================================================================
# Xray Logging / Логирование Xray
# ============================================================================

if [ -n "$XUI_XRAY_ACCESS_LOG" ] || [ -n "$XUI_XRAY_ERROR_LOG" ] || [ -n "$XUI_XRAY_LOG_LEVEL" ]; then
    echo "Configuring Xray logging..."
    
    CURRENT_CONFIG=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_CONFIG" ]; then
        NEW_CONFIG="$CURRENT_CONFIG"
        
        if command -v jq >/dev/null 2>&1; then
            [ -n "$XUI_XRAY_ACCESS_LOG" ] && NEW_CONFIG=$(echo "$NEW_CONFIG" | jq --arg val "$XUI_XRAY_ACCESS_LOG" '.log.access = $val')
            [ -n "$XUI_XRAY_ERROR_LOG" ] && NEW_CONFIG=$(echo "$NEW_CONFIG" | jq --arg val "$XUI_XRAY_ERROR_LOG" '.log.error = $val')
            [ -n "$XUI_XRAY_LOG_LEVEL" ] && NEW_CONFIG=$(echo "$NEW_CONFIG" | jq --arg val "$XUI_XRAY_LOG_LEVEL" '.log.loglevel = $val')
        else
            [ -n "$XUI_XRAY_ACCESS_LOG" ] && NEW_CONFIG=$(echo "$NEW_CONFIG" | sed "s|\"access\":[[:space:]]*\"[^\"]*\"|\"access\": \"$XUI_XRAY_ACCESS_LOG\"|")
            [ -n "$XUI_XRAY_ERROR_LOG" ] && NEW_CONFIG=$(echo "$NEW_CONFIG" | sed "s|\"error\":[[:space:]]*\"[^\"]*\"|\"error\": \"$XUI_XRAY_ERROR_LOG\"|")
            [ -n "$XUI_XRAY_LOG_LEVEL" ] && NEW_CONFIG=$(echo "$NEW_CONFIG" | sed "s|\"loglevel\":[[:space:]]*\"[^\"]*\"|\"loglevel\": \"$XUI_XRAY_LOG_LEVEL\"|")
        fi
        
        sqlite3 "$DB_PATH" "UPDATE settings SET value='$(echo "$NEW_CONFIG" | sed "s/'/''/g")' WHERE key='xrayTemplateConfig';"
        echo "[XRAY] Logging configured"
    fi
fi

echo "Configuration applied!"
