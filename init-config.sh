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

# Terminate any lingering orphaned xray/mtg processes from crashed previous runs to free ports
if command -v pkill >/dev/null 2>&1; then
    pkill -9 -f "xray-linux-amd64" >/dev/null 2>&1 || true
    pkill -9 -f "mtg-linux-amd64" >/dev/null 2>&1 || true
elif command -v killall >/dev/null 2>&1; then
    killall -q -9 xray-linux-amd64 mtg-linux-amd64 2>/dev/null || true
fi

echo "Applying environment configuration..."

sqlite_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

sqlite_db() {
    sqlite3 -cmd ".timeout 15000" "$DB_PATH" "$@"
}

# Enable WAL mode so x-ui traffic updates and scripts never lock each other
sqlite_db "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 15000;" >/dev/null 2>&1 || true

# Deduplicate settings table
sqlite_db "DELETE FROM settings WHERE rowid NOT IN (SELECT MAX(rowid) FROM settings GROUP BY key);" >/dev/null 2>&1 || true

set_always() {
    key=$1
    value=$2

    if [ -n "$value" ]; then
        esc_key=$(sqlite_escape "$key")
        esc_value=$(sqlite_escape "$value")

        sqlite_db "
UPDATE settings SET value = '${esc_value}' WHERE key = '${esc_key}';
INSERT INTO settings (key, value) SELECT '${esc_key}', '${esc_value}' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = '${esc_key}');
"
        echo "[SET] $key = $value"
    fi
}

set_empty() {
    key=$1
    esc_key=$(sqlite_escape "$key")

    sqlite_db "
UPDATE settings SET value = '' WHERE key = '${esc_key}';
INSERT INTO settings (key, value) SELECT '${esc_key}', '' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = '${esc_key}');
"
    echo "[SET] $key = "
}

set_if_empty() {
    key=$1
    value=$2

    if [ -n "$value" ]; then
        esc_key=$(sqlite_escape "$key")
        existing=$(sqlite_db "SELECT value FROM settings WHERE key='${esc_key}' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")

        if [ -z "$existing" ]; then
            esc_value=$(sqlite_escape "$value")
            sqlite_db "
UPDATE settings SET value = '${esc_value}' WHERE key = '${esc_key}';
INSERT INTO settings (key, value) SELECT '${esc_key}', '${esc_value}' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = '${esc_key}');
"
            echo "[NEW] $key = $value"
        fi
    fi
}

get_setting_value() {
    key=$1
    esc_key=$(sqlite_escape "$key")
    sqlite_db "SELECT value FROM settings WHERE key='${esc_key}' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo ""
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

    if sqlite_db "SELECT 1 FROM inbounds WHERE port='$port' LIMIT 1;" 2>/dev/null | grep -q 1; then
        return 1
    fi

    if sqlite_db "SELECT 1 FROM settings WHERE key IN ('webPort','subPort') AND value='$port' LIMIT 1;" 2>/dev/null | grep -q 1; then
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

find_xui_binary() {
    for b in "/usr/local/x-ui/x-ui" "/app/x-ui" "$(command -v x-ui 2>/dev/null)"; do
        if [ -n "$b" ] && [ -x "$b" ]; then
            if head -c 4 "$b" 2>/dev/null | grep -q "ELF"; then
                echo "$b"
                return 0
            fi
        fi
    done
    return 1
}

if [ -n "$XUI_ADMIN_PASSWORD" ]; then
    CURRENT_USER="$XUI_ADMIN_USERNAME"
    if [ -z "$CURRENT_USER" ]; then
        CURRENT_USER=$(sqlite_db "SELECT username FROM users LIMIT 1;" 2>/dev/null || echo "admin")
        [ -n "$CURRENT_USER" ] || CURRENT_USER="admin"
    fi
    XUI_BIN=$(find_xui_binary || true)
    if [ -n "$XUI_BIN" ]; then
        # 3x-ui utilizes bcrypt hashing for passwords; use setting CLI to hash correctly
        "$XUI_BIN" setting -username "$CURRENT_USER" -password "$XUI_ADMIN_PASSWORD" >/dev/null 2>&1 || true
        echo "[CREDS] Admin credentials set (bcrypt)"
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import bcrypt" 2>/dev/null; then
        HASHED_PASS=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$XUI_ADMIN_PASSWORD', bcrypt.gensalt(10)).decode())")
        esc_pass=$(sqlite_escape "$HASHED_PASS")
        esc_user=$(sqlite_escape "$CURRENT_USER")
        sqlite_db "UPDATE users SET username='${esc_user}', password='${esc_pass}' WHERE id=1;"
        echo "[CREDS] Admin credentials set (python bcrypt)"
    else
        echo "[CREDS] Warning: cannot hash password with bcrypt (x-ui binary not found)"
    fi
elif [ -n "$XUI_ADMIN_USERNAME" ]; then
    esc_username=$(sqlite_escape "$XUI_ADMIN_USERNAME")
    sqlite_db "UPDATE users SET username='${esc_username}' WHERE id=1;"
    echo "[CREDS] Admin username set"
fi

if [ -n "$XUI_SECRET_KEY" ]; then
    set_always "secret" "$XUI_SECRET_KEY"
fi

# ============================================================================
# Domain and Certificate Helpers
# ============================================================================

get_public_ip() {
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com"
    do
        ip=$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d ' \n\r' || true)

        case "$ip" in
            *.*)
                echo "$ip"
                return 0
                ;;
        esac
    done

    return 1
}

