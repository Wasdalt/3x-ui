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

# Load environment configuration if available
if [ -f "/etc/x-ui/.env" ] && [ -r "/etc/x-ui/.env" ]; then
    set -a
    . "/etc/x-ui/.env"
    set +a
elif [ -f "${SCRIPT_DIR}/.env" ] && [ -r "${SCRIPT_DIR}/.env" ]; then
    set -a
    . "${SCRIPT_DIR}/.env"
    set +a
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
# ONLY if x-ui itself is NOT currently running and orphan cleanup is not explicitly skipped
if [ "${XUI_SKIP_PKILL:-false}" != "true" ]; then
    is_xui_running() {
        if command -v systemctl >/dev/null 2>&1; then
            systemctl is-active --quiet x-ui 2>/dev/null && return 0
        fi
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -f "^/usr/local/x-ui/x-ui" >/dev/null 2>&1 && return 0
        fi
        return 1
    }

    if ! is_xui_running; then
        if command -v pkill >/dev/null 2>&1; then
            pkill -9 -f "xray-linux-amd64" >/dev/null 2>&1 || true
            pkill -9 -f "mtg-linux-amd64" >/dev/null 2>&1 || true
        elif command -v killall >/dev/null 2>&1; then
            killall -q -9 xray-linux-amd64 mtg-linux-amd64 2>/dev/null || true
        fi
    else
        echo "[INIT] x-ui service is already running, skipping orphan process cleanup"
    fi
fi

# Save current database inode so fork-db-apply can distinguish restores from traffic updates
INODE_FILE="/run/x-ui-fork-db-apply.inode"
if [ -f "$DB_PATH" ]; then
    stat -c '%i' "$DB_PATH" > "$INODE_FILE" 2>/dev/null || true
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

get_all_server_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | grep -vE '^(127\.|172\.(1[7-9]|2[0-9]|3[0-1])\.|169\.254\.)' || true
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(127\.|172\.(1[7-9]|2[0-9]|3[0-1])\.|169\.254\.)' || true
    fi
    get_public_ip || true
    [ -n "${XUI_SERVER_IP:-}" ] && echo "$XUI_SERVER_IP"
}

domain_points_to_this_server() {
    domain="$1"

    [ -n "$domain" ] || return 1

    case "${XUI_SKIP_DNS_CHECK:-${XUI_DNS_CHECK_SKIP:-false}}" in
        true|TRUE|1|yes|YES|on|ON)
            echo "[DNS-CHECK] Skipping DNS validation via XUI_SKIP_DNS_CHECK"
            return 0
            ;;
    esac

    all_server_ips=$(get_all_server_ips | tr ' ' '\n' | sort -u | grep -v '^$' || true)

    if [ -z "$all_server_ips" ]; then
        echo "[DNS-CHECK] Warning: Cannot detect server IPs, proceeding with cert issue attempt"
        return 0
    fi

    resolved_ips=$(resolve_domain_a_records "$domain" || true)

    if [ -z "$resolved_ips" ]; then
        echo "[DNS-CHECK] FAIL: $domain has no A records"
        echo "[DNS-CHECK] Server IPs: $(echo "$all_server_ips" | tr '\n' ' ')"
        return 1
    fi

    for r_ip in $resolved_ips; do
        if echo "$all_server_ips" | grep -qx "$r_ip"; then
            echo "[DNS-CHECK] OK: $domain -> $r_ip matches server IP"
            return 0
        fi
    done

    echo "[DNS-CHECK] FAIL: $domain does not point to this server"
    echo "[DNS-CHECK] Server IPs: $(echo "$all_server_ips" | tr '\n' ' ')"
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

    port_opt=""
    if ss -tlpn 2>/dev/null | grep -q ':80 ' || netstat -tlpn 2>/dev/null | grep -q ':80 '; then
        port_opt="--http-01-port 8088"
    fi

    if [ -z "$email" ] || [ "$email" = "admin@example.com" ]; then
        echo "[AUTO-CERT] XUI_ADMIN_EMAIL not set, using --register-unsafely-without-email"

        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email \
            ${port_opt} \
            -d "$domain" \
            --preferred-challenges http || true
    else
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "$email" --no-eff-email \
            ${port_opt} \
            -d "$domain" \
            --preferred-challenges http || true
    fi
}

