#!/bin/bash
# ============================================================================
# SelfSteal Decoy Site Manager for 3x-ui Fork
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
CONFIG_DIR="${XUI_CONFIG_DIR:-/etc/x-ui}"
ENV_FILE="${XUI_ENV_FILE:-${CONFIG_DIR}/.env}"
[ -f "$ENV_FILE" ] || ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi
. "${SCRIPT_DIR}/fork-policy.sh"

DECOY_ROOT="${SCRIPT_DIR}/decoy"
[ -d "$DECOY_ROOT" ] || DECOY_ROOT="${XUI_DIR}/decoy"

TEMPLATES_DIR="${DECOY_ROOT}/templates"
PUBLIC_DIR="${DECOY_ROOT}/public"
NGINX_CONF="/etc/x-ui/nginx-decoy.conf"
SERVICE_FILE="/etc/systemd/system/x-ui-decoy.service"

SELFSTEAL_PORT="${XUI_SELFSTEAL_PORT:-10444}"
SELFSTEAL_TEMPLATE="${XUI_SELFSTEAL_TEMPLATE:-shopflow}"
SELFSTEAL_MODE="${XUI_SELFSTEAL_MODE:-legacy}"
# A private directory prevents other local users from connecting to/spoofing the backend.
# The native x-ui/Xray service must run as root to use this endpoint.
REALITY_SOCKET="/run/x-ui-selfsteal/https.sock"

case "$SELFSTEAL_MODE" in
    legacy|reality) ;;
    *) echo "[SELFSTEAL-ERROR] XUI_SELFSTEAL_MODE должен быть legacy или reality" >&2; exit 1 ;;
esac

validate_reality_config() {
    local tool cert_pub key_pub
    case "$SELFSTEAL_TEMPLATE" in
        shopflow|tech|converter|blog|corporate) ;;
        *) echo "[SELFSTEAL-ERROR] Неизвестный шаблон SelfSteal" >&2; return 1 ;;
    esac
    for tool in nginx openssl curl; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "[SELFSTEAL-ERROR] Для режима reality требуется ${tool}" >&2
            return 1
        }
    done
    case "${XUI_HAPROXY_ENABLE:-false}" in
        true|TRUE|1|yes|YES|on|ON)
            echo "[SELFSTEAL-ERROR] Режим reality требует XUI_HAPROXY_ENABLE=false" >&2
            return 1 ;;
    esac
    case "${XUI_SELFSTEAL_ENABLE:-false}" in
        true|TRUE|1|yes|YES|on|ON) ;;
        *) echo "[SELFSTEAL-ERROR] Режим reality требует XUI_SELFSTEAL_ENABLE=true" >&2; return 1 ;;
    esac
    case "${XUI_SELFSTEAL_PUBLIC:-false}" in
        true|TRUE|1|yes|YES|on|ON)
            echo "[SELFSTEAL-ERROR] В режиме reality порт 443 принадлежит Xray, не Nginx; отключите XUI_SELFSTEAL_PUBLIC" >&2
            return 1 ;;
    esac
    REALITY_DOMAIN="${XUI_SELFSTEAL_DOMAIN:-}"
    # No implicit panel-domain fallback, wildcards, ports or nginx configuration syntax.
    if [ "${#REALITY_DOMAIN}" -gt 253 ] ||
       ! printf '%s\n' "$REALITY_DOMAIN" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
        echo "[SELFSTEAL-ERROR] Укажите собственный DNS-домен в XUI_SELFSTEAL_DOMAIN (без схемы, порта и wildcard)" >&2
        return 1
    fi
    case "$SELFSTEAL_PORT" in
        ''|*[!0-9]*) echo "[SELFSTEAL-ERROR] Некорректный XUI_SELFSTEAL_PORT" >&2; return 1 ;;
    esac
    if [ "${#SELFSTEAL_PORT}" -gt 5 ] || [ "$SELFSTEAL_PORT" -lt 1024 ] || [ "$SELFSTEAL_PORT" -gt 65535 ]; then
        echo "[SELFSTEAL-ERROR] Локальный XUI_SELFSTEAL_PORT должен быть в диапазоне 1024–65535" >&2
        return 1
    fi
    REALITY_CERT="${XUI_SELFSTEAL_CERT_FILE:-/etc/letsencrypt/live/${REALITY_DOMAIN}/fullchain.pem}"
    REALITY_KEY="${XUI_SELFSTEAL_KEY_FILE:-/etc/letsencrypt/live/${REALITY_DOMAIN}/privkey.pem}"
    local path
    for path in "$REALITY_CERT" "$REALITY_KEY" "$PUBLIC_DIR"; do
        if ! [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
            echo "[SELFSTEAL-ERROR] Требуется абсолютный путь без пробелов и специальных символов: ${path}" >&2
            return 1
        fi
    done
    [ -r "$REALITY_CERT" ] && [ -r "$REALITY_KEY" ] || {
        echo "[SELFSTEAL-ERROR] Нет читаемого сертификата/ключа для ${REALITY_DOMAIN}; самоподписанный fallback запрещён" >&2
        return 1
    }
    openssl x509 -in "$REALITY_CERT" -noout -checkend 86400 >/dev/null 2>&1 &&
    openssl x509 -in "$REALITY_CERT" -noout -checkhost "$REALITY_DOMAIN" >/dev/null 2>&1 &&
    openssl verify -purpose sslserver -verify_hostname "$REALITY_DOMAIN" \
        -untrusted "$REALITY_CERT" "$REALITY_CERT" >/dev/null 2>&1 || {
        echo "[SELFSTEAL-ERROR] Сертификат должен быть доверенным, действительным ещё сутки и покрывать ${REALITY_DOMAIN}" >&2
        return 1
    }
    # -passin prevents an encrypted key from hanging an unattended service startup.
    cert_pub=$(set -o pipefail; openssl x509 -in "$REALITY_CERT" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256) || return 1
    key_pub=$(set -o pipefail; openssl pkey -in "$REALITY_KEY" -passin pass: -pubout -outform DER | openssl dgst -sha256) || return 1
    if [ "$cert_pub" != "$key_pub" ]; then
        echo "[SELFSTEAL-ERROR] Закрытый ключ не соответствует сертификату" >&2
        return 1
    fi
    REALITY_PROXY_LOCATIONS=""
    if [ -n "${XUI_SELFSTEAL_PROXY_INBOUNDS:-}" ]; then
        if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${DECOY_ROOT}/reality_routes.py" ]; then
            echo "[SELFSTEAL-ERROR] Для выбранных HTTP-маршрутов нужны python3 и decoy/reality_routes.py" >&2
            return 1
        fi
        REALITY_PROXY_LOCATIONS=$(python3 "${DECOY_ROOT}/reality_routes.py" \
            --db "${XUI_DB_PATH:-${CONFIG_DIR}/x-ui.db}" \
            --ids "$XUI_SELFSTEAL_PROXY_INBOUNDS" --backend-port "$SELFSTEAL_PORT") || return 1
    fi
}