resolve_domain_a_records() {
    domain="$1"

    if command -v dig >/dev/null 2>&1; then
        dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true
        return 0
    fi

    return 1
}

domain_points_to_this_server() {
    domain="$1"

    [ -n "$domain" ] || return 1

    if ! command -v curl >/dev/null 2>&1; then
        echo "[DNS-CHECK] curl not found, cannot detect public IP"
        return 1
    fi

    server_ip=$(get_public_ip || true)

    if [ -z "$server_ip" ]; then
        echo "[DNS-CHECK] Cannot detect server public IP"
        return 1
    fi

    resolved_ips=$(resolve_domain_a_records "$domain" || true)

    if [ -z "$resolved_ips" ]; then
        echo "[DNS-CHECK] FAIL: $domain has no A records"
        echo "[DNS-CHECK] Server IP: $server_ip"
        return 1
    fi

    if echo "$resolved_ips" | grep -qx "$server_ip"; then
        echo "[DNS-CHECK] OK: $domain -> $server_ip"
        return 0
    fi

    echo "[DNS-CHECK] FAIL: $domain does not point to this server"
    echo "[DNS-CHECK] Server IP: $server_ip"
    echo "[DNS-CHECK] Domain IPs: $(echo "$resolved_ips" | tr '\n' ' ')"

    return 1
}

cert_is_valid_for_domain() {
    domain="$1"

    cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
    key_file="/etc/letsencrypt/live/${domain}/privkey.pem"

    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        echo "[CERT-CHECK] FAIL: certificate files not found for $domain"
        return 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        echo "[CERT-CHECK] openssl not found, cannot validate certificate"
        return 1
    fi

    if ! openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1; then
        echo "[CERT-CHECK] FAIL: certificate for $domain is expired or expires within 24h"
        return 1
    fi

    if openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -q "DNS:${domain}"; then
        echo "[CERT-CHECK] OK: certificate SAN contains DNS:$domain"
        return 0
    fi

    subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null || true)

    case "$subject" in
        *"CN = $domain"*|*"CN=$domain"*)
            echo "[CERT-CHECK] OK: certificate CN matches $domain"
            return 0
            ;;
    esac

    echo "[CERT-CHECK] FAIL: certificate does not match $domain"
    return 1
}