try_use_domain() {
    domain="$1"
    email="$2"

    [ -n "$domain" ] || return 1

    echo "[DOMAIN] Checking domain: $domain"

    cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
    key_file="/etc/letsencrypt/live/${domain}/privkey.pem"

    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        echo "[AUTO-CERT] Existing certificate found for $domain"

        if cert_is_valid_for_domain "$domain"; then
            echo "[AUTO-CERT] Valid certificate exists for $domain — skipping DNS check"
            return 0
        fi

        echo "[AUTO-CERT] Existing certificate is invalid for $domain, trying to reissue"
    fi

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

        # 1. If inbound already has valid cert files on disk, NEVER touch it!
        if [ -n "$current_cert_file" ] && [ -f "$current_cert_file" ] && [ -n "$current_key_file" ] && [ -f "$current_key_file" ]; then
            continue
        fi

        # 2. If inbound has its own serverName and its certificate exists under /etc/letsencrypt/live/${current_server}/
        if [ -n "$current_server" ] && [ -f "/etc/letsencrypt/live/${current_server}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${current_server}/privkey.pem" ]; then
            own_cert="/etc/letsencrypt/live/${current_server}/fullchain.pem"
            own_key="/etc/letsencrypt/live/${current_server}/privkey.pem"
            esc_own_cert=$(sqlite_escape "$own_cert")
            esc_own_key=$(sqlite_escape "$own_key")
            sqlite_db "
UPDATE inbounds
SET stream_settings = json_set(
  stream_settings,
  '$.tlsSettings.certificates[0].certificateFile', '${esc_own_cert}',
  '$.tlsSettings.certificates[0].keyFile', '${esc_own_key}'
)
WHERE id = ${inbound_id};
"
            echo "[INBOUND-CERT] Linked inbound id=${inbound_id} to its domain certificate: ${current_server}"
            continue
        fi

        # 3. Only if current cert is missing from disk, fallback to target cert or self-signed
        if [ "$has_target_cert" -eq 1 ]; then
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
            echo "[INBOUND-CERT] Fallback inbound id=${inbound_id}: missing cert -> ${target_domain} (${target_cert_file})"
        else
            # Apply fallback self-signed cert if current file is missing
            if [ ! -f "$fallback_cert" ] || [ ! -f "$fallback_key" ]; then
                mkdir -p "/etc/x-ui"
                if command -v openssl >/dev/null 2>&1; then
                    openssl req -x509 -newkey rsa:2048 -nodes \
                        -keyout "$fallback_key" \
                        -out "$fallback_cert" \
                        -days 3650 \
                        -subj "/CN=${server_ip}" >/dev/null 2>&1 || true
                fi
            fi

            if [ -f "$fallback_cert" ] && [ -f "$fallback_key" ]; then
                esc_cert_file=$(sqlite_escape "$fallback_cert")
                esc_key_file=$(sqlite_escape "$fallback_key")
                esc_server_name=$(sqlite_escape "${current_server:-${target_domain:-$server_ip}}")

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

sync_haproxy_and_hosts() {
    target_domain=$1
    haproxy_cfg_file="${XUI_HAPROXY_CFG:-/etc/x-ui/haproxy.cfg}"

    case "${XUI_HAPROXY_ENABLE:-true}" in
        true|TRUE|1|yes|YES|on|ON) ;;
        *)
            echo "[HAPROXY] Disabled via XUI_HAPROXY_ENABLE"
            return 0
            ;;
    esac

    command -v sqlite3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
        echo "[HAPROXY] sqlite3 or jq not found, skipping HAProxy synchronization"
        return 0
    }

    # 1. Resolve target domain for clients / subscriptions
    if [ -n "$XUI_HAPROXY_DOMAIN" ]; then
        target_domain="$XUI_HAPROXY_DOMAIN"
    fi
    if [ -z "$target_domain" ] || [ "$target_domain" = "127.0.0.1" ]; then
        db_sub=$(sqlite_db "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
        db_web=$(sqlite_db "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "")
        target_domain="${db_sub:-${db_web}}"
    fi
    if [ -z "$target_domain" ] || [ "$target_domain" = "127.0.0.1" ]; then
        discovered_ip=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n 1)
        target_domain="${discovered_ip:-127.0.0.1}"
    fi

    sqlite_db "
UPDATE settings
SET value = json_set(value, '$.metrics.listen', '127.0.0.1:61111')
WHERE key = 'xrayTemplateConfig'
  AND json_valid(value)
  AND json_extract(value, '$.metrics.listen') = '127.0.0.1:11111';
" >/dev/null 2>&1 || true

    inbound_443=$(sqlite_db "SELECT id FROM inbounds WHERE enable = 1 AND port = 443 AND protocol != 'hysteria' LIMIT 1;" 2>/dev/null || echo "")
    if [ -n "$inbound_443" ]; then
        echo "[HAPROXY] Inbound id=${inbound_443} is listening on 443, shifting to internal port 10443 for HAProxy"
        sqlite_db "UPDATE inbounds SET port = 10443 WHERE id = ${inbound_443};"
    fi

    selfsteal_port_safe="${XUI_SELFSTEAL_PORT:-10444}"
    reality_rows=$(sqlite_db -separator '|' "
SELECT id, stream_settings
FROM inbounds
WHERE enable = 1
  AND json_valid(stream_settings)
  AND json_extract(stream_settings, '$.security') = 'reality';
" 2>/dev/null || true)

    if [ -n "$reality_rows" ]; then
        printf "%s\n" "$reality_rows" | while IFS='|' read -r r_id r_stream; do
            [ -n "$r_id" ] || continue
            cur_target=$(echo "$r_stream" | jq -r '.realitySettings.target // ""' 2>/dev/null || echo "")
            case "$cur_target" in
                *:443|443)
                    t_host=$(echo "$cur_target" | cut -d: -f1)
                    if [ "$t_host" = "443" ] || [ "$t_host" = "127.0.0.1" ] || [ "$t_host" = "localhost" ] || [ -z "$t_host" ] || [ "$t_host" = "$target_domain" ] || [ "$t_host" = "${XUI_HAPROXY_DOMAIN:-}" ] || [ "$t_host" = "${XUI_SELFSTEAL_DOMAIN:-}" ]; then
                        echo "[HAPROXY] Fixing Reality inbound id=${r_id} target '${cur_target}' -> 127.0.0.1:${selfsteal_port_safe} to prevent loop"
                        new_stream=$(echo "$r_stream" | jq -c --arg tgt "127.0.0.1:${selfsteal_port_safe}" '.realitySettings.target = $tgt' 2>/dev/null || echo "")
                        if [ -n "$new_stream" ]; then
                            esc_new_stream=$(sqlite_escape "$new_stream")
                            sqlite_db "UPDATE inbounds SET stream_settings = '${esc_new_stream}' WHERE id = ${r_id};"
                        fi
                    fi
                    ;;
            esac
        done
    fi

    # Fix Vision TCP TLS inbounds having invalid h2/h3 ALPN
    sqlite_db "
UPDATE inbounds
SET stream_settings = json_set(stream_settings, '$.tlsSettings.alpn', json('[\"http/1.1\"]'))
WHERE enable = 1
  AND json_valid(stream_settings)
  AND json_valid(settings)
  AND json_extract(stream_settings, '$.network') = 'tcp'
  AND json_extract(stream_settings, '$.security') = 'tls'
  AND EXISTS (
    SELECT 1 FROM json_each(settings, '$.clients')
    WHERE json_extract(value, '$.flow') = 'xtls-rprx-vision'
  )
  AND (
    stream_settings LIKE '%\"h2\"%' OR stream_settings LIKE '%\"h3\"%'
  );
" 2>/dev/null || true

    # Fix Reality inbounds with empty minClientVer causing Xray v26 client version rejection
    sqlite_db "
UPDATE inbounds
SET stream_settings = json_set(stream_settings, '$.realitySettings.minClientVer', '1.0.0')
WHERE enable = 1
  AND json_valid(stream_settings) = 1
  AND json_extract(stream_settings, '$.security') = 'reality'
  AND (
    json_extract(stream_settings, '$.realitySettings.minClientVer') IS NULL
    OR json_extract(stream_settings, '$.realitySettings.minClientVer') = ''
  );
" 2>/dev/null || true

    # 4. Generate HAProxy configuration from active inbounds
    rows=$(sqlite_db -separator '|' "
SELECT id, port, remark, protocol, stream_settings
FROM inbounds
WHERE enable = 1
  AND protocol NOT IN ('mtproto', 'mixed', 'hysteria')
  AND json_valid(stream_settings)
ORDER BY id ASC;
" 2>/dev/null || true)

    tmp_cfg=$(mktemp)
    tmp_parts=$(mktemp)

    if [ -n "$rows" ]; then
        printf "%s\n" "$rows" | while IFS='|' read -r id port remark proto stream; do
            [ -n "$id" ] || continue
            sec=$(echo "$stream" | jq -r '.security // ""' 2>/dev/null || echo "")
            snis=""

            if [ "$sec" = "reality" ]; then
                snis=$(echo "$stream" | jq -r '.realitySettings.serverNames[]?' 2>/dev/null | tr '\n' ' ')
            elif [ "$sec" = "tls" ]; then
                snis=$(echo "$stream" | jq -r '.tlsSettings.serverName // ""' 2>/dev/null)
            fi

            clean_snis=""
            for s in $snis; do
                case "$s" in
                    ""|localhost|127.0.0.1|*:[0-9]*) continue ;;
                    [0-9]*.[0-9]*.[0-9]*.[0-9]*) continue ;;
                    *) clean_snis="$clean_snis $s" ;;
                esac
            done

            # If TLS inbound has no domain SNI, fallback to target_domain
            if [ -z "$clean_snis" ] && [ "$sec" = "tls" ] && [ -n "$target_domain" ] && [ "$target_domain" != "127.0.0.1" ]; then
                clean_snis="$target_domain"
            fi

            if [ -n "$clean_snis" ]; then
                acl_name="is_in_${id}"
                bk_name="bk_in_${id}"
                for s in $clean_snis; do
                    echo "RULE:    acl ${acl_name} req_ssl_sni -i ${s}" >> "$tmp_parts"
                done
                echo "RULE:    use_backend ${bk_name} if ${acl_name}" >> "$tmp_parts"
                echo "BACKEND:${bk_name}|${port}" >> "$tmp_parts"
            fi
        done
    fi

        cat << 'EOF_HAPROXY_HEAD' > "$tmp_cfg"