validate_reality_runtime() {
    if [ -f "/.dockerenv" ] || [ ! -d /run/systemd/system ] || ! command -v systemctl >/dev/null 2>&1; then
        echo "[SELFSTEAL-ERROR] Режим reality пока поддерживает только нативную установку с systemd; Docker/Python fallback не поддерживаются" >&2
        return 1
    fi
    [ "$(id -u)" -eq 0 ] || {
        echo "[SELFSTEAL-ERROR] Применение режима reality требует root" >&2
        return 1
    }
    if systemctl is-active --quiet haproxy.service 2>/dev/null; then
        echo "[SELFSTEAL-ERROR] HAProxy ещё запущен; сначала подготовьте отдельную миграцию, службы автоматически не останавливаются" >&2
        return 1
    fi
}

reality_plan() {
    validate_reality_config || return 1
    cat <<EOF
SelfSteal: REALITY -> локальный HTTPS Nginx (без изменения БД).
Поддерживается нативная установка с systemd, x-ui/Xray от root.
В НОВОМ тестовом входящем панели:
  Протокол: VLESS; транспорт: TCP/RAW; защита: REALITY
  Listen: 0.0.0.0; порт: свободный тестовый (443 только если свободен)
  Target: ${REALITY_SOCKET}
  xver / PROXY protocol: 1
  Server Names: ${REALITY_DOMAIN}
  Ключи Reality, UUID и непустой Short ID: создать средствами панели
В Host выбранного входящего:
  Адрес: ${REALITY_DOMAIN}; порт: фактический порт нового входящего
  Security: reality; SNI: ${REALITY_DOMAIN}; fingerprint: chrome
  Не переопределять SNI адресом; не отключать проверку сертификата
Сертификат: ${REALITY_CERT}
Nginx НЕ слушает публичные 80/443. Локальный HTTPS: 127.0.0.1:${SELFSTEAL_PORT}.
Старые входящие/Hosts автоматически НЕ мигрируют. DNS и свободный порт проверьте отдельно.
EOF
    if [ -n "$REALITY_PROXY_LOCATIONS" ]; then
        echo "Явно выбранные HTTP-маршруты (БД открыта read-only):"
        printf '%s\n' "$REALITY_PROXY_LOCATIONS" | grep '^        # inbound '
        echo "Для их клиентов: HTTPS-домен и порт REALITY-фронтенда; сохранить транспорт и path/serviceName."
        echo "Host HTTP-транспорта: security=tls (не reality), SNI=${REALITY_DOMAIN}; для gRPC нужен HTTP/2."
        echo "Проверка плана не подтверждает доступность backend или соединение настоящего клиента."
    else
        echo "HTTP-маршруты не выбраны; WS/XHTTP/gRPC автоматически не переносятся."
    fi
}

generate_reality_nginx_conf() {
    # Caller validates all interpolated values before writing any file.
    local output="$1" h2_listen="http2" h2_line="" version
    version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ "$(printf '%s\n' "$version" | cut -d. -f1)" -gt 1 ] ||
       { [ "$(printf '%s\n' "$version" | cut -d. -f1)" -eq 1 ] && [ "$(printf '%s\n' "$version" | cut -d. -f2)" -ge 25 ]; }; then
        h2_listen=""
        h2_line="http2 on;"
    fi
    cat > "$output" <<EOF
user root;
worker_processes 1;
pid /run/x-ui-decoy.pid;
error_log /var/log/x-ui-decoy.log warn;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    server_tokens off;
    client_max_body_size 0;
    map \$http_upgrade \$selfsteal_connection_upgrade {
        default upgrade;
        '' close;
    }
    map \$proxy_protocol_addr \$selfsteal_client_ip {
        default \$proxy_protocol_addr;
        '' \$remote_addr;
    }
    server {
        listen unix:${REALITY_SOCKET} ssl proxy_protocol ${h2_listen};
        listen 127.0.0.1:${SELFSTEAL_PORT} ssl ${h2_listen};
        ${h2_line}
        server_name ${REALITY_DOMAIN};
        ssl_certificate ${REALITY_CERT};
        ssl_certificate_key ${REALITY_KEY};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_tickets off;
        root ${PUBLIC_DIR};
        index index.html;
${REALITY_PROXY_LOCATIONS:-}
        location / { try_files \$uri \$uri/ =404; }
        location ~ /\. { deny all; }
    }
}
EOF
}