issue_cert_for_domain() {
    domain="$1"
    email="$2"

    [ -n "$domain" ] || return 1

    echo "[AUTO-CERT] Issuing certificate for $domain"

    if command -v certbot_issue_domain_cert >/dev/null 2>&1; then
        certbot_issue_domain_cert "$domain" "$email"
        return $?
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        echo "[AUTO-CERT] certbot not found"
        return 1
    fi

    if [ -z "$email" ] || [ "$email" = "admin@example.com" ]; then
        echo "[AUTO-CERT] XUI_ADMIN_EMAIL not set, using --register-unsafely-without-email"

        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email \
            -d "$domain" \
            --preferred-challenges http
    else
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "$email" --no-eff-email \
            -d "$domain" \
            --preferred-challenges http
    fi
}

try_use_domain() {
    domain="$1"
    email="$2"

    [ -n "$domain" ] || return 1

    echo "[DOMAIN] Checking domain: $domain"

    cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
    key_file="/etc/letsencrypt/live/${domain}/privkey.pem"

    # If a valid certificate already exists, use it without requiring a DNS check.
    # A temporary external IP API failure (ipify/ifconfig.me) would otherwise clear
    # the cert paths from the DB and break SSL for all clients.
    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        echo "[AUTO-CERT] Existing certificate found for $domain"

        if cert_is_valid_for_domain "$domain"; then
            echo "[AUTO-CERT] Valid certificate exists for $domain — skipping DNS check"
            return 0
        fi

        echo "[AUTO-CERT] Existing certificate is invalid for $domain, trying to reissue"
        # Fall through to DNS check before reissuing
    fi

    # DNS check is only required when we need to issue (or reissue) a certificate.
    if ! domain_points_to_this_server "$domain"; then
        echo "[DOMAIN] Rejecting $domain: DNS does not point to this server"
        return 1
    fi

    if ! issue_cert_for_domain "$domain" "$email"; then
        echo "[AUTO-CERT] Failed to issue certificate for $domain"
        return 1
    fi

    if ! cert_is_valid_for_domain "$domain"; then
        echo "[AUTO-CERT] Certificate was issued, but validation failed for $domain"
        return 1
    fi

    echo "[AUTO-CERT] Domain $domain passed all checks"
    return 0
}