global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend fe_http_in
    bind :80
    mode http
    timeout client 10s
    acl is_acme path_beg /.well-known/acme-challenge/
    http-request redirect scheme https code 301 unless is_acme
    use_backend bk_certbot if is_acme

frontend fe_tls_in
    bind :443
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content set-var(sess.sni) req_ssl_sni
    tcp-request content accept if { req_ssl_hello_type 1 }
    log-format "%ci:%cp [%t] %ft %b/%s %Tw/%Tc/%Tt %B %ts SNI:%[var(sess.sni)]"

    # SNI Routing for 3x-ui inbounds
EOF_HAPROXY_HEAD

        # SelfSteal Decoy Site integration
        selfsteal_enabled=0
        case "${XUI_SELFSTEAL_ENABLE:-true}" in
            true|TRUE|1|yes|YES|on|ON) selfsteal_enabled=1 ;;
        esac

        selfsteal_domain="${XUI_SELFSTEAL_DOMAIN:-${target_domain}}"
        selfsteal_port="${XUI_SELFSTEAL_PORT:-10444}"

        grep "^RULE:" "$tmp_parts" 2>/dev/null | sed 's/^RULE://' >> "$tmp_cfg" || true

        if [ "$selfsteal_enabled" -eq 1 ]; then
            # If target_domain is not explicitly routed to an inbound, route it to SelfSteal decoy
            if ! grep -q -- "-i ${selfsteal_domain}" "$tmp_cfg" 2>/dev/null; then
                cat << EOF_SS_RULE >> "$tmp_cfg"
    use_backend bk_selfsteal if { req_ssl_sni -i ${selfsteal_domain} }
