#!/bin/bash
# ============================================================================
# SelfSteal Decoy Site Manager for 3x-ui Fork
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

DECOY_ROOT="${SCRIPT_DIR}/decoy"
[ -d "$DECOY_ROOT" ] || DECOY_ROOT="${XUI_DIR}/decoy"

TEMPLATES_DIR="${DECOY_ROOT}/templates"
PUBLIC_DIR="${DECOY_ROOT}/public"
NGINX_CONF="/etc/x-ui/nginx-decoy.conf"
SERVICE_FILE="/etc/systemd/system/x-ui-decoy.service"

SELFSTEAL_PORT="${XUI_SELFSTEAL_PORT:-10444}"
SELFSTEAL_TEMPLATE="${XUI_SELFSTEAL_TEMPLATE:-shopflow}"

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

resolve_ssl_certs() {
    target_domain="${XUI_SELFSTEAL_DOMAIN:-${XUI_HAPROXY_DOMAIN:-${XUI_DOMAIN:-}}}"
    if [ -z "$target_domain" ] && [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 >/dev/null 2>&1; then
        db_sub=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
        db_web=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "")
        target_domain="${db_sub:-${db_web}}"
    fi
    cert=""
    key=""

    if [ -n "$target_domain" ] && [ "$target_domain" != "127.0.0.1" ] && [ "$target_domain" != "localhost" ]; then
        cand_cert="/etc/letsencrypt/live/${target_domain}/fullchain.pem"
        cand_key="/etc/letsencrypt/live/${target_domain}/privkey.pem"
        if [ -f "$cand_cert" ] && [ -f "$cand_key" ]; then
            cert="$cand_cert"
            key="$cand_key"
        elif command -v certbot_issue_domain_cert >/dev/null 2>&1 || [ -f "${SCRIPT_DIR}/certbot-domain.sh" ] || [ -f "${XUI_DIR}/certbot-domain.sh" ]; then
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

    if [ -z "$cert" ]; then
        # Find any available Let's Encrypt certificate
        found_cert=$(find /etc/letsencrypt/live/ -name "fullchain.pem" 2>/dev/null | head -n 1)
        if [ -n "$found_cert" ]; then
            f_dom=$(echo "$found_cert" | awk -F'/' '{print $(NF-1)}')
            found_key="/etc/letsencrypt/live/${f_dom}/privkey.pem"
            if [ -f "$found_key" ]; then
                cert="$found_cert"
                key="$found_key"
            fi
        fi
    fi

    if [ -z "$cert" ] && [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 >/dev/null 2>&1; then
        db_cert=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || echo "")
        db_key=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webKeyFile';" 2>/dev/null || echo "")
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

    printf "%s|%s\n" "$cert" "$key"
}

generate_nginx_conf() {
    ssl_info=$(resolve_ssl_certs)
    cert=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f1 | tr -d '\r\n')
    key=$(echo "$ssl_info" | tail -n 1 | cut -d'|' -f2 | tr -d '\r\n')

    # Double check cert validity
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
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

    # Detect nginx version for http2 syntax compatibility
    nginx_http2_listen="listen 127.0.0.1:${SELFSTEAL_PORT} ssl;"
    nginx_http2_line=""
    bin_to_check="${nginx_bin:-$(command -v nginx || true)}"
    if [ -n "$bin_to_check" ] && [ -x "$bin_to_check" ]; then
        nver=$("$bin_to_check" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        nmajor=$(echo "$nver" | cut -d. -f1)
        nminor=$(echo "$nver" | cut -d. -f2)
        npatch=$(echo "$nver" | cut -d. -f3)
        if [ "${nmajor:-0}" -gt 1 ] || [ "${nmajor:-0}" -eq 1 -a "${nminor:-0}" -gt 25 ] || [ "${nmajor:-0}" -eq 1 -a "${nminor:-0}" -eq 25 -a "${npatch:-0}" -ge 1 ]; then
            nginx_http2_listen="listen 127.0.0.1:${SELFSTEAL_PORT} ssl;"
            nginx_http2_line="http2 on;"
        else
            nginx_http2_listen="listen 127.0.0.1:${SELFSTEAL_PORT} ssl http2;"
            nginx_http2_line=""
        fi
    else
        nginx_http2_listen="listen 127.0.0.1:${SELFSTEAL_PORT} ssl http2;"
        nginx_http2_line=""
    fi

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
            web_proxy_loc="        location / {
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

            extra_servers="${extra_servers}

    server {
        ${nginx_http2_listen}
        ${nginx_http2_line}
        server_name ${c_dom};

        error_page 497 =301 https://\$host\$request_uri;

        ssl_certificate ${c_cert};
        ssl_certificate_key ${c_key};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets on;

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

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        ${nginx_http2_listen}
        ${nginx_http2_line}
        server_name _ ${target_domain};

        error_page 497 =301 https://\$host\$request_uri;

        ssl_certificate ${cert};
        ssl_certificate_key ${key};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets on;

        root ${PUBLIC_DIR};
        index index.html;

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
        generate_nginx_conf
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
        generate_nginx_conf
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
        ssl_info=$(resolve_ssl_certs)
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
    if command -v curl >/dev/null 2>&1; then
        curl -k -s -I "https://127.0.0.1:${SELFSTEAL_PORT}/" | head -n 5 || echo "Не удалось подключиться к порту ${SELFSTEAL_PORT}"
    fi
}

case "${1:-status}" in
    templates|list)
        list_templates
        ;;
    template|switch)
        switch_template "$2"
        setup_and_start_service
        ;;
    start|restart|apply)
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
        echo "Использование: $0 {status|templates|template <name>|preview [порт]|apply}"
        exit 1
        ;;
esac