sync_inbound_tls_certs() {
    target_domain=$1
    target_cert_file=$2
    target_key_file=$3

    case "${XUI_SYNC_INBOUND_CERTS:-true}" in
        true|TRUE|1|yes|YES|on|ON) ;;
        *)
            echo "[INBOUND-CERT] Sync disabled"
            return 0
            ;;
    esac

    # 1. Resolve target certificate from DB or disk if not provided or missing
    if [ -z "$target_cert_file" ] || [ ! -f "$target_cert_file" ] || [ ! -f "$target_key_file" ]; then
        db_cert=$(sqlite_db "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || echo "")
        db_key=$(sqlite_db "SELECT value FROM settings WHERE key='webKeyFile';" 2>/dev/null || echo "")
        db_dom=$(sqlite_db "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "")
        if [ -n "$db_cert" ] && [ -f "$db_cert" ] && [ -f "$db_key" ]; then
            target_cert_file="$db_cert"
            target_key_file="$db_key"
            target_domain="${db_dom:-$target_domain}"
        fi
    fi

    if [ -z "$target_cert_file" ] || [ ! -f "$target_cert_file" ] || [ ! -f "$target_key_file" ]; then
        discovered_cert=$(find /etc/letsencrypt/live/ -name "fullchain.pem" 2>/dev/null | head -n 1)
        if [ -n "$discovered_cert" ]; then
            discovered_domain=$(echo "$discovered_cert" | awk -F'/' '{print $(NF-1)}')
            discovered_key="/etc/letsencrypt/live/${discovered_domain}/privkey.pem"
            if [ -f "$discovered_key" ]; then
                target_cert_file="$discovered_cert"
                target_key_file="$discovered_key"
                target_domain="$discovered_domain"
                echo "[INBOUND-CERT] Auto-discovered active certificate for domain: $target_domain"
            fi
        fi
    fi

    rows=$(sqlite_db -separator '|' "
SELECT id,
       COALESCE(json_extract(stream_settings, '$.tlsSettings.serverName'), ''),
       COALESCE(json_extract(stream_settings, '$.tlsSettings.certificates[0].certificateFile'), ''),
       COALESCE(json_extract(stream_settings, '$.tlsSettings.certificates[0].keyFile'), '')
FROM inbounds
WHERE enable = 1
  AND json_valid(stream_settings)
  AND json_extract(stream_settings, '$.security') = 'tls'
  AND json_extract(stream_settings, '$.tlsSettings.certificates[0].certificateFile') IS NOT NULL
  AND json_extract(stream_settings, '$.tlsSettings.certificates[0].keyFile') IS NOT NULL;
" 2>/dev/null || true)

    [ -n "$rows" ] || return 0

    has_target_cert=0
    if [ -n "$target_cert_file" ] && [ -f "$target_cert_file" ] && [ -f "$target_key_file" ]; then
        has_target_cert=1
    fi

    server_ip=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n 1)
    [ -n "$server_ip" ] || server_ip="127.0.0.1"

    fallback_cert="/etc/x-ui/fallback-inbound.crt"
    fallback_key="/etc/x-ui/fallback-inbound.key"

    printf "%s\n" "$rows" | while IFS='|' read -r inbound_id current_server current_cert_file current_key_file; do
        [ -n "$inbound_id" ] || continue

        if [ "$has_target_cert" -eq 1 ]; then
            # Skip if already up-to-date with target domain and cert files
            if [ "$current_cert_file" = "$target_cert_file" ] && [ "$current_key_file" = "$target_key_file" ] && [ "$current_server" = "$target_domain" ]; then
                continue
            fi

            esc_domain=$(sqlite_escape "$target_domain")
            esc_cert_file=$(sqlite_escape "$target_cert_file")
            esc_key_file=$(sqlite_escape "$target_key_file")

            sqlite_db "
UPDATE inbounds
SET stream_settings = json_set(
  stream_settings,
  '$.tlsSettings.serverName', '${esc_domain}',
  '$.tlsSettings.certificates[0].certificateFile', '${esc_cert_file}',
  '$.tlsSettings.certificates[0].keyFile', '${esc_key_file}'
)
WHERE id = ${inbound_id};
"
            echo "[INBOUND-CERT] Updated inbound id=${inbound_id}: ${current_server:-none} (${current_cert_file}) -> ${target_domain} (${target_cert_file})"
        else
            # Keep existing cert if file exists on disk and is valid
            if [ -f "$current_cert_file" ] && [ -f "$current_key_file" ]; then
                continue
            fi

            # Apply fallback self-signed cert if current file is missing
            if [ ! -f "$fallback_cert" ] || [ ! -f "$fallback_key" ]; then
                mkdir -p "/etc/x-ui"
                if command -v openssl >/dev/null 2>&1; then
                    openssl req -x509 -newkey rsa:2048 -nodes                         -keyout "$fallback_key"                         -out "$fallback_cert"                         -days 3650                         -subj "/CN=${server_ip}" >/dev/null 2>&1 || true
                fi
            fi

            if [ -f "$fallback_cert" ] && [ -f "$fallback_key" ]; then
                esc_cert_file=$(sqlite_escape "$fallback_cert")
                esc_key_file=$(sqlite_escape "$fallback_key")
                esc_server_name=$(sqlite_escape "${target_domain:-$server_ip}")

                sqlite_db "
UPDATE inbounds
SET stream_settings = json_set(
  stream_settings,
  '$.tlsSettings.serverName', '${esc_server_name}',
  '$.tlsSettings.certificates[0].certificateFile', '${esc_cert_file}',
  '$.tlsSettings.certificates[0].keyFile', '${esc_key_file}'
)
WHERE id = ${inbound_id};
"
                echo "[INBOUND-CERT] Inbound id=${inbound_id}: missing cert (${current_cert_file}) -> fallback cert applied (CN=${server_ip})"
            else
                echo "[INBOUND-CERT] Warning: missing cert for inbound id=${inbound_id} (${current_cert_file})"
            fi
        fi
    done
}

# ============================================================================
# Domain Detection
# ============================================================================

ENV_DOMAIN="$XUI_DOMAIN"
DB_DOMAIN=$(get_setting_value "webDomain")

FINAL_DOMAIN=""
CERT_FILE=""
KEY_FILE=""
SUB_DOMAIN=""
SUB_CERT_FILE=""
SUB_KEY_FILE=""

if [ -n "$DB_DOMAIN" ]; then
    echo "[DOMAIN] Database domain found: $DB_DOMAIN"
fi

if [ -n "$ENV_DOMAIN" ]; then
    echo "[DOMAIN] Env domain found: $ENV_DOMAIN"
fi

# ============================================================================
# Auto SSL certificates with strict DNS validation
# ============================================================================

if command -v certbot >/dev/null 2>&1 || command -v certbot_issue_domain_cert >/dev/null 2>&1; then
    CERTBOT_EMAIL="${XUI_ADMIN_EMAIL:-}"

    # 1. If ENV_DOMAIN is set and differs from DB_DOMAIN,
    #    treat ENV_DOMAIN as an intentional domain change.
    if [ -n "$ENV_DOMAIN" ] && [ "$ENV_DOMAIN" != "$DB_DOMAIN" ]; then
        echo "[DOMAIN] Env domain differs from database domain"
        echo "[DOMAIN] Database domain: ${DB_DOMAIN:-none}"
        echo "[DOMAIN] Env domain: $ENV_DOMAIN"
        echo "[DOMAIN] Trying env domain first"

        if try_use_domain "$ENV_DOMAIN" "$CERTBOT_EMAIL"; then
            FINAL_DOMAIN="$ENV_DOMAIN"
            echo "[DOMAIN] Using env domain: $FINAL_DOMAIN"
        else
            echo "[DOMAIN] Env domain is not usable: $ENV_DOMAIN"
            echo "[DOMAIN] Falling back to database domain if available"
        fi
    fi

    # 2. If ENV_DOMAIN was not selected, try DB_DOMAIN.
    if [ -z "$FINAL_DOMAIN" ] && [ -n "$DB_DOMAIN" ]; then
        echo "[DOMAIN] Trying database domain: $DB_DOMAIN"

        if try_use_domain "$DB_DOMAIN" "$CERTBOT_EMAIL"; then
            FINAL_DOMAIN="$DB_DOMAIN"
            echo "[DOMAIN] Using database domain: $FINAL_DOMAIN"
        else
            echo "[DOMAIN] Database domain is not usable: $DB_DOMAIN"
        fi
    fi

    # 3. If there is no DB_DOMAIN or DB_DOMAIN failed,
    #    try ENV_DOMAIN as a final fallback.
    if [ -z "$FINAL_DOMAIN" ] && [ -n "$ENV_DOMAIN" ]; then
        echo "[DOMAIN] Trying env domain as fallback: $ENV_DOMAIN"

        if try_use_domain "$ENV_DOMAIN" "$CERTBOT_EMAIL"; then
            FINAL_DOMAIN="$ENV_DOMAIN"
            echo "[DOMAIN] Using env domain: $FINAL_DOMAIN"
        else
            echo "[DOMAIN] Env domain is not usable: $ENV_DOMAIN"
        fi
    fi

    if [ -n "$FINAL_DOMAIN" ]; then
        XUI_DOMAIN="$FINAL_DOMAIN"
        export XUI_DOMAIN

        CERT_FILE="/etc/letsencrypt/live/${FINAL_DOMAIN}/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/${FINAL_DOMAIN}/privkey.pem"

        if [ -n "$XUI_SUB_DOMAIN" ] && [ "$XUI_SUB_DOMAIN" != "$FINAL_DOMAIN" ]; then
            SUB_DOMAIN="$XUI_SUB_DOMAIN"

            echo "[SUB-DOMAIN] Separate subscription domain configured: $SUB_DOMAIN"

            if try_use_domain "$SUB_DOMAIN" "$CERTBOT_EMAIL"; then
                SUB_CERT_FILE="/etc/letsencrypt/live/${SUB_DOMAIN}/fullchain.pem"
                SUB_KEY_FILE="/etc/letsencrypt/live/${SUB_DOMAIN}/privkey.pem"
                echo "[SUB-DOMAIN] Using separate subscription domain: $SUB_DOMAIN"
            else
                echo "[SUB-DOMAIN] Separate subscription domain is not usable, falling back to panel domain"
                SUB_DOMAIN="$FINAL_DOMAIN"
                SUB_CERT_FILE="$CERT_FILE"
                SUB_KEY_FILE="$KEY_FILE"
            fi
        else
            SUB_DOMAIN="${XUI_SUB_DOMAIN:-$FINAL_DOMAIN}"
            SUB_CERT_FILE="$CERT_FILE"
            SUB_KEY_FILE="$KEY_FILE"
        fi

        set_always "webDomain" "$FINAL_DOMAIN"
        set_always "webCertFile" "$CERT_FILE"
        set_always "webKeyFile" "$KEY_FILE"

        set_always "subDomain" "$SUB_DOMAIN"
        set_always "subCertFile" "$SUB_CERT_FILE"
        set_always "subKeyFile" "$SUB_KEY_FILE"

        echo "[DOMAIN] Final domain saved to DB: $FINAL_DOMAIN"
        echo "[DOMAIN] Certificate paths saved to DB"
    else
        echo "[DOMAIN] No usable domain found. SSL not configured."

        XUI_DOMAIN=""
        CERT_FILE=""
        KEY_FILE=""
        SUB_DOMAIN=""
        SUB_CERT_FILE=""
        SUB_KEY_FILE=""
    fi
else
    echo "[AUTO-CERT] certbot is not installed, skipping certificate issue"

    if [ -n "$ENV_DOMAIN" ] && [ "$ENV_DOMAIN" != "$DB_DOMAIN" ]; then
        echo "[DOMAIN] Using env domain without certbot: $ENV_DOMAIN"
        XUI_DOMAIN="$ENV_DOMAIN"
    elif [ -n "$DB_DOMAIN" ]; then
        XUI_DOMAIN="$DB_DOMAIN"
    elif [ -n "$ENV_DOMAIN" ]; then
        XUI_DOMAIN="$ENV_DOMAIN"
    else
        XUI_DOMAIN=""
    fi

    if [ -n "$XUI_DOMAIN" ]; then
        DEFAULT_CERT_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
        DEFAULT_KEY_FILE="/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem"

        CERT_FILE="${XUI_CERT_FILE:-$DEFAULT_CERT_FILE}"
        KEY_FILE="${XUI_KEY_FILE:-$DEFAULT_KEY_FILE}"

        if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
            echo "[WARN] Certificate files for ${XUI_DOMAIN} not found"
            CERT_FILE=""
            KEY_FILE=""
        fi

        if [ -n "$XUI_SUB_DOMAIN" ] && [ "$XUI_SUB_DOMAIN" != "$XUI_DOMAIN" ]; then
            SUB_DOMAIN="$XUI_SUB_DOMAIN"
            SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/fullchain.pem}"
            SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-/etc/letsencrypt/live/${XUI_SUB_DOMAIN}/privkey.pem}"
        else
            SUB_DOMAIN="${XUI_SUB_DOMAIN:-$XUI_DOMAIN}"
            SUB_CERT_FILE="${XUI_SUB_CERT_FILE:-$CERT_FILE}"
            SUB_KEY_FILE="${XUI_SUB_KEY_FILE:-$KEY_FILE}"
        fi

        if [ -n "$SUB_CERT_FILE" ] && { [ ! -f "$SUB_CERT_FILE" ] || [ ! -f "$SUB_KEY_FILE" ]; }; then
            SUB_CERT_FILE=""
            SUB_KEY_FILE=""
        fi
    fi