EOF_SS_RULE
            fi

            cat << EOF_HAPROXY_DEF >> "$tmp_cfg"

    # Default fallback: SelfSteal Decoy Site (active probing / non-Reality / direct IP)
    default_backend bk_selfsteal
EOF_HAPROXY_DEF
        else
            def_bk=$(grep "^BACKEND:" "$tmp_parts" 2>/dev/null | head -n 1 | cut -d: -f2 | cut -d'|' -f1 || echo "")
            cat << EOF_HAPROXY_DEF >> "$tmp_cfg"

    # Default fallback: first available Reality/TLS inbound or certbot backend
    default_backend ${def_bk:-bk_certbot}
EOF_HAPROXY_DEF
        fi

        grep "^BACKEND:" "$tmp_parts" 2>/dev/null | while IFS='|' read -r raw_bk port; do
            bk=$(echo "$raw_bk" | cut -d: -f2)
            cat << EOF_BK >> "$tmp_cfg"

backend ${bk}
    mode tcp
    server srv1 127.0.0.1:${port}
EOF_BK
        done

        if [ "$selfsteal_enabled" -eq 1 ]; then
            cat << EOF_BK_SS >> "$tmp_cfg"

backend bk_selfsteal
    mode tcp
    server srv_decoy 127.0.0.1:${selfsteal_port} check
EOF_BK_SS
        fi

        cat << 'EOF_BK_CERTBOT' >> "$tmp_cfg"

backend bk_certbot
    mode http
    timeout server 10s
    server srv_certbot 127.0.0.1:8088
