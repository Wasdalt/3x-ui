#!/bin/sh
# ============================================================================
# 3x-ui Initialization Script / Скрипт инициализации 3x-ui
# Applies environment variables to panel database
# Применяет переменные окружения к базе данных панели
# ============================================================================

set -e

DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CERTBOT_HELPER="${XUI_CERTBOT_HELPER:-${SCRIPT_DIR}/certbot-domain.sh}"

if [ -r "$CERTBOT_HELPER" ]; then
    . "$CERTBOT_HELPER"
fi

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

get_setting_value() {
    sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='$1';" 2>/dev/null || echo ""
}

random_uint16() {
    od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' '
}

random_hex() {
    od -An -N9 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

port_is_available() {
    port=$1

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi

    if sqlite3 "$DB_PATH" "SELECT 1 FROM inbounds WHERE port='$port' LIMIT 1;" 2>/dev/null | grep -q 1; then
        return 1
    fi

    if sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key IN ('webPort','subPort') AND value='$port' LIMIT 1;" 2>/dev/null | grep -q 1; then
        return 1
    fi

    if [ -n "$XUI_SUB_PORT" ] && [ "$XUI_SUB_PORT" = "$port" ]; then
        return 1
    fi

    if command -v ss >/dev/null 2>&1; then
        ! ss -H -lntu "sport = :$port" 2>/dev/null | grep -q .
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        ! netstat -tuln 2>/dev/null | grep -E "(^|[.:])${port}[[:space:]]" >/dev/null 2>&1
        return $?
    fi

    return 0
}

generate_panel_port() {
    for i in $(seq 1 50); do
        number=$(random_uint16)
        [ -n "$number" ] || number=$((i * 997))
        port=$((40000 + number % 20000))
        if port_is_available "$port"; then
            echo "$port"
            return 0
        fi
    done

    for port in 50550 51050 52050 53050 54050 55050 56050 57050 58050 59050; do
        if port_is_available "$port"; then
            echo "$port"
            return 0
        fi
    done

    echo ""
    return 1
}

generate_base_path() {
    token=$(random_hex)
    [ -n "$token" ] || token="$(date +%s)$$"
    echo "/${token}/"
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

# If XUI_DOMAIN empty - try to get panel domain from DB (for backups)
if [ -z "$XUI_DOMAIN" ]; then
    DB_DOMAIN=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "")
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
    
    # HTTP fallback mode
    if [ "$XUI_ALLOW_HTTP" = "true" ]; then
        echo "[HTTP] HTTP mode enabled - panel accessible via http://server-ip:${XUI_PORT:-2053}"
    else
        echo "[TIP] Use SSH tunnel: ssh -N -L 8080:localhost:${XUI_PORT:-2053} user@server"
        echo "[TIP] Or set XUI_ALLOW_HTTP=true for HTTP access (insecure!)"
    fi
else
    DEFAULT_CERT_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
    DEFAULT_KEY_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem"
    CERT_FILE="${XUI_CERT_FILE:-$DEFAULT_CERT_FILE}"
    KEY_FILE="${XUI_KEY_FILE:-$DEFAULT_KEY_FILE}"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo "[WARN] Certificate files for ${XUI_DOMAIN} not found, starting panel without SSL until certbot succeeds"
        CERT_FILE=""
        KEY_FILE=""
    fi

    if [ -n "$XUI_SUB_DOMAIN" ] && [ "$XUI_SUB_DOMAIN" != "$XUI_DOMAIN" ]; then
        SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/fullchain.pem}"
        SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/privkey.pem}"
    else
        SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-$CERT_FILE}"
        SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-$KEY_FILE}"
    fi

    if [ -n "$SUB_CERT_FILE" ] && { [ ! -f "$SUB_CERT_FILE" ] || [ ! -f "$SUB_KEY_FILE" ]; }; then
        SUB_CERT_FILE=""
        SUB_KEY_FILE=""
    fi
fi


# ============================================================================
# Generated Fallbacks / Автогенерация безопасных локальных значений
# ============================================================================