fi

# ============================================================================
# HTTP fallback if no SSL domain
# ============================================================================

if [ -z "$XUI_DOMAIN" ]; then
    echo "[WARN] No valid domain specified, SSL not configured"

    CERT_FILE=""
    KEY_FILE=""
    SUB_DOMAIN=""
    SUB_CERT_FILE=""
    SUB_KEY_FILE=""

    if [ "$XUI_ALLOW_HTTP" = "true" ]; then
        echo "[HTTP] HTTP mode enabled - panel accessible via http://server-ip:${XUI_PORT:-2053}"
    else
        echo "[TIP] Use SSH tunnel: ssh -N -L 8080:localhost:${XUI_PORT:-2053} user@server"
        echo "[TIP] Or set XUI_ALLOW_HTTP=true for HTTP access (insecure!)"
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

if [ -n "$XUI_DOMAIN" ]; then
    set_always "webDomain" "$XUI_DOMAIN"
else
    set_empty "webDomain"
fi

if [ -n "$CERT_FILE" ]; then
    set_always "webCertFile" "$CERT_FILE"
else
    set_empty "webCertFile"
fi

if [ -n "$KEY_FILE" ]; then
    set_always "webKeyFile" "$KEY_FILE"
else
    set_empty "webKeyFile"
fi