EOF_BK_CERTBOT


        # Pre-flight syntax validation before applying config
        chmod 644 "$tmp_cfg"
        cfg_valid=1
        val_output=""
        if command -v haproxy >/dev/null 2>&1; then
            if ! val_output=$(haproxy -c -f "$tmp_cfg" 2>&1); then
                cfg_valid=0
            fi
        elif command -v docker >/dev/null 2>&1; then
            if ! val_output=$(docker run --rm --user 0:0 -v "${tmp_cfg}:/tmp/test.cfg:ro" haproxy:alpine haproxy -c -f /tmp/test.cfg 2>&1); then
                cfg_valid=0
            fi
        fi

        if [ "$cfg_valid" -eq 0 ]; then
            echo "[HAPROXY-ERROR] Generated config failed syntax validation! Preserving previous configuration."
            [ -n "$val_output" ] && echo "[HAPROXY-ERROR] Details: $val_output"
        else
            mkdir -p "$(dirname "$haproxy_cfg_file")"
            if [ ! -f "$haproxy_cfg_file" ] || ! cmp -s "$tmp_cfg" "$haproxy_cfg_file"; then
                cat "$tmp_cfg" > "$haproxy_cfg_file"
                chmod 644 "$haproxy_cfg_file"
                echo "[HAPROXY] Generated and updated ${haproxy_cfg_file}"

                # Guarantee sync to /etc/haproxy/haproxy.cfg
                mkdir -p /etc/haproxy /run/haproxy 2>/dev/null || true
                cat "$tmp_cfg" > /etc/haproxy/haproxy.cfg 2>/dev/null || true
                chmod 644 /etc/haproxy/haproxy.cfg 2>/dev/null || true
            else
                echo "[HAPROXY] Configuration ${haproxy_cfg_file} is up-to-date"
            fi

            # Ensure HAProxy is running and up-to-date (native systemd or Docker container)
            if command -v haproxy >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
                mkdir -p /run/haproxy /etc/haproxy 2>/dev/null || true
                [ -f "$tmp_cfg" ] && cat "$tmp_cfg" > /etc/haproxy/haproxy.cfg 2>/dev/null || true
                if systemctl is-active --quiet haproxy 2>/dev/null; then
                    systemctl reload haproxy >/dev/null 2>&1 || systemctl restart haproxy >/dev/null 2>&1 || true
                    echo "[HAPROXY] Reloaded native systemd haproxy.service"
                else
                    systemctl enable haproxy >/dev/null 2>&1 || true
                    systemctl restart haproxy >/dev/null 2>&1 || true
                    echo "[HAPROXY] Started native systemd haproxy.service"
                fi
            elif command -v docker >/dev/null 2>&1; then
                if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^3x-haproxy$"; then
                    docker kill -s USR2 3x-haproxy >/dev/null 2>&1 || docker restart 3x-haproxy >/dev/null 2>&1 || true
                    echo "[HAPROXY] Reloaded 3x-haproxy docker container (seamless USR2)"
                elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^3x-haproxy$"; then
                    docker start 3x-haproxy >/dev/null 2>&1 || true
                    echo "[HAPROXY] Started existing 3x-haproxy docker container"
                else
                    docker run -d --name 3x-haproxy --restart always --net=host --user 0:0 \
                        -v "/etc/x-ui:/etc/x-ui:ro" haproxy:alpine haproxy -W -db -f /etc/x-ui/haproxy.cfg >/dev/null 2>&1 || true
                    echo "[HAPROXY] Created and started 3x-haproxy docker container"
                fi
            fi

            # Ensure SelfSteal Decoy service is active if enabled
            if [ "$selfsteal_enabled" -eq 1 ]; then
                decoy_script=""
                if [ -f "${SCRIPT_DIR}/decoy-setup.sh" ]; then
                    decoy_script="${SCRIPT_DIR}/decoy-setup.sh"
                elif [ -f "/usr/local/x-ui/decoy-setup.sh" ]; then
                    decoy_script="/usr/local/x-ui/decoy-setup.sh"
                elif [ -f "/app/decoy-setup.sh" ]; then
                    decoy_script="/app/decoy-setup.sh"
                fi
                if [ -n "$decoy_script" ]; then
                    echo "[HAPROXY-SELFSTEAL] Applying SelfSteal decoy service (${selfsteal_domain} -> 127.0.0.1:${selfsteal_port})..."
                    sh "$decoy_script" apply >/dev/null 2>&1 || true
                fi
            fi
        fi

        rm -f "$tmp_cfg" "$tmp_parts"

    # 5. Synchronize hosts table (nodes for subscriptions)
    echo "[HAPROXY-HOSTS] Synchronizing hosts table for domain: ${target_domain} (port 443)..."
    now_ms=$(date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))")

    # Ensure each active inbound has an entry in hosts pointing to target_domain:443
    if [ -n "$rows" ]; then
        order=1
        printf "%s\n" "$rows" | while IFS='|' read -r id port remark proto stream; do
            [ -n "$id" ] || continue
            sec=$(echo "$stream" | jq -r '.security // "same"' 2>/dev/null || echo "same")
            sni=""

            if [ "$sec" = "reality" ]; then
                sni=$(echo "$stream" | jq -r '.realitySettings.serverNames[0] // ""' 2>/dev/null || echo "")
            elif [ "$sec" = "tls" ]; then
                sni=$(echo "$stream" | jq -r '.tlsSettings.serverName // ""' 2>/dev/null || echo "")
            fi
            case "$sni" in
                ""|localhost|127.0.0.1|*:[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
                    sni="$target_domain"
                    ;;
            esac

            esc_remark=$(sqlite_escape "$remark")
            esc_sni=$(sqlite_escape "$sni")
            esc_sec=$(sqlite_escape "$sec")

            existing_host=$(sqlite_db -separator '|' "SELECT id, address FROM hosts WHERE inbound_id = ${id} LIMIT 1;" 2>/dev/null || echo "")
            if [ -n "$existing_host" ]; then
                host_id=$(echo "$existing_host" | cut -d'|' -f1)
                curr_addr=$(echo "$existing_host" | cut -d'|' -f2)

                case "$curr_addr" in
                    ""|localhost|127.0.0.1|0.0.0.0)
                        if [ "$sec" = "tls" ] && [ -n "$sni" ] && [ "$sni" != "$target_domain" ]; then
                            host_addr="$sni"
                        else
                            host_addr="$target_domain"
                        fi
                        ;;
                    *)
                        host_addr="$curr_addr"
                        ;;
                esac

                esc_host_addr=$(sqlite_escape "$host_addr")
                sqlite_db "