setup_reality_service() {
    validate_reality_config || return 1
    validate_reality_runtime || return 1
    local current_installed="" tmp_cfg backup_dir was_active=0
    [ -f "${PUBLIC_DIR}/.current_template" ] && current_installed=$(cat "${PUBLIC_DIR}/.current_template")
    if [ ! -f "${PUBLIC_DIR}/index.html" ] || [ "$current_installed" != "$SELFSTEAL_TEMPLATE" ]; then
        switch_template "$SELFSTEAL_TEMPLATE" || return 1
    fi
    install -d -m 0700 /run/x-ui-selfsteal || return 1
    tmp_cfg=$(mktemp) || return 1
    generate_reality_nginx_conf "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
    if ! nginx -t -c "$tmp_cfg"; then
        rm -f "$tmp_cfg"
        echo "[SELFSTEAL-ERROR] Проверка Nginx не прошла; прежняя конфигурация сохранена" >&2
        return 1
    fi
    backup_dir=$(mktemp -d) || { rm -f "$tmp_cfg"; return 1; }
    if [ -f "$NGINX_CONF" ]; then cp -p "$NGINX_CONF" "$backup_dir/nginx.conf" || return 1; fi
    if [ -f "$SERVICE_FILE" ]; then cp -p "$SERVICE_FILE" "$backup_dir/service" || return 1; fi
    systemctl is-active --quiet x-ui-decoy.service && was_active=1
    mkdir -p "$(dirname "$NGINX_CONF")" || return 1
    if [ -f "$NGINX_CONF" ] && [ ! -f "${NGINX_CONF}.pre-reality" ]; then
        cp -p "$NGINX_CONF" "${NGINX_CONF}.pre-reality"
    fi
    install -m 0600 "$tmp_cfg" "$NGINX_CONF" || return 1
    rm -f "$tmp_cfg"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=3x-ui SelfSteal local HTTPS backend for REALITY
After=network.target

[Service]
Type=forking
RuntimeDirectory=x-ui-selfsteal
RuntimeDirectoryMode=0700
PIDFile=/run/x-ui-decoy.pid
ExecStartPre=$(command -v nginx) -t -c ${NGINX_CONF}
ExecStart=$(command -v nginx) -c ${NGINX_CONF}
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    if ! systemctl daemon-reload || ! systemctl restart x-ui-decoy.service ||
       ! curl --fail --silent --show-error --max-time 10 --noproxy '*' \
           --haproxy-protocol --unix-socket "$REALITY_SOCKET" \
           "https://${REALITY_DOMAIN}/" -o /dev/null; then
        echo "[SELFSTEAL-ERROR] Запуск/HTTPS через Unix-сокет не прошёл проверку; восстанавливаю прежнюю службу" >&2
        systemctl stop x-ui-decoy.service >/dev/null 2>&1 || true
        if [ -f "$backup_dir/nginx.conf" ]; then cp -p "$backup_dir/nginx.conf" "$NGINX_CONF"; else rm -f "$NGINX_CONF"; fi
        if [ -f "$backup_dir/service" ]; then cp -p "$backup_dir/service" "$SERVICE_FILE"; else rm -f "$SERVICE_FILE"; fi
        systemctl daemon-reload || true
        if [ "$was_active" -eq 1 ]; then systemctl start x-ui-decoy.service || true; fi
        rm -rf "$backup_dir"
        return 1
    fi
    rm -rf "$backup_dir"
    systemctl enable x-ui-decoy.service >/dev/null || return 1
    echo "[SELFSTEAL] Nginx готов: ${REALITY_SOCKET} (PROXY protocol v1). БД и входящие не изменены."
}

list_templates() {
    echo "Доступные шаблоны сайта-заглушки (SelfSteal):"
    for dir in "${TEMPLATES_DIR}"/*; do
        if [ -d "$dir" ] && [ -f "$dir/index.html" ]; then
            name=$(basename "$dir")
            if [ "$name" = "$SELFSTEAL_TEMPLATE" ]; then
                echo "  * $name (активный в .env)"
            else
                echo "  - $name"
            fi
        fi
    done
}

switch_template() {
    target=$1
    if [ -z "$target" ]; then
        echo "Ошибка: укажите имя шаблона (shopflow, tech, converter, blog, corporate)"
        list_templates
        return 1
    fi

    if [ ! -f "${TEMPLATES_DIR}/${target}/index.html" ]; then
        echo "Ошибка: шаблон '${target}' не найден в ${TEMPLATES_DIR}"
        list_templates
        return 1
    fi

    mkdir -p "$PUBLIC_DIR"
    find "$PUBLIC_DIR" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
    cp -rf "${TEMPLATES_DIR}/${target}/"* "$PUBLIC_DIR/"
    echo "$target" > "${PUBLIC_DIR}/.current_template"
    echo "✓ Шаблон '${target}' успешно установлен в ${PUBLIC_DIR}"

    if [ "$DECOY_ROOT" != "${XUI_DIR}/decoy" ] && [ -d "${XUI_DIR}" ] && [ -w "${XUI_DIR}" ]; then
        mkdir -p "${XUI_DIR}/decoy/public" 2>/dev/null || true
        find "${XUI_DIR}/decoy/public" -mindepth 1 -delete 2>/dev/null || true
        cp -rf "${PUBLIC_DIR}/"* "${XUI_DIR}/decoy/public/" 2>/dev/null || true
        echo "$target" > "${XUI_DIR}/decoy/public/.current_template" 2>/dev/null || true
    fi

    real_env="$(readlink -f "$ENV_FILE" 2>/dev/null || echo "$ENV_FILE")"
    if [ -f "$real_env" ] && [ -w "$real_env" ]; then
        if grep -q "^XUI_SELFSTEAL_TEMPLATE=" "$real_env"; then
            sed -i "s/^XUI_SELFSTEAL_TEMPLATE=.*/XUI_SELFSTEAL_TEMPLATE=${target}/" "$real_env"
        else
            echo "XUI_SELFSTEAL_TEMPLATE=${target}" >> "$real_env"
        fi
        echo "✓ Переменная XUI_SELFSTEAL_TEMPLATE=${target} записана в ${real_env}"
    elif [ -f "${SCRIPT_DIR}/.env" ] && [ -w "${SCRIPT_DIR}/.env" ]; then
        if grep -q "^XUI_SELFSTEAL_TEMPLATE=" "${SCRIPT_DIR}/.env"; then
            sed -i "s/^XUI_SELFSTEAL_TEMPLATE=.*/XUI_SELFSTEAL_TEMPLATE=${target}/" "${SCRIPT_DIR}/.env"
        else
            echo "XUI_SELFSTEAL_TEMPLATE=${target}" >> "${SCRIPT_DIR}/.env"
        fi
        echo "✓ Переменная XUI_SELFSTEAL_TEMPLATE=${target} записана в ${SCRIPT_DIR}/.env"
    fi
}