set_always "webBasePath" "$XUI_BASE_PATH"

# Subscription / Подписка
set_always "subEnable" "$XUI_SUB_ENABLE"
set_always "subPort" "$XUI_SUB_PORT"
set_always "subPath" "$XUI_SUB_PATH"

if [ -n "$SUB_DOMAIN" ]; then
    set_always "subDomain" "$SUB_DOMAIN"
elif [ -n "$XUI_SUB_DOMAIN" ]; then
    set_always "subDomain" "$XUI_SUB_DOMAIN"
elif [ -n "$XUI_DOMAIN" ]; then
    set_always "subDomain" "$XUI_DOMAIN"
else
    set_empty "subDomain"
fi

if [ -n "$SUB_CERT_FILE" ]; then
    set_always "subCertFile" "$SUB_CERT_FILE"
else
    set_empty "subCertFile"
fi

if [ -n "$SUB_KEY_FILE" ]; then
    set_always "subKeyFile" "$SUB_KEY_FILE"
else
    set_empty "subKeyFile"
fi

# Resolve any collision between subPort and existing inbound ports
sub_port_val=$(get_setting_value "subPort")
if [ -n "$sub_port_val" ] && [ "$sub_port_val" -gt 0 ] 2>/dev/null; then
    conflicting_inbound=$(sqlite_db "SELECT id || ' (' || tag || ')' FROM inbounds WHERE enable = 1 AND port = ${sub_port_val} LIMIT 1;" 2>/dev/null || echo "")
    if [ -n "$conflicting_inbound" ]; then
        echo "[WARN] Subscription port ${sub_port_val} conflicts with inbound ${conflicting_inbound}"
        new_sub_port=$((sub_port_val + 1))
        while [ "$(sqlite_db "SELECT count(*) FROM inbounds WHERE port = ${new_sub_port};" 2>/dev/null || echo "1")" -gt 0 ]; do
            new_sub_port=$((new_sub_port + 1))
        done
        set_always "subPort" "$new_sub_port"
        echo "[AUTO-FIX] Shifted subPort to ${new_sub_port} to prevent Xray port collision"
    fi