if [ -z "$XUI_PORT" ] && [ -z "$(get_setting_value webPort)" ]; then
    if GENERATED_PORT=$(generate_panel_port); then
        set_if_empty "webPort" "$GENERATED_PORT"
        echo "[AUTO] Generated free panel port: $GENERATED_PORT"
    else
        echo "[WARN] Could not find a free generated panel port"
    fi
fi

if [ -z "$XUI_BASE_PATH" ] && [ -z "$(get_setting_value webBasePath)" ]; then
    GENERATED_BASE_PATH=$(generate_base_path)
    set_if_empty "webBasePath" "$GENERATED_BASE_PATH"
    echo "[AUTO] Generated panel base path: $GENERATED_BASE_PATH"
fi


# ============================================================================
# Panel Settings / Настройки панели
# ============================================================================

set_always "webPort" "$XUI_PORT"
set_always "webDomain" "$XUI_DOMAIN"
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
# Xray Logging / Логирование Xray (через БД / via database)
# ============================================================================

XRAY_CONFIG="${XUI_XRAY_CONFIG:-/app/bin/config.json}"

if [ -n "$XUI_XRAY_ACCESS_LOG" ] || [ -n "$XUI_XRAY_ERROR_LOG" ] || [ -n "$XUI_XRAY_LOG_LEVEL" ]; then
    echo "Configuring Xray logging..."
    
    # Wait for config.json to exist (panel creates it on start)
    # Ждём появления config.json (панель создаёт при старте)
    for i in $(seq 1 30); do
        [ -f "$XRAY_CONFIG" ] && break
        sleep 0.5
    done
    
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "[WARN] Xray config not found, skipping log configuration"
    else
        # Check if xrayTemplateConfig exists in DB, if not - create from config.json
        # Проверяем наличие xrayTemplateConfig в БД, если нет - создаём из config.json
        EXISTING=$(sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" 2>/dev/null || echo "")
        
        if [ -z "$EXISTING" ]; then
            echo "[DB] Creating xrayTemplateConfig from config.json..."
            ESCAPED_CONFIG=$(sed "s/'/''/g" "$XRAY_CONFIG")
            sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '$ESCAPED_CONFIG');"
        fi
        
        TMP_JSON=$(mktemp)
        # Dump directly from DB to file to avoid bash variable expansion issues
        sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" > "$TMP_JSON"
        
        if [ -s "$TMP_JSON" ]; then
            if ! jq empty "$TMP_JSON" >/dev/null 2>&1; then
                echo "[WARN] Invalid xrayTemplateConfig in DB, rebuilding from config.json"
                ESCAPED_CONFIG=$(sed "s/'/''/g" "$XRAY_CONFIG")
                sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', '$ESCAPED_CONFIG');"
                cp "$XRAY_CONFIG" "$TMP_JSON"
            fi

            # Apply log settings using jq
            [ -n "$XUI_XRAY_ACCESS_LOG" ] && jq --arg val "$XUI_XRAY_ACCESS_LOG" '.log.access = $val' "$TMP_JSON" > "${TMP_JSON}.tmp" && mv "${TMP_JSON}.tmp" "$TMP_JSON"
            [ -n "$XUI_XRAY_ERROR_LOG" ] && jq --arg val "$XUI_XRAY_ERROR_LOG" '.log.error = $val' "$TMP_JSON" > "${TMP_JSON}.tmp" && mv "${TMP_JSON}.tmp" "$TMP_JSON"
            [ -n "$XUI_XRAY_LOG_LEVEL" ] && jq --arg val "$XUI_XRAY_LOG_LEVEL" '.log.loglevel = $val' "$TMP_JSON" > "${TMP_JSON}.tmp" && mv "${TMP_JSON}.tmp" "$TMP_JSON"
            
            # Save to config.json formatted
            jq . "$TMP_JSON" > "$XRAY_CONFIG"
            
            # Save back to DB (escaping single quotes for sqlite)
            ESCAPED_NEW=$(sed "s/'/''/g" "$TMP_JSON")
            sqlite3 "$DB_PATH" "UPDATE settings SET value='$ESCAPED_NEW' WHERE key='xrayTemplateConfig';"
            
            rm -f "$TMP_JSON"
            echo "[XRAY] Logging configured via DB: access=${XUI_XRAY_ACCESS_LOG:-none} error=${XUI_XRAY_ERROR_LOG:-none} level=${XUI_XRAY_LOG_LEVEL:-default}"
        else
            rm -f "$TMP_JSON"
            echo "[WARN] Could not read xrayTemplateConfig from DB"
        fi
    fi