get_decoy_domain() {
    d="${XUI_SELFSTEAL_DOMAIN:-${XUI_HAPROXY_DOMAIN:-${XUI_DOMAIN:-${XUI_SUB_DOMAIN:-}}}}"
    if [ -z "$d" ] || [ "$d" = "127.0.0.1" ] || [ "$d" = "localhost" ]; then
        if [ -f "/etc/x-ui/x-ui.db" ]; then
            if command -v sqlite3 >/dev/null 2>&1; then
                d=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='subDomain' AND value != '';" 2>/dev/null || true)
                [ -z "$d" ] && d=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webDomain' AND value != '';" 2>/dev/null || true)
            elif command -v python3 >/dev/null 2>&1; then
                d=$(python3 -c "import sqlite3; c=sqlite3.connect('/etc/x-ui/x-ui.db').cursor(); r=c.execute(\"SELECT value FROM settings WHERE key='subDomain' AND value != ''\").fetchone(); print(r[0] if r else '')" 2>/dev/null || true)
                [ -z "$d" ] && d=$(python3 -c "import sqlite3; c=sqlite3.connect('/etc/x-ui/x-ui.db').cursor(); r=c.execute(\"SELECT value FROM settings WHERE key='webDomain' AND value != ''\").fetchone(); print(r[0] if r else '')" 2>/dev/null || true)
            fi
        fi
    fi
    # If still empty, check letsencrypt certs: look for base domain
    if [ -z "$d" ] && [ -d "/etc/letsencrypt/live" ]; then
        for ldir in /etc/letsencrypt/live/*; do
            [ -d "$ldir" ] || continue
            bname=$(basename "$ldir")
            case "$bname" in
                ""|README|*fallback*) continue ;;
                edge.*|portal.*|ingest.*|sub.*) continue ;;
                *)
                    if [ -f "${ldir}/fullchain.pem" ]; then
                        d="$bname"
                        break
                    fi
                    ;;
            esac
        done
        if [ -z "$d" ]; then
            for ldir in /etc/letsencrypt/live/*; do
                [ -d "$ldir" ] || continue
                bname=$(basename "$ldir")
                case "$bname" in
                    ""|README|*fallback*) continue ;;
                    *)
                        if [ -f "${ldir}/fullchain.pem" ]; then
                            d="$bname"
                            break
                        fi
                        ;;
                esac
            done
        fi
    fi
    echo "$d"
}

resolve_ssl_certs() {
    target_domain=$(get_decoy_domain)
    cert=""
    key=""

    if [ -n "$target_domain" ] && [ "$target_domain" != "127.0.0.1" ] && [ "$target_domain" != "localhost" ]; then
        cand_cert="/etc/letsencrypt/live/${target_domain}/fullchain.pem"
        cand_key="/etc/letsencrypt/live/${target_domain}/privkey.pem"
        if [ -f "$cand_cert" ] && [ -f "$cand_key" ]; then
            cert="$cand_cert"
            key="$cand_key"
        fi
    fi

    # Check if target_domain is covered in SAN of any existing Let's Encrypt certificate
    if [ -z "$cert" ] && [ -n "$target_domain" ] && command -v openssl >/dev/null 2>&1; then
        for ldir in /etc/letsencrypt/live/*; do
            [ -d "$ldir" ] || continue
            cand_c="${ldir}/fullchain.pem"
            cand_k="${ldir}/privkey.pem"
            if [ -f "$cand_c" ] && [ -f "$cand_k" ]; then
                if openssl x509 -in "$cand_c" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${target_domain}"; then
                    cert="$cand_c"
                    key="$cand_k"
                    break
                fi
            fi
        done
    fi

    if [ -z "$cert" ] && [ -n "$target_domain" ] && [ "$target_domain" != "127.0.0.1" ] && [ "$target_domain" != "localhost" ] &&
       fork_allow XUI_AUTO_CERTS "Выпуск сертификата сайта-заглушки ${target_domain}"; then
        cand_cert="/etc/letsencrypt/live/${target_domain}/fullchain.pem"
        cand_key="/etc/letsencrypt/live/${target_domain}/privkey.pem"
        if command -v certbot_issue_domain_cert >/dev/null 2>&1 || [ -f "${SCRIPT_DIR}/certbot-domain.sh" ] || [ -f "${XUI_DIR}/certbot-domain.sh" ]; then
            if ! command -v certbot_issue_domain_cert >/dev/null 2>&1; then
                # shellcheck disable=SC1090
                . "${SCRIPT_DIR}/certbot-domain.sh" 2>/dev/null || . "${XUI_DIR}/certbot-domain.sh" 2>/dev/null || true
            fi
            echo "[DECOY] Запрос SSL сертификата через certbot для ${target_domain}..." >&2
            certbot_issue_domain_cert "$target_domain" "${XUI_ADMIN_EMAIL:-}" >&2 || true
            if [ -f "$cand_cert" ] && [ -f "$cand_key" ]; then
                cert="$cand_cert"
                key="$cand_key"
            fi
        elif command -v certbot >/dev/null 2>&1; then
            echo "[DECOY] Запрос SSL сертификата через certbot для ${target_domain}..." >&2
            port_opt=""
            if ss -tlpn 2>/dev/null | grep -q ':80 ' || netstat -tlpn 2>/dev/null | grep -q ':80 '; then
                port_opt="--http-01-port 8088"
            fi
            certbot certonly --standalone -d "$target_domain" --non-interactive --agree-tos --register-unsafely-without-email ${port_opt} >&2 || true
            if [ -f "$cand_cert" ] && [ -f "$cand_key" ]; then
                cert="$cand_cert"
                key="$cand_key"
            fi
        fi
    fi

    if [ -z "$cert" ] && ! fork_allow XUI_SELFSTEAL_ALLOW_FALLBACK_CERT "Подмена сертификата заглушки другим/самоподписанным"; then
        echo "[DECOY-ERROR] Нет сертификата выбранного домена; чужой или самоподписанный не подставляется" >&2
        return 1
    fi

    if [ -z "$cert" ]; then
        # Only an explicit fallback permission may select a different identity.
        for ldir in /etc/letsencrypt/live/*; do
            [ -d "$ldir" ] || continue
            case "$(basename "$ldir")" in
                ""|README|*fallback*) continue ;;
            esac
            if [ -f "${ldir}/fullchain.pem" ] && [ -f "${ldir}/privkey.pem" ]; then
                cert="${ldir}/fullchain.pem"
                key="${ldir}/privkey.pem"
                [ -z "$target_domain" ] && target_domain="$(basename "$ldir")"
                break
            fi
        done
    fi

    if [ -z "$cert" ] && [ -f "/etc/x-ui/x-ui.db" ]; then
        db_cert=""
        db_key=""
        if command -v sqlite3 >/dev/null 2>&1; then
            db_cert=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || echo "")
            db_key=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webKeyFile';" 2>/dev/null || echo "")
        elif command -v python3 >/dev/null 2>&1; then
            db_cert=$(python3 -c "import sqlite3; c=sqlite3.connect('/etc/x-ui/x-ui.db').cursor(); r=c.execute(\"SELECT value FROM settings WHERE key='webCertFile'\").fetchone(); print(r[0] if r else '')" 2>/dev/null || true)
            db_key=$(python3 -c "import sqlite3; c=sqlite3.connect('/etc/x-ui/x-ui.db').cursor(); r=c.execute(\"SELECT value FROM settings WHERE key='webKeyFile'\").fetchone(); print(r[0] if r else '')" 2>/dev/null || true)
        fi
        if [ -n "$db_cert" ] && [ -n "$db_key" ] && [ -f "$db_cert" ] && [ -f "$db_key" ]; then
            cert="$db_cert"
            key="$db_key"
        fi
    fi

    if [ -z "$cert" ]; then
        # Fallback self-signed certificate
        fallback_cert="/etc/x-ui/fallback-inbound.crt"
        fallback_key="/etc/x-ui/fallback-inbound.key"
        if [ ! -f "$fallback_cert" ] || [ ! -f "$fallback_key" ]; then
            mkdir -p "/etc/x-ui"
            if command -v openssl >/dev/null 2>&1; then
                openssl req -x509 -newkey rsa:2048 -nodes \
                    -keyout "$fallback_key" -out "$fallback_cert" \
                    -days 3650 -subj "/CN=decoy-fallback" >/dev/null 2>&1 || true
            fi
        fi
        cert="$fallback_cert"
        key="$fallback_key"
    fi

    printf "%s|%s|%s\n" "$cert" "$key" "$target_domain"
}

generate_nginx_conf() {
    ssl_info=$(resolve_ssl_certs) || return 1
    cert=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f1 | tr -d '\r\n')
    key=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f2 | tr -d '\r\n')
    target_domain=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f3 | tr -d '\r\n')

    # Double check cert validity
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        fork_allow XUI_SELFSTEAL_ALLOW_FALLBACK_CERT "Создание самоподписанного сертификата заглушки" || return 1
        mkdir -p "/etc/x-ui"
        cert="/etc/x-ui/fallback-inbound.crt"
        key="/etc/x-ui/fallback-inbound.key"
        if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$key" -out "$cert" \
                -days 3650 -subj "/CN=decoy-fallback" >/dev/null 2>&1 || true
        fi
    fi

    mime_include=""
    if [ -f "/etc/nginx/mime.types" ]; then
        mime_include="include /etc/nginx/mime.types;"
    elif [ -f "/etc/mime.types" ]; then
        mime_include="include /etc/mime.types;"
    fi

    # Detect if Nginx should bind to public port 443
    is_public_443=0
    case "${XUI_SELFSTEAL_PUBLIC:-false}" in
        true|TRUE|1|yes|YES) is_public_443=1 ;;
    esac
    if [ "$SELFSTEAL_PORT" = "443" ] && [ "$is_public_443" -eq 0 ]; then
        echo "[DECOY-ERROR] Публичный порт 443 требует явного XUI_SELFSTEAL_PUBLIC=true" >&2
        return 1
    fi

    # Detect nginx version for http2 syntax compatibility
    bin_to_check="${nginx_bin:-$(command -v nginx || true)}"
    nmajor=1
    nminor=24
    if [ -n "$bin_to_check" ] && [ -x "$bin_to_check" ]; then
        nver=$("$bin_to_check" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        nmajor=$(echo "$nver" | cut -d. -f1)
        nminor=$(echo "$nver" | cut -d. -f2)
    fi

    use_new_h2=0
    if [ "${nmajor:-0}" -gt 1 ] || [ "${nmajor:-0}" -eq 1 -a "${nminor:-0}" -gt 25 ]; then
        use_new_h2=1
    fi

    if [ "$is_public_443" -eq 1 ] || [ "$SELFSTEAL_PORT" = "443" ]; then
        if [ "$use_new_h2" -eq 1 ]; then
            nginx_http2_listen="listen 443 ssl;
        listen 127.0.0.1:10444 ssl;"
            nginx_http2_line="http2 on;"
        else
            nginx_http2_listen="listen 443 ssl http2;
        listen 127.0.0.1:10444 ssl http2;"
            nginx_http2_line=""
        fi
    else
        if [ "$use_new_h2" -eq 1 ]; then
            nginx_http2_listen="listen 127.0.0.1:${SELFSTEAL_PORT} ssl;"
            nginx_http2_line="http2 on;"
        else
            nginx_http2_listen="listen 127.0.0.1:${SELFSTEAL_PORT} ssl http2;"
            nginx_http2_line=""
        fi
    fi

    # Dynamically extract all web-proxied inbounds (ws, upgrade, xhttp, splithttp, grpc, tcp-http) with security=none
    dynamic_proxy_locations=""
    if [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        db_dyn_rows=$(sqlite3 /etc/x-ui/x-ui.db "
SELECT id, port, stream_settings FROM inbounds
WHERE enable = 1
  AND json_valid(stream_settings)
  AND json_extract(stream_settings, '$.network') IN ('ws', 'upgrade', 'httpupgrade', 'xhttp', 'splithttp', 'grpc', 'tcp')
  AND (json_extract(stream_settings, '$.security') = 'none' OR json_extract(stream_settings, '$.security') IS NULL OR json_extract(stream_settings, '$.security') = '');
" 2>/dev/null || true)
        if [ -n "$db_dyn_rows" ]; then
            seen_loc_paths=""
            tmp_dyn=$(mktemp)
            printf "%s\n" "$db_dyn_rows" > "$tmp_dyn"
            while IFS='|' read -r d_id d_port d_stream; do
                [ -n "$d_id" ] || continue
                d_net=$(echo "$d_stream" | jq -r '.network // "tcp"' 2>/dev/null || echo "tcp")
                d_path=""
                case "$d_net" in
                    ws)
                        d_path=$(echo "$d_stream" | jq -r '.wsSettings.path // ""' 2>/dev/null || echo "")
                        ;;
                    upgrade|httpupgrade)
                        d_path=$(echo "$d_stream" | jq -r '.httpupgradeSettings.path // .upgradeSettings.path // ""' 2>/dev/null || echo "")
                        ;;
                    xhttp)
                        d_path=$(echo "$d_stream" | jq -r '.xhttpSettings.path // ""' 2>/dev/null || echo "")
                        ;;
                    splithttp)
                        d_path=$(echo "$d_stream" | jq -r '.splithttpSettings.path // ""' 2>/dev/null || echo "")
                        ;;
                    grpc)
                        d_path=$(echo "$d_stream" | jq -r '.grpcSettings.serviceName // ""' 2>/dev/null || echo "")
                        ;;
                    tcp)
                        tcp_hdr=$(echo "$d_stream" | jq -r '.tcpSettings.header.type // ""' 2>/dev/null || echo "")
                        if [ "$tcp_hdr" = "http" ]; then
                            d_path=$(echo "$d_stream" | jq -r '.tcpSettings.header.request.path[0]? // ""' 2>/dev/null || echo "")
                        fi
                        ;;
                esac
                clean_path=$(echo "$d_path" | cut -d'?' -f1 | tr -d ' ')
                case "$clean_path" in
                    ""|"/"|"\\") continue ;;
                    /*) ;;
                    *) clean_path="/${clean_path}" ;;
                esac
                if echo "$seen_loc_paths" | grep -q -x "$clean_path" 2>/dev/null; then
                    continue
                fi
                seen_loc_paths="${seen_loc_paths}
${clean_path}"

                if [ "$d_net" = "grpc" ]; then
                    dynamic_proxy_locations="${dynamic_proxy_locations}
        location ${clean_path} {
            grpc_pass grpc://127.0.0.1:${d_port};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_set_header Host \$host;
            grpc_set_header X-Real-IP \$remote_addr;
        }"
                else
                    dynamic_proxy_locations="${dynamic_proxy_locations}
        location ${clean_path} {
            proxy_pass http://127.0.0.1:${d_port};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_buffering off;
            proxy_request_buffering off;
            client_max_body_size 0;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }"
                fi
            done < "$tmp_dyn"
            rm -f "$tmp_dyn"
        fi
    fi

    default_sans=""
    if [ -f "$cert" ] && command -v openssl >/dev/null 2>&1; then
        default_sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | sed 's/DNS://' | tr '\n' ' ' || echo "")
    fi
    default_server_names="_ ${default_sans:-$target_domain}"
    seen_domains="${default_sans:-$target_domain}"

    extra_servers=""
    for live_dir in /etc/letsencrypt/live/*; do
        [ -d "$live_dir" ] || continue
        c_dom=$(basename "$live_dir")
        case "$c_dom" in
            ""|README|*fallback*) continue ;;
        esac
        c_cert="${live_dir}/fullchain.pem"
        c_key="${live_dir}/privkey.pem"
        if [ -f "$c_cert" ] && [ -f "$c_key" ] && [ "$c_cert" != "$cert" ]; then
            web_proxy_loc="${dynamic_proxy_locations}

        location / {
            try_files \$uri \$uri/ \$uri.html /index.html =404;
        }"
            # Проверяем, настроен ли Telegram WEB Proxy на этот домен
            if [ -f "/etc/tproxy-server/credentials.env" ]; then
                tproxy_dom=$(grep -E '^WEB_PROXY_DOMAIN=' /etc/tproxy-server/credentials.env 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ')
                if [ -n "$tproxy_dom" ] && [ "$tproxy_dom" = "$c_dom" ]; then
                    web_proxy_loc="        location / {
            proxy_pass http://127.0.0.1:8080;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }"
                fi
            fi

            cert_sans=""
            if command -v openssl >/dev/null 2>&1; then
                cert_sans=$(openssl x509 -in "$c_cert" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | sed 's/DNS://' | tr '\n' ' ' || echo "")
            fi
            unique_snis=""
            for d in ${cert_sans:-$c_dom}; do
                if ! echo " $seen_domains " | grep -q " $d "; then
                    seen_domains="$seen_domains $d"
                    unique_snis="$unique_snis $d"
                fi
            done
            [ -n "$unique_snis" ] || continue
            server_names="$unique_snis"

            extra_servers="${extra_servers}

    server {
        ${nginx_http2_listen}
        ${nginx_http2_line}
        server_name ${server_names};

        error_page 497 =301 https://\$host\$request_uri;

        ssl_certificate ${c_cert};
        ssl_certificate_key ${c_key};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        root ${PUBLIC_DIR};
        index index.html;

${web_proxy_loc}

        location = /favicon.ico {
            log_not_found off;
            access_log off;
        }

        location = /robots.txt {
            log_not_found off;
            access_log off;
        }

        location /api/health {
            default_type application/json;
            return 200 '{\"status\":\"healthy\",\"service\":\"shopflow-edge\",\"version\":\"4.8.2\"}';
        }

        location ~ /\. {
            deny all;
        }
    }"
        fi
    done

    nginx_http_server=""
    if [ "$is_public_443" -eq 1 ]; then
        nginx_http_server='    server {
        listen 80;
        server_name _;
        location /.well-known/acme-challenge/ {
            root /var/www/html;
            try_files $uri =404;
        }
        location / {
            return 301 https://$host$request_uri;
        }
    }'
    fi
    mkdir -p "$(dirname "$NGINX_CONF")"
    cat > "$NGINX_CONF" <<EOF
user root;
worker_processes 1;
pid /run/x-ui-decoy.pid;
error_log /var/log/x-ui-decoy.log warn;

events {
    worker_connections 1024;
}

http {
    ${mime_include}
    default_type application/octet-stream;
    access_log off;
    sendfile on;
    keepalive_timeout 65;
    server_tokens off;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
    client_max_body_size 0;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

${nginx_http_server}

    server {
        ${nginx_http2_listen}
        ${nginx_http2_line}
        server_name ${default_server_names};

        error_page 497 =301 https://\$host\$request_uri;

        ssl_certificate ${cert};
        ssl_certificate_key ${key};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        root ${PUBLIC_DIR};
        index index.html;

        # Dynamic Inbound proxy locations (WebSocket / xHTTP / SplitHTTP)
${dynamic_proxy_locations}

        location / {
            try_files \$uri \$uri/ \$uri.html /index.html =404;
        }

        location = /favicon.ico {
            log_not_found off;
            access_log off;
        }

        location = /robots.txt {
            log_not_found off;
            access_log off;
        }

        location /api/health {
            default_type application/json;
            return 200 '{"status":"healthy","service":"shopflow-edge","version":"4.8.2"}';
        }

        location ~ /\. {
            deny all;
        }
    }
${extra_servers}
}
EOF
}

setup_and_start_service() {
    if [ "$SELFSTEAL_MODE" = "reality" ]; then
        setup_reality_service
        return $?
    fi
    if [ -d "${SCRIPT_DIR}/decoy" ] && [ "${SCRIPT_DIR}/decoy" != "${XUI_DIR}/decoy" ] && [ -d "$XUI_DIR" ]; then
        mkdir -p "${XUI_DIR}/decoy"
        cp -rf "${SCRIPT_DIR}/decoy/"* "${XUI_DIR}/decoy/" 2>/dev/null || true
        chmod -R 755 "${XUI_DIR}/decoy" 2>/dev/null || true
        PUBLIC_DIR="${XUI_DIR}/decoy/public"
        TEMPLATES_DIR="${XUI_DIR}/decoy/templates"
    fi

    current_installed=""
    [ -f "${PUBLIC_DIR}/.current_template" ] && current_installed="$(cat "${PUBLIC_DIR}/.current_template" 2>/dev/null)"
    if [ ! -f "${PUBLIC_DIR}/index.html" ] || [ "$current_installed" != "$SELFSTEAL_TEMPLATE" ]; then
        switch_template "$SELFSTEAL_TEMPLATE"
    fi
    chmod -R 755 "$PUBLIC_DIR" 2>/dev/null || true

    if [ -f "/.dockerenv" ] || ( [ -z "$(command -v systemctl 2>/dev/null)" ] && command -v docker >/dev/null 2>&1 ); then
        echo "[DECOY] Configuring Docker container 3x-decoy..."
        generate_nginx_conf || return 1
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^3x-decoy$"; then
            docker restart 3x-decoy >/dev/null 2>&1 || true
        elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^3x-decoy$"; then
            docker start 3x-decoy >/dev/null 2>&1 || true
        else
            docker run -d --name 3x-decoy --restart always --net=host \
                -v "${PUBLIC_DIR}:/usr/share/nginx/html:ro" \
                -v "/etc/letsencrypt:/etc/letsencrypt:ro" \
                -v "/etc/x-ui:/etc/x-ui:ro" \
                -v "${NGINX_CONF}:/etc/nginx/nginx.conf:ro" \
                nginx:alpine >/dev/null 2>&1 || true
        fi
        echo "[DECOY] Docker container 3x-decoy ready"
        return 0
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        echo "[DECOY] Nginx не найден, попытка автоматической установки..."
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q nginx >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q nginx >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache nginx >/dev/null 2>&1 || true
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm nginx >/dev/null 2>&1 || true
        fi
    fi

    nginx_bin=$(command -v nginx || true)
    python_bin=$(command -v python3 || echo "/usr/bin/python3")

    if [ -n "$nginx_bin" ] && [ -x "$nginx_bin" ]; then
        generate_nginx_conf || return 1
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=3x-ui SelfSteal Decoy Web Server (Nginx)
After=network.target

[Service]
Type=forking
PIDFile=/run/x-ui-decoy.pid
ExecStartPre=${nginx_bin} -t -c ${NGINX_CONF}
ExecStart=${nginx_bin} -c ${NGINX_CONF}
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable x-ui-decoy.service >/dev/null 2>&1 || true
        if systemctl restart x-ui-decoy.service; then
            echo "[DECOY] Native Nginx service x-ui-decoy.service started on 127.0.0.1:${SELFSTEAL_PORT}"
        else
            echo "[DECOY-ERROR] Не удалось запустить x-ui-decoy.service с Nginx. Вывод проверки конфига:"
            ${nginx_bin} -t -c ${NGINX_CONF} || true
            journalctl -u x-ui-decoy.service -n 10 --no-pager || true
        fi
    elif [ -n "$python_bin" ] && [ -x "$python_bin" ] && [ -f "${DECOY_ROOT}/decoy-server.py" ]; then
        ssl_info=$(resolve_ssl_certs) || return 1
        cert=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f1 | tr -d '\r\n')
        key=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f2 | tr -d '\r\n')

        if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
            cert="/etc/x-ui/fallback-inbound.crt"
            key="/etc/x-ui/fallback-inbound.key"
        fi

        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=3x-ui SelfSteal Decoy Web Server (Python fallback)
After=network.target

[Service]
Type=simple
Environment=XUI_SELFSTEAL_PORT=${SELFSTEAL_PORT}
Environment=XUI_SELFSTEAL_DIR=${PUBLIC_DIR}
Environment=XUI_SELFSTEAL_CERT=${cert}
Environment=XUI_SELFSTEAL_KEY=${key}
ExecStart=${python_bin} ${DECOY_ROOT}/decoy-server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable x-ui-decoy.service >/dev/null 2>&1 || true
        if systemctl restart x-ui-decoy.service; then
            echo "[DECOY] Native Python fallback service x-ui-decoy.service started on 127.0.0.1:${SELFSTEAL_PORT}"
        else
            echo "[DECOY-ERROR] Не удалось запустить x-ui-decoy.service с Python. Логи:"
            journalctl -u x-ui-decoy.service -n 10 --no-pager || true
        fi
    else
        echo "[DECOY-WARN] Neither nginx nor python3 found, cannot start decoy service"
    fi
}

check_status() {
    echo "=== Статус SelfSteal Decoy Web Server ==="
    echo "Режим: ${SELFSTEAL_MODE}"
    if [ "$SELFSTEAL_MODE" = "reality" ]; then
        echo "Target REALITY: ${REALITY_SOCKET}; xver: 1"
    fi
    echo "Порт: 127.0.0.1:${SELFSTEAL_PORT}"
    echo "Шаблон: ${SELFSTEAL_TEMPLATE}"
    echo "Каталог файлов: ${PUBLIC_DIR}"
    echo ""

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui-decoy.service 2>/dev/null; then
        echo "✓ Сервис x-ui-decoy.service активен (systemd)"
        systemctl status x-ui-decoy.service --no-pager | head -n 10
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^3x-decoy$"; then
        echo "✓ Контейнер 3x-decoy активен (Docker)"
        docker ps -f name=3x-decoy
    else
        echo "⚠ Сервис x-ui-decoy не запущен"
        if command -v journalctl >/dev/null 2>&1; then
            echo "Последние логи ошибки (journalctl):"
            journalctl -u x-ui-decoy.service -n 10 --no-pager 2>/dev/null || true
        fi
    fi

    echo ""
    echo "Тест локального ответа (127.0.0.1:${SELFSTEAL_PORT}):"
    if [ "$SELFSTEAL_MODE" = "reality" ]; then
        validate_reality_config || return 1
        curl --fail --silent --show-error --max-time 10 --noproxy '*' \
            --haproxy-protocol --unix-socket "$REALITY_SOCKET" \
            "https://${REALITY_DOMAIN}/" -o /dev/null || return 1
        echo "✓ Unix-сокет, PROXY protocol, сертификат и HTTPS-ответ проверены"
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -k -s -I "https://127.0.0.1:${SELFSTEAL_PORT}/" | head -n 5 || echo "Не удалось подключиться к порту ${SELFSTEAL_PORT}"
    fi
}

# Allow isolated tests to source functions without starting services.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

case "${1:-status}" in
    plan)
        if [ "$SELFSTEAL_MODE" != "reality" ]; then
            echo "Для плана SelfSteal REALITY задайте XUI_SELFSTEAL_MODE=reality" >&2
            exit 1
        fi
        reality_plan
        ;;
    validate)
        if [ "$SELFSTEAL_MODE" = "reality" ]; then
            validate_reality_config && validate_reality_runtime
        fi
        ;;
    templates|list)
        list_templates
        ;;
    template|switch)
        switch_template "$2"
        setup_and_start_service
        ;;
    start|restart|apply|install|--install)
        setup_and_start_service
        ;;
    preview)
        port="${2:-8080}"
        current_installed=""
        [ -f "${PUBLIC_DIR}/.current_template" ] && current_installed="$(cat "${PUBLIC_DIR}/.current_template" 2>/dev/null)"
        if [ ! -f "${PUBLIC_DIR}/index.html" ] || [ "$current_installed" != "$SELFSTEAL_TEMPLATE" ]; then
            switch_template "$SELFSTEAL_TEMPLATE"
        fi
        echo "=========================================================="
        echo "Локальный предпросмотр активной заглушки из .env: ${SELFSTEAL_TEMPLATE}"
        echo "URL: http://localhost:${port}"
        echo "Каталог: ${PUBLIC_DIR}"
        echo "=========================================================="
        echo "Смена шаблона: измените XUI_SELFSTEAL_TEMPLATE в .env"
        echo "или выполните: $0 template <имя>"
        echo "=========================================================="
        exec python3 -m http.server "$port" --directory "$PUBLIC_DIR"
        ;;
    status)
        check_status
        ;;
    *)
        echo "Использование: $0 {status|plan|validate|templates|template <name>|preview [порт]|apply}"
        exit 1
        ;;
esac