fi

# Inbound TLS certificates are stored separately in inbounds.stream_settings.
# Keep them in sync only when the saved certificate path is broken.
sync_inbound_tls_certs "$XUI_DOMAIN" "$CERT_FILE" "$KEY_FILE"

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
# Xray Logging / Логирование Xray через БД
# ============================================================================

XRAY_CONFIG="${XUI_XRAY_CONFIG:-/app/bin/config.json}"

if [ -n "$XUI_XRAY_ACCESS_LOG" ] || [ -n "$XUI_XRAY_ERROR_LOG" ] || [ -n "$XUI_XRAY_LOG_LEVEL" ]; then
    echo "Configuring Xray logging..."

    for i in $(seq 1 30); do
        [ -f "$XRAY_CONFIG" ] && break
        sleep 0.5
    done

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "[WARN] Xray config not found, skipping log configuration"
    else
        # Run the entire jq/sqlite pipeline in a subshell so that any unexpected
        # non-zero exit (e.g. jq exit 5 on a system error) does not propagate
        # through 'set -e' and abort the parent script.
        _configure_xray_logging() {
            EXISTING=$(sqlite_db "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" 2>/dev/null || echo "")

            if [ -z "$EXISTING" ]; then
                echo "[DB] Creating xrayTemplateConfig from config.json..."

                TMP_ESCAPED=$(mktemp)
                sed "s/'/''/g" "$XRAY_CONFIG" > "$TMP_ESCAPED"
                ESCAPED_CONFIG=$(cat "$TMP_ESCAPED")
                rm -f "$TMP_ESCAPED"

                sqlite_db "INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '$ESCAPED_CONFIG');"
            fi

            TMP_JSON=$(mktemp)
            sqlite_db "SELECT value FROM settings WHERE key='xrayTemplateConfig';" > "$TMP_JSON"

            if [ -s "$TMP_JSON" ]; then
                if ! jq empty "$TMP_JSON" >/dev/null 2>&1; then
                    echo "[WARN] Invalid xrayTemplateConfig in DB, rebuilding from config.json"

                    TMP_ESCAPED=$(mktemp)
                    sed "s/'/''/g" "$XRAY_CONFIG" > "$TMP_ESCAPED"
                    ESCAPED_CONFIG=$(cat "$TMP_ESCAPED")
                    rm -f "$TMP_ESCAPED"

                    sqlite_db "DELETE FROM settings WHERE key='xrayTemplateConfig';"
                    sqlite_db "INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '$ESCAPED_CONFIG');"

                    cp "$XRAY_CONFIG" "$TMP_JSON"
                fi

                [ -n "$XUI_XRAY_ACCESS_LOG" ] && jq --arg val "$XUI_XRAY_ACCESS_LOG" '.log.access = $val' "$TMP_JSON" > "${TMP_JSON}.tmp" && mv "${TMP_JSON}.tmp" "$TMP_JSON"
                [ -n "$XUI_XRAY_ERROR_LOG" ] && jq --arg val "$XUI_XRAY_ERROR_LOG" '.log.error = $val' "$TMP_JSON" > "${TMP_JSON}.tmp" && mv "${TMP_JSON}.tmp" "$TMP_JSON"
                [ -n "$XUI_XRAY_LOG_LEVEL" ] && jq --arg val "$XUI_XRAY_LOG_LEVEL" '.log.loglevel = $val' "$TMP_JSON" > "${TMP_JSON}.tmp" && mv "${TMP_JSON}.tmp" "$TMP_JSON"

                jq . "$TMP_JSON" > "$XRAY_CONFIG"

                TMP_ESCAPED=$(mktemp)
                sed "s/'/''/g" "$TMP_JSON" > "$TMP_ESCAPED"
                ESCAPED_NEW=$(cat "$TMP_ESCAPED")
                rm -f "$TMP_ESCAPED"

                sqlite_db "UPDATE settings SET value='$ESCAPED_NEW' WHERE key='xrayTemplateConfig';"

                rm -f "$TMP_JSON"

                echo "[XRAY] Logging configured via DB: access=${XUI_XRAY_ACCESS_LOG:-none} error=${XUI_XRAY_ERROR_LOG:-none} level=${XUI_XRAY_LOG_LEVEL:-default}"
            else
                rm -f "$TMP_JSON"
                echo "[WARN] Could not read xrayTemplateConfig from DB"
            fi
        }

        _configure_xray_logging || echo "[WARN] Xray logging configuration failed (non-fatal)"
    fi
fi

echo "Configuration applied!"