fi

# ============================================================================
# Автовыпуск SSL сертификатов (только нативная установка)
# ============================================================================

if [ -n "$XUI_DOMAIN" ] && command -v certbot > /dev/null 2>&1; then
    CERT_PATH="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"

    if [ ! -f "$CERT_PATH" ]; then
        echo "[AUTO-CERT] Сертификат для ${XUI_DOMAIN} не найден, выпускаем..."

        if command -v certbot_issue_domain_cert >/dev/null 2>&1; then
            certbot_issue_domain_cert "${XUI_DOMAIN}" "${XUI_ADMIN_EMAIL:-}" && {
                echo "[AUTO-CERT] ✓ Сертификат для ${XUI_DOMAIN} получен!"

                # Обновляем пути сертификатов в БД
                CERT_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
                KEY_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem"
                sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('webCertFile', '${CERT_FILE}');"
                sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('webKeyFile', '${KEY_FILE}');"
                sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('subCertFile', '${CERT_FILE}');"
                sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('subKeyFile', '${KEY_FILE}');"
                echo "[AUTO-CERT] Пути сертификатов обновлены в БД"
            } || echo "[AUTO-CERT] ⚠ Не удалось получить сертификат (DNS/порт 80?)"
        else
            CERTBOT_EMAIL="${XUI_ADMIN_EMAIL:-}"
            if [ -z "$CERTBOT_EMAIL" ] || [ "$CERTBOT_EMAIL" = "admin@example.com" ]; then
                echo "[AUTO-CERT] XUI_ADMIN_EMAIL не задан, используем --register-unsafely-without-email"
                certbot certonly --standalone --non-interactive --agree-tos \
                    --register-unsafely-without-email \
                    -d "${XUI_DOMAIN}" \
                    --preferred-challenges http 2>&1 && {
                    echo "[AUTO-CERT] ✓ Сертификат для ${XUI_DOMAIN} получен!"

                    # Обновляем пути сертификатов в БД
                    CERT_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
                    KEY_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('webCertFile', '${CERT_FILE}');"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('webKeyFile', '${KEY_FILE}');"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('subCertFile', '${CERT_FILE}');"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('subKeyFile', '${CERT_FILE}');"
                    echo "[AUTO-CERT] Пути сертификатов обновлены в БД"
                } || echo "[AUTO-CERT] ⚠ Не удалось получить сертификат (DNS/порт 80?)"
            else
                certbot certonly --standalone --non-interactive --agree-tos \
                    --email "$CERTBOT_EMAIL" --no-eff-email \
                    -d "${XUI_DOMAIN}" \
                    --preferred-challenges http 2>&1 && {
                    echo "[AUTO-CERT] ✓ Сертификат для ${XUI_DOMAIN} получен!"

                    # Обновляем пути сертификатов в БД
                    CERT_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
                    KEY_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('webCertFile', '${CERT_FILE}');"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('webKeyFile', '${KEY_FILE}');"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('subCertFile', '${CERT_FILE}');"
                    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings(key, value) VALUES('subKeyFile', '${CERT_FILE}');"
                    echo "[AUTO-CERT] Пути сертификатов обновлены в БД"
                } || echo "[AUTO-CERT] ⚠ Не удалось получить сертификат (DNS/порт 80?)"
            fi
        fi
    else
        echo "[AUTO-CERT] ✓ Сертификат для ${XUI_DOMAIN} уже существует"
    fi
fi

echo "Configuration applied!"
