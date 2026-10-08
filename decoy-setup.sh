#!/bin/bash
# ============================================================================
# SelfSteal Decoy Site Manager for 3x-ui Fork
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
CONFIG_DIR="${XUI_CONFIG_DIR:-/etc/x-ui}"
ENV_FILE="${XUI_ENV_FILE:-${CONFIG_DIR}/.env}"

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
SELFSTEAL_TEMPLATE="${XUI_SELFSTEAL_TEMPLATE:-tech}"

list_templates() {
    echo "Доступные шаблоны сайта-заглушки (SelfSteal):"
    for dir in "${TEMPLATES_DIR}"/*; do
        if [ -d "$dir" ] && [ -f "$dir/index.html" ]; then
            name=$(basename "$dir")
            if [ "$name" = "$SELFSTEAL_TEMPLATE" ]; then
                echo "  * $name (активный)"
            else
                echo "  - $name"
            fi
        fi
    done
}

switch_template() {
    target=$1
    if [ -z "$target" ]; then
        echo "Ошибка: укажите имя шаблона (tech, converter, blog, corporate)"
        list_templates
        return 1
    fi

    if [ ! -f "${TEMPLATES_DIR}/${target}/index.html" ]; then
        echo "Ошибка: шаблон '${target}' не найден в ${TEMPLATES_DIR}"
        list_templates
        return 1
    fi

    mkdir -p "$PUBLIC_DIR"
    cp -rf "${TEMPLATES_DIR}/${target}/"* "$PUBLIC_DIR/"
    echo "✓ Шаблон '${target}' успешно установлен в ${PUBLIC_DIR}"

    # Also sync to /usr/local/x-ui/decoy if running native
    if [ "$DECOY_ROOT" != "${XUI_DIR}/decoy" ] && [ -d "${XUI_DIR}" ]; then
        mkdir -p "${XUI_DIR}/decoy/public"
        cp -rf "${PUBLIC_DIR}/"* "${XUI_DIR}/decoy/public/" 2>/dev/null || true
    fi

    # Update .env if accessible
    if [ -f "$ENV_FILE" ]; then
        if grep -q "^XUI_SELFSTEAL_TEMPLATE=" "$ENV_FILE"; then
            sed -i "s/^XUI_SELFSTEAL_TEMPLATE=.*/XUI_SELFSTEAL_TEMPLATE=${target}/" "$ENV_FILE"
        fi
    fi
}

resolve_ssl_certs() {
    target_domain="${XUI_SELFSTEAL_DOMAIN:-${XUI_HAPROXY_DOMAIN:-${XUI_DOMAIN:-}}}"
    cert=""
    key=""

    if [ -n "$target_domain" ]; then
        cand_cert="/etc/letsencrypt/live/${target_domain}/fullchain.pem"
        cand_key="/etc/letsencrypt/live/${target_domain}/privkey.pem"
        if [ -f "$cand_cert" ] && [ -f "$cand_key" ]; then
            cert="$cand_cert"
            key="$cand_key"
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

    echo "$cert|$key"
}

generate_nginx_conf() {
    ssl_info=$(resolve_ssl_certs)
    cert=$(echo "$ssl_info" | cut -d'|' -f1)
    key=$(echo "$ssl_info" | cut -d'|' -f2)

    mkdir -p "$(dirname "$NGINX_CONF")"
    cat > "$NGINX_CONF" <<EOF
worker_processes 1;
pid /run/x-ui-decoy.pid;
error_log /var/log/x-ui-decoy.log warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    sendfile on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen 127.0.0.1:${SELFSTEAL_PORT} ssl;
        http2 on;
        server_name _;

        ssl_certificate ${cert};
        ssl_certificate_key ${key};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        root ${PUBLIC_DIR};
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html =404;
        }

        location ~ /\. {
            deny all;
        }
    }
}
EOF
}

setup_and_start_service() {
    # 1. Ensure public dir has an index.html
    if [ ! -f "${PUBLIC_DIR}/index.html" ]; then
        switch_template "$SELFSTEAL_TEMPLATE"
    fi

    # 2. Check if running in Docker or Native
    if [ -f "/.dockerenv" ] || ( [ -z "$(command -v systemctl 2>/dev/null)" ] && command -v docker >/dev/null 2>&1 ); then
        # Docker mode
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

    # Native mode (systemd)
    nginx_bin=$(command -v nginx || echo "/usr/sbin/nginx")
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
        systemctl restart x-ui-decoy.service >/dev/null 2>&1 || true
        echo "[DECOY] Native Nginx service x-ui-decoy.service started on 127.0.0.1:${SELFSTEAL_PORT}"
    elif [ -n "$python_bin" ] && [ -x "$python_bin" ] && [ -f "${DECOY_ROOT}/decoy-server.py" ]; then
        ssl_info=$(resolve_ssl_certs)
        cert=$(echo "$ssl_info" | cut -d'|' -f1)
        key=$(echo "$ssl_info" | cut -d'|' -f2)

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
        systemctl restart x-ui-decoy.service >/dev/null 2>&1 || true
        echo "[DECOY] Native Python fallback service x-ui-decoy.service started on 127.0.0.1:${SELFSTEAL_PORT}"
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
    status)
        check_status
        ;;
    *)
        echo "Использование: $0 {status|templates|template <name>|apply}"
        exit 1
        ;;
esac