UPDATE hosts
SET address = '${esc_host_addr}',
    port = 443,
    sni = '${esc_sni}',
    security = '${esc_sec}',
    remark = '${esc_remark}',
    updated_at = ${now_ms}
WHERE id = ${host_id};
" 2>/dev/null || true
            else
                if [ "$sec" = "tls" ] && [ -n "$sni" ] && [ "$sni" != "$target_domain" ]; then
                    host_addr="$sni"
                else
                    host_addr="$target_domain"
                fi
                esc_host_addr=$(sqlite_escape "$host_addr")
                group_id=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 16 || echo "grp${id}${now_ms}")
                sqlite_db "
INSERT INTO hosts (
    group_id, inbound_id, sort_order, remark, server_description,
    is_disabled, is_hidden, tags, address, port,
    security, sni, host_header, path, alpn,
    fingerprint, override_sni_from_address, keep_sni_blank,
    pinned_peer_cert_sha256, verify_peer_cert_by_name, allow_insecure,
    ech_config_list, mux_params, sockopt_params, final_mask,
    vless_route, exclude_from_sub_types, mihomo_ip_version, mihomo_x25519,
    shuffle_host, node_guids, created_at, updated_at
) VALUES (
    '${group_id}', ${id}, ${order}, '${esc_remark}', '',
    0, 0, '', '${esc_host_addr}', 443,
    '${esc_sec}', '${esc_sni}', '', '', '[]',
    '', 0, 0,
    '[]', '', 0,
    '', '', '', '',
    '', '', '', 0,
    0, '', ${now_ms}, ${now_ms}
);
" 2>/dev/null || true
            fi
            order=$((order + 1))
        done
        echo "[HAPROXY-HOSTS] Hosts table synchronized for all active inbounds"
    fi

    # 6. Clean legacy externalProxy from inbounds.stream_settings
    rows_ext=$(sqlite_db -separator '|' "
SELECT id, stream_settings
FROM inbounds
WHERE stream_settings LIKE '%externalProxy%';
" 2>/dev/null || true)

    if [ -n "$rows_ext" ]; then
        printf "%s\n" "$rows_ext" | while IFS='|' read -r ext_id ext_stream; do
            [ -n "$ext_id" ] || continue
            new_stream=$(echo "$ext_stream" | jq 'del(.externalProxy)' 2>/dev/null || echo "")
            if [ -n "$new_stream" ] && [ "$new_stream" != "$ext_stream" ]; then
                esc_new_stream=$(sqlite_escape "$new_stream")
                sqlite_db "UPDATE inbounds SET stream_settings = '${esc_new_stream}' WHERE id = ${ext_id};" 2>/dev/null || true
                echo "[HAPROXY] Cleaned legacy externalProxy from inbound id=${ext_id}"
            fi
        done
    fi
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

    if [ -z "$FINAL_DOMAIN" ] && [ -n "$DB_DOMAIN" ]; then
        echo "[DOMAIN] Trying database domain: $DB_DOMAIN"

        if try_use_domain "$DB_DOMAIN" "$CERTBOT_EMAIL"; then
            FINAL_DOMAIN="$DB_DOMAIN"
            echo "[DOMAIN] Using database domain: $FINAL_DOMAIN"
        else
            echo "[DOMAIN] Database domain is not usable: $DB_DOMAIN"
        fi
    fi

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

        # Ensure certificate for XUI_HAPROXY_DOMAIN if set and different
        if [ -n "$XUI_HAPROXY_DOMAIN" ] && [ "$XUI_HAPROXY_DOMAIN" != "$FINAL_DOMAIN" ] && [ "$XUI_HAPROXY_DOMAIN" != "${SUB_DOMAIN:-}" ]; then
            if command -v is_domain_name >/dev/null 2>&1 && is_domain_name "$XUI_HAPROXY_DOMAIN"; then
                echo "[DOMAIN] Requesting certificate for HAProxy/SelfSteal domain: $XUI_HAPROXY_DOMAIN"
                certbot_issue_domain_cert "$XUI_HAPROXY_DOMAIN" "$CERTBOT_EMAIL" || true
            fi
        fi
    else
        echo "[DOMAIN] Certbot validation skipped or not matching. Preserving domain configuration."

        XUI_DOMAIN="${ENV_DOMAIN:-$DB_DOMAIN}"
        CERT_FILE=""
        KEY_FILE=""
        if [ -n "$XUI_DOMAIN" ]; then
            cert_cand="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
            key_cand="/etc/letsencrypt/live/${XUI_DOMAIN}/privkey.pem"
            if [ -f "$cert_cand" ] && [ -f "$key_cand" ]; then
                CERT_FILE="$cert_cand"
                KEY_FILE="$key_cand"
                echo "[DOMAIN] Found valid local certificates on disk: $CERT_FILE"
            fi
        fi
        SUB_DOMAIN="${XUI_SUB_DOMAIN:-$XUI_DOMAIN}"
        SUB_CERT_FILE="$CERT_FILE"
        SUB_KEY_FILE="$KEY_FILE"
    fi

    # Auto-issue SSL certificates for all candidate domains from DB and .env
    if command -v certbot_issue_domain_cert >/dev/null 2>&1; then
        db_reality_doms=$(sqlite_db "
SELECT json_extract(stream_settings, '$.realitySettings.serverNames[0]')
FROM inbounds
WHERE enable = 1
  AND json_valid(stream_settings)
  AND json_extract(stream_settings, '$.security') = 'reality';
" 2>/dev/null || true)

        db_tls_doms=$(sqlite_db "
SELECT json_extract(stream_settings, '$.tlsSettings.serverName')
FROM inbounds
WHERE enable = 1
  AND json_valid(stream_settings)
  AND json_extract(stream_settings, '$.security') = 'tls';
" 2>/dev/null || true)

        db_settings_doms=$(sqlite_db "
SELECT value FROM settings WHERE key IN ('webDomain', 'subDomain') AND value != '';
" 2>/dev/null || true)

        db_hosts_doms=$(sqlite_db "
SELECT address FROM hosts WHERE address != '' AND address NOT LIKE '127.%' AND address NOT LIKE '0.0.%';
" 2>/dev/null || true)

        all_candidate_domains=$(echo "$db_reality_doms $db_tls_doms $db_settings_doms $db_hosts_doms ${XUI_DOMAIN:-} ${XUI_SUB_DOMAIN:-} ${XUI_HAPROXY_DOMAIN:-} ${XUI_SELFSTEAL_DOMAIN:-}" | tr ' ' '\n' | sort -u)

        decoy_updated=0
        for d in $all_candidate_domains; do
            [ -n "$d" ] || continue
            case "$d" in
                ""|null|localhost|127.0.0.1|*:[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*) continue ;;
            esac
            if command -v is_domain_name >/dev/null 2>&1 && is_domain_name "$d"; then
                # Check if cert already exists and valid
                if [ -f "/etc/letsencrypt/live/${d}/fullchain.pem" ]; then
                    if command -v openssl >/dev/null 2>&1 && openssl x509 -in "/etc/letsencrypt/live/${d}/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1; then
                        continue
                    fi
                fi
                # Check if covered by any SAN in existing certs
                covered=0
                for c_file in /etc/letsencrypt/live/*/fullchain.pem; do
                    [ -f "$c_file" ] || continue
                    if openssl x509 -in "$c_file" -noout -text 2>/dev/null | grep -q "DNS:${d}"; then
                        if openssl x509 -in "$c_file" -noout -checkend 86400 >/dev/null 2>&1; then
                            covered=1
                            break
                        fi
                    fi
                done
                [ "$covered" -eq 1 ] && continue

                # Check if DNS resolves to self before calling certbot
                if command -v domain_points_to_this_server >/dev/null 2>&1 && domain_points_to_this_server "$d"; then
                    echo "[AUTO-SSL] Automatically requesting SSL certificate for domain: $d"
                    if certbot_issue_domain_cert "$d" "$CERTBOT_EMAIL"; then
                        decoy_updated=1
                        if [ "$d" = "$XUI_DOMAIN" ] || [ "$d" = "$(get_setting_value webDomain)" ]; then
                            set_always "webCertFile" "/etc/letsencrypt/live/${d}/fullchain.pem"
                            set_always "webKeyFile" "/etc/letsencrypt/live/${d}/privkey.pem"
                            CERT_FILE="/etc/letsencrypt/live/${d}/fullchain.pem"
                            KEY_FILE="/etc/letsencrypt/live/${d}/privkey.pem"
                        fi
                        if [ "$d" = "${XUI_SUB_DOMAIN:-}" ] || [ "$d" = "$(get_setting_value subDomain)" ]; then
                            set_always "subCertFile" "/etc/letsencrypt/live/${d}/fullchain.pem"
                            set_always "subKeyFile" "/etc/letsencrypt/live/${d}/privkey.pem"
                        fi
                    fi
                else
                    echo "[AUTO-SSL] Domain $d does not point to this server yet, skipping certbot"
                fi
            fi
        done

        if [ "$decoy_updated" -eq 1 ] && [ -x "${XUI_DIR}/decoy-setup.sh" ]; then
            "${XUI_DIR}/decoy-setup.sh" apply >/dev/null 2>&1 || true
        fi
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

if [ -z "$CERT_FILE" ] || [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    if [ "$XUI_ALLOW_HTTP" = "true" ]; then
        echo "[HTTP] HTTP mode enabled via XUI_ALLOW_HTTP=true"
        set_always "webCertFile" ""
        set_always "webKeyFile" ""
    else
        fallback_web_cert="/etc/x-ui/fallback-web.crt"
        fallback_web_key="/etc/x-ui/fallback-web.key"
        server_ip=$(get_public_ip 2>/dev/null || echo "")
        [ -z "$server_ip" ] && server_ip=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n 1)
        [ -z "$server_ip" ] && server_ip="127.0.0.1"

        san_alt="IP:${server_ip}"
        [ -n "$XUI_DOMAIN" ] && [ "$XUI_DOMAIN" != "localhost" ] && san_alt="${san_alt},DNS:${XUI_DOMAIN}"

        if [ ! -f "$fallback_web_cert" ] || [ ! -f "$fallback_web_key" ]; then
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$fallback_web_key" \
                -out "$fallback_web_cert" \
                -days 3650 \
                -subj "/CN=${server_ip}" \
                -addext "subjectAltName=${san_alt}" >/dev/null 2>&1 || \
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$fallback_web_key" \
                -out "$fallback_web_cert" \
                -days 3650 \
                -subj "/CN=${server_ip}" >/dev/null 2>&1 || true
            chmod 600 "$fallback_web_key" 2>/dev/null || true
            chmod 644 "$fallback_web_cert" 2>/dev/null || true
        fi

        if [ -f "$fallback_web_cert" ] && [ -f "$fallback_web_key" ]; then
            CERT_FILE="$fallback_web_cert"
            KEY_FILE="$fallback_web_key"
            set_always "webCertFile" "$CERT_FILE"
            set_always "webKeyFile" "$KEY_FILE"
            echo "[AUTO-SSL] Using self-signed fallback SSL certificate for panel (${server_ip})"
        fi
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

if [ -n "$fallback_web_cert" ] && [ "$CERT_FILE" = "$fallback_web_cert" ]; then
    effective_domain="$server_ip"
else
    effective_domain="${XUI_DOMAIN:-${ENV_DOMAIN:-$DB_DOMAIN}}"
fi
if [ -n "$effective_domain" ]; then
    set_always "webDomain" "$effective_domain"
else
    set_empty "webDomain"
fi

if [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ]; then
    set_always "webCertFile" "$CERT_FILE"
elif [ -n "$(get_setting_value webCertFile)" ] && [ -f "$(get_setting_value webCertFile)" ]; then
    :
else
    set_empty "webCertFile"
fi

if [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ]; then
    set_always "webKeyFile" "$KEY_FILE"
elif [ -n "$(get_setting_value webKeyFile)" ] && [ -f "$(get_setting_value webKeyFile)" ]; then
    :
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
elif [ -n "$effective_domain" ]; then
    set_always "subDomain" "$effective_domain"
else
    set_empty "subDomain"
fi

if [ -n "$SUB_CERT_FILE" ] && [ -f "$SUB_CERT_FILE" ]; then
    set_always "subCertFile" "$SUB_CERT_FILE"
elif [ -n "$(get_setting_value subCertFile)" ] && [ -f "$(get_setting_value subCertFile)" ]; then
    :
else
    set_empty "subCertFile"
fi

if [ -n "$SUB_KEY_FILE" ] && [ -f "$SUB_KEY_FILE" ]; then
    set_always "subKeyFile" "$SUB_KEY_FILE"
elif [ -n "$(get_setting_value subKeyFile)" ] && [ -f "$(get_setting_value subKeyFile)" ]; then
    :
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
effective_domain="${FINAL_DOMAIN:-${XUI_DOMAIN:-${ENV_DOMAIN:-$DB_DOMAIN}}}"
sync_inbound_tls_certs "$effective_domain" "$CERT_FILE" "$KEY_FILE"

# Sync HAProxy SNI routing on port 443 and hosts table for subscriptions
sync_haproxy_and_hosts "$effective_domain"

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

    for i in $(seq 1 4); do
        [ -f "$XRAY_CONFIG" ] && break
        sleep 0.25
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
