#!/bin/bash
# ============================================================================
# 3x-ui Нативная установка с поддержкой .env конфигурации
# Устанавливает 3x-ui как systemd-сервис + наша система конфигурации через .env
# ============================================================================

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# Проверка root
[[ $EUID -ne 0 ]] && echo -e "${red}Ошибка: запустите скрипт от root${plain}" && exit 1

XUI_DIR="/usr/local/x-ui"
XUI_CONFIG_DIR="/etc/x-ui"
XUI_ENV_FILE="${XUI_CONFIG_DIR}/.env"
XUI_SERVICE="/etc/systemd/system/x-ui.service"
XUI_BUNDLED_SERVICE="${XUI_DIR}/x-ui.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTBOT_HELPER="${SCRIPT_DIR}/certbot-domain.sh"
XUI_FORK_CLI="/usr/bin/x-ui-fork"
XUI_FORK_PROJECT_FILE="${XUI_CONFIG_DIR}/fork-project-dir"
DB_PATH="${XUI_CONFIG_DIR}/x-ui.db"
DB_BACKUP=""
INSTALL_DONE=0

if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/.env"
    set +a
elif [ -f "$XUI_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$XUI_ENV_FILE"
    set +a
fi

restore_db_backup_on_error() {
    if [ "$INSTALL_DONE" -ne 1 ] && [ -n "$DB_BACKUP" ] && [ -f "$DB_BACKUP" ]; then
        mkdir -p "$XUI_CONFIG_DIR"
        cp "$DB_BACKUP" "$DB_PATH"
        rm -f "$DB_BACKUP"
        echo -e "${yellow}  ⚠ Ошибка установки, БД восстановлена из бэкапа${plain}"
    fi
}

trap restore_db_backup_on_error EXIT

echo -e "${green}============================================================================${plain}"
echo -e "${green}  3x-ui Нативная установка с .env конфигурацией${plain}"
echo -e "${green}============================================================================${plain}"
echo ""

# ============================================================================
# 1. Установка зависимостей
# ============================================================================
echo -e "${yellow}[1/6] Установка зависимостей...${plain}"

if command -v sqlite3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1 && (command -v haproxy >/dev/null 2>&1 || command -v docker >/dev/null 2>&1) && (command -v nginx >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1); then
    echo -e "${green}  ✓ sqlite3, jq, certbot, haproxy, nginx уже установлены${plain}"
else
    wait_for_apt_lock() {
        if command -v fuser >/dev/null 2>&1; then
            local max_wait=60
            local waited=0
            while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
                if [ "$waited" -eq 0 ]; then
                    echo -e "${yellow}  ⏳ Ожидание освобождения блокировки apt (фоновое обновление системы)...${plain}"
                fi
                sleep 2
                waited=$((waited + 2))
                if [ "$waited" -ge "$max_wait" ]; then
                    break
                fi
            done
        fi
    }

    install_deps() {
        if command -v apt-get > /dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            wait_for_apt_lock
            apt-get update -y -qq || true
            apt-get install -y -qq sqlite3 jq certbot cron haproxy nginx > /dev/null 2>&1 || \
            apt-get install -y -qq sqlite3 jq certbot cron haproxy > /dev/null 2>&1 || \
            apt-get install -y -qq sqlite3 jq certbot cron > /dev/null 2>&1 || \
            apt-get install -y sqlite3 jq
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y -q sqlite jq certbot cronie haproxy nginx > /dev/null 2>&1 || \
            dnf install -y -q sqlite jq certbot cronie haproxy > /dev/null 2>&1 || \
            dnf install -y -q sqlite jq certbot cronie > /dev/null 2>&1 || \
            dnf install -y sqlite jq
        elif command -v yum > /dev/null 2>&1; then
            yum install -y -q sqlite jq certbot cronie haproxy nginx > /dev/null 2>&1 || \
            yum install -y -q sqlite jq certbot cronie haproxy > /dev/null 2>&1 || \
            yum install -y -q sqlite jq certbot cronie > /dev/null 2>&1 || \
            yum install -y sqlite jq
        elif command -v apk > /dev/null 2>&1; then
            apk add --no-cache sqlite jq certbot haproxy nginx > /dev/null 2>&1 || \
            apk add --no-cache sqlite jq certbot haproxy > /dev/null 2>&1 || \
            apk add --no-cache sqlite jq certbot > /dev/null 2>&1 || \
            apk add --no-cache sqlite jq
        elif command -v pacman > /dev/null 2>&1; then
            pacman -Sy --noconfirm sqlite jq certbot cronie haproxy nginx > /dev/null 2>&1 || \
            pacman -Sy --noconfirm sqlite jq certbot cronie haproxy > /dev/null 2>&1 || \
            pacman -Sy --noconfirm sqlite jq certbot cronie > /dev/null 2>&1 || \
            pacman -Sy --noconfirm sqlite jq
        else
            echo -e "${red}Неподдерживаемый менеджер пакетов${plain}"
            exit 1
        fi
    }

    install_deps || {
        echo -e "${red}Ошибка при установке зависимостей (sqlite3, jq)${plain}"
        exit 1
    }
    echo -e "${green}  ✓ Зависимости проверены и установлены${plain}"
    # Отключаем системный дефолтный сайт nginx на 80 порту, чтобы не конфликтовать с certbot/haproxy
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
    fi
fi

# ============================================================================
# 2. Установка 3x-ui через оригинальный install.sh
# ============================================================================
echo -e "${yellow}[2/6] Установка 3x-ui...${plain}"

# --- Бэкап существующей БД перед установкой ---
DOCKER_DB_PATH="${SCRIPT_DIR}/db/x-ui.db"

if [ -f "$DB_PATH" ]; then
    DB_BACKUP="/tmp/x-ui.db.backup.$(date +%s)"
    cp "$DB_PATH" "$DB_BACKUP"
    echo -e "${green}  ✓ Бэкап БД: ${DB_BACKUP}${plain}"
elif [ -f "$DOCKER_DB_PATH" ]; then
    DB_BACKUP="/tmp/x-ui.db.backup.$(date +%s)"
    cp "$DOCKER_DB_PATH" "$DB_BACKUP"
    echo -e "${green}  ✓ Бэкап БД (из Docker): ${DB_BACKUP}${plain}"
fi

CLI_VERSION="${1:-}"
CONFIG_VERSION="${XUI_PANEL_VERSION:-}"
TARGET_VERSION="${CLI_VERSION:-$CONFIG_VERSION}"
DO_INSTALL_UPSTREAM=0

if [ -f "${XUI_DIR}/x-ui" ]; then
    CURRENT_VERSION=$("${XUI_DIR}/x-ui" -v 2>/dev/null | head -n 1 | tr -d ' \r\n' || echo "")
    if [ -n "$CLI_VERSION" ]; then
        echo -e "${yellow}  3x-ui уже установлен (текущая версия: ${CURRENT_VERSION:-неизвестно}). Установка запрошенной версии: ${CLI_VERSION}${plain}"
        TARGET_VERSION="$CLI_VERSION"
        DO_INSTALL_UPSTREAM=1
    elif [ -t 0 ]; then
        echo -e "${yellow}  3x-ui уже установлен (текущая версия: ${CURRENT_VERSION:-неизвестно}).${plain}"
        read -r -p "  Переустановить / сменить версию официальной 3x-ui? [y/N]: " ask_reinstall
        case "$ask_reinstall" in
            y|Y|yes|YES|да|ДА)
                read -r -p "  Какую версию установить? [Enter для latest, или укажите, напр. v2.5.0 / dev]: " input_ver
                TARGET_VERSION="${input_ver:-latest}"
                DO_INSTALL_UPSTREAM=1
                ;;
            *)
                echo -e "${green}  ✓ Оставляем текущую установку 3x-ui (${CURRENT_VERSION:-latest})${plain}"
                DO_INSTALL_UPSTREAM=0
                ;;
        esac
    else
        echo -e "${green}  ✓ 3x-ui уже установлен (${CURRENT_VERSION:-latest}), пропускаем${plain}"
        DO_INSTALL_UPSTREAM=0
    fi
else
    DO_INSTALL_UPSTREAM=1
    if [ -z "$TARGET_VERSION" ] && [ -t 0 ]; then
        echo -e "${yellow}  Выбор версии официальной 3x-ui (MHSanaei):${plain}"
        echo -e "  - [Enter] для последней стабильной (latest)"
        echo -e "  - Или укажите конкретную версию (например: v2.5.0, v2.4.9, dev)"
        read -r -p "  Версия [latest]: " input_ver
        TARGET_VERSION="${input_ver:-latest}"
    fi
    TARGET_VERSION="${TARGET_VERSION:-latest}"
fi

if [ "$DO_INSTALL_UPSTREAM" -eq 1 ]; then
    if [ -n "$TARGET_VERSION" ] && [ "$TARGET_VERSION" != "latest" ]; then
        echo -e "  Запуск оригинального установщика (версия ${TARGET_VERSION})..."
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) "$TARGET_VERSION"
    else
        echo -e "  Запуск оригинального установщика (latest)..."
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    fi
    echo -e "${green}  ✓ 3x-ui установлен${plain}"
fi

# --- Восстановление БД после установки ---
if [ -n "$DB_BACKUP" ] && [ -f "$DB_BACKUP" ]; then
    cp "$DB_BACKUP" "$DB_PATH"
    echo -e "${green}  ✓ БД восстановлена из бэкапа${plain}"
    rm -f "$DB_BACKUP"
    DB_BACKUP=""
fi

# ============================================================================
# 3. Копирование init-config.sh
# ============================================================================
echo -e "${yellow}[3/6] Настройка init-config.sh...${plain}"

cp -f "${SCRIPT_DIR}/init-config.sh" "${XUI_DIR}/init-config.sh"
chmod +x "${XUI_DIR}/init-config.sh"
mkdir -p "${XUI_CONFIG_DIR}"
if [ -f "${SCRIPT_DIR}/fork-sync.sh" ]; then
    cp -f "${SCRIPT_DIR}/fork-sync.sh" "${XUI_DIR}/fork-sync.sh"
    chmod +x "${XUI_DIR}/fork-sync.sh"
fi
if [ -f "${SCRIPT_DIR}/fork-db-apply.sh" ]; then
    cp -f "${SCRIPT_DIR}/fork-db-apply.sh" "${XUI_DIR}/fork-db-apply.sh"
    chmod +x "${XUI_DIR}/fork-db-apply.sh"
fi
if [ -f "${CERTBOT_HELPER}" ]; then
    cp -f "${CERTBOT_HELPER}" "${XUI_DIR}/certbot-domain.sh"
    chmod +x "${XUI_DIR}/certbot-domain.sh"
fi
if [ -f "${SCRIPT_DIR}/native-update.sh" ]; then
    chmod +x "${SCRIPT_DIR}/native-update.sh"
fi
if [ -f "${SCRIPT_DIR}/x-ui-fork.sh" ]; then
    chmod +x "${SCRIPT_DIR}/x-ui-fork.sh"
    ln -sf "${SCRIPT_DIR}/x-ui-fork.sh" "${XUI_FORK_CLI}"
    echo "${SCRIPT_DIR}" > "${XUI_FORK_PROJECT_FILE}"
fi
if [ -d "${SCRIPT_DIR}/decoy" ]; then
    mkdir -p "${XUI_DIR}/decoy"
    cp -rf "${SCRIPT_DIR}/decoy/"* "${XUI_DIR}/decoy/"
    echo -e "${green}  ✓ decoy templates скопированы в ${XUI_DIR}/decoy/${plain}"
fi
if [ -f "${SCRIPT_DIR}/decoy-setup.sh" ]; then
    cp -f "${SCRIPT_DIR}/decoy-setup.sh" "${XUI_DIR}/decoy-setup.sh"
    chmod +x "${XUI_DIR}/decoy-setup.sh"
    echo -e "${green}  ✓ decoy-setup.sh скопирован в ${XUI_DIR}/${plain}"
fi
mkdir -p "${XUI_DIR}/xray-logs"
echo -e "${green}  ✓ init-config.sh скопирован в ${XUI_DIR}/${plain}"

# ============================================================================
# 4. Настройка .env
# ============================================================================
echo -e "${yellow}[4/6] Настройка .env...${plain}"

mkdir -p "${XUI_CONFIG_DIR}"

# Если в проекте есть .env — делаем симлинк (один файл для Docker и нативной)
if [ -f "${SCRIPT_DIR}/.env" ]; then
    ln -sf "${SCRIPT_DIR}/.env" "${XUI_ENV_FILE}"
    echo -e "${green}  ✓ Симлинк: ${XUI_ENV_FILE} → ${SCRIPT_DIR}/.env${plain}"
elif [ -f "${SCRIPT_DIR}/.env.example" ]; then
    cp "${SCRIPT_DIR}/.env.example" "${SCRIPT_DIR}/.env"
    ln -sf "${SCRIPT_DIR}/.env" "${XUI_ENV_FILE}"
    echo -e "${green}  ✓ .env создан из .env.example${plain}"
    echo -e "${green}  ✓ Симлинк: ${XUI_ENV_FILE} → ${SCRIPT_DIR}/.env${plain}"
    echo -e "${yellow}  ⚠ Отредактируйте: nano ${SCRIPT_DIR}/.env${plain}"
else
    echo -e "${yellow}  ⚠ .env не найден, создаём минимальный${plain}"
    cat > "${XUI_ENV_FILE}" << 'ENVEOF'
# 3x-ui конфигурация
# XUI_DOMAIN=panel.example.com
# XUI_ADMIN_EMAIL=admin@example.com
# XUI_PORT=2053
# XUI_BASE_PATH=/secretpath/
ENVEOF
fi

# ============================================================================
# 5. Настройка systemd — добавление EnvironmentFile и ExecStartPre
# ============================================================================
echo -e "${yellow}[5/6] Настройка systemd-сервиса...${plain}"

if [ ! -f "${XUI_SERVICE}" ]; then
    if [ -f "${XUI_BUNDLED_SERVICE}" ]; then
        cp "${XUI_BUNDLED_SERVICE}" "${XUI_SERVICE}"
        echo -e "${green}  ✓ systemd-сервис создан из ${XUI_BUNDLED_SERVICE}${plain}"
    else
        cat > "${XUI_SERVICE}" <<EOF
[Unit]
Description=x-ui Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${XUI_DIR}
ExecStart=${XUI_DIR}/x-ui
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        echo -e "${green}  ✓ systemd-сервис создан: ${XUI_SERVICE}${plain}"
    fi
fi

if [ ! -f "${XUI_SERVICE}.bak" ]; then
    cp "${XUI_SERVICE}" "${XUI_SERVICE}.bak"
    echo -e "  Бэкап: ${XUI_SERVICE}.bak"
fi

if ! grep -q "${XUI_ENV_FILE}" "${XUI_SERVICE}"; then
    sed -i "/\[Service\]/a EnvironmentFile=-${XUI_ENV_FILE}" "${XUI_SERVICE}"
    echo -e "${green}  ✓ EnvironmentFile добавлен${plain}"
fi

if ! grep -q "XUI_XRAY_CONFIG" "${XUI_SERVICE}"; then
    sed -i "/EnvironmentFile/a Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json" "${XUI_SERVICE}"
    echo -e "${green}  ✓ XUI_XRAY_CONFIG задан${plain}"
fi

if ! grep -q "init-config.sh" "${XUI_SERVICE}"; then
    sed -i "/^ExecStart=/i ExecStartPre=${XUI_DIR}/init-config.sh" "${XUI_SERVICE}"
    echo -e "${green}  ✓ ExecStartPre добавлен${plain}"
fi

if [ -f "${XUI_DIR}/fork-sync.sh" ] && ! grep -q "${XUI_DIR}/fork-sync.sh" "${XUI_SERVICE}"; then
    if grep -q "^ExecStartPre=.*init-config.sh" "${XUI_SERVICE}"; then
        sed -i "\|^ExecStartPre=.*init-config.sh|i ExecStartPre=${XUI_DIR}/fork-sync.sh" "${XUI_SERVICE}"
    else
        sed -i "/^ExecStart=/i ExecStartPre=${XUI_DIR}/fork-sync.sh" "${XUI_SERVICE}"
    fi
    echo -e "${green}  ✓ Fork sync ExecStartPre добавлен${plain}"
fi

systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1 || true
echo -e "${green}  ✓ systemd перезагружен${plain}"
echo -e "${green}  ✓ x-ui autostart включён${plain}"

if [ -x "${XUI_DIR}/fork-db-apply.sh" ]; then
    cat > /etc/systemd/system/x-ui-fork-db-apply.service <<EOF
[Unit]
Description=Apply x-ui fork DB/env configuration
After=x-ui.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
EnvironmentFile=-${XUI_ENV_FILE}
Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json
Environment=XUI_SKIP_PKILL=true
ExecStart=${XUI_DIR}/fork-db-apply.sh
EOF

    cat > /etc/systemd/system/x-ui-fork-db-apply.path <<EOF
[Unit]
Description=Watch x-ui database changes for fork configuration
StartLimitIntervalSec=0

[Path]
PathChanged=${XUI_CONFIG_DIR}/x-ui.db
PathModified=${XUI_CONFIG_DIR}/x-ui.db
Unit=x-ui-fork-db-apply.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl reset-failed x-ui-fork-db-apply.service x-ui-fork-db-apply.path >/dev/null 2>&1 || true
    systemctl restart x-ui-fork-db-apply.path >/dev/null 2>&1 || systemctl enable --now x-ui-fork-db-apply.path >/dev/null 2>&1 || true
    echo -e "${green}  ✓ DB apply path включён${plain}"
fi

# ============================================================================
# 6. Настройка certbot и автообновления сертификатов
# ============================================================================
echo -e "${yellow}[6/6] Настройка certbot...${plain}"

# Читаем домен из .env, а при восстановлении бэкапа — из БД панели
XUI_DOMAIN=$(grep "^XUI_DOMAIN=" "${XUI_ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
XUI_ADMIN_EMAIL=$(grep "^XUI_ADMIN_EMAIL=" "${XUI_ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")

case "$XUI_ADMIN_EMAIL" in
    admin@example.com|*@example.com|*@example.org|*@example.net) XUI_ADMIN_EMAIL="" ;;
esac

if [ -z "$XUI_DOMAIN" ] && [ -f "$DB_PATH" ]; then
    XUI_DOMAIN=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "")
    [ -n "$XUI_DOMAIN" ] && echo -e "${green}  ✓ Домен взят из БД: ${XUI_DOMAIN}${plain}"
fi

if [ -f "${CERTBOT_HELPER}" ]; then
    . "${CERTBOT_HELPER}"
    certbot_configure_auto_renewal || true

    if [ -n "$XUI_DOMAIN" ]; then
        certbot_issue_domain_cert "$XUI_DOMAIN" "$XUI_ADMIN_EMAIL" || echo -e "${yellow}  ⚠ Не удалось получить сертификат для ${XUI_DOMAIN} (DNS/порт 80?)${plain}"
    else
        echo -e "${yellow}  ⚠ Домен не найден в .env или БД, выпуск сертификата пропущен${plain}"
    fi

    XUI_SELFSTEAL_DOMAIN=$(grep "^XUI_SELFSTEAL_DOMAIN=" "${XUI_ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    if [ -n "$XUI_SELFSTEAL_DOMAIN" ] && [ "$XUI_SELFSTEAL_DOMAIN" != "$XUI_DOMAIN" ]; then
        echo -e "${yellow}  Выпуск сертификата для сайта-заглушки (${XUI_SELFSTEAL_DOMAIN})...${plain}"
        certbot_issue_domain_cert "$XUI_SELFSTEAL_DOMAIN" "$XUI_ADMIN_EMAIL" || echo -e "${yellow}  ⚠ Не удалось получить сертификат для ${XUI_SELFSTEAL_DOMAIN}${plain}"
    fi
else
    echo -e "${yellow}  ⚠ ${CERTBOT_HELPER} не найден, certbot пропущен${plain}"
fi

# ============================================================================
# Перезапуск
# ============================================================================
echo ""
systemctl restart x-ui
sleep 2

if command -v haproxy >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/haproxy
    [ -f "${XUI_CONFIG_DIR}/haproxy.cfg" ] && cp -f "${XUI_CONFIG_DIR}/haproxy.cfg" /etc/haproxy/haproxy.cfg 2>/dev/null || true
    systemctl enable haproxy >/dev/null 2>&1 || true
    systemctl restart haproxy >/dev/null 2>&1 || true
fi

if [ -x "${XUI_DIR}/decoy-setup.sh" ]; then
    "${XUI_DIR}/decoy-setup.sh" apply >/dev/null 2>&1 || true
fi

if systemctl is-active --quiet x-ui && [ -f "$DB_PATH" ]; then
    PORT_VALUE=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "")
    BASE_PATH_VALUE=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "")

    if [ -z "$PORT_VALUE" ] || [ -z "$BASE_PATH_VALUE" ]; then
        echo -e "${yellow}  Автогенерация недостающих настроек панели...${plain}"
        "${XUI_DIR}/init-config.sh" || true
        systemctl restart x-ui
        sleep 2
    fi
fi

if systemctl is-active --quiet x-ui; then
    echo -e "${green}============================================================================${plain}"
    echo -e "${green}  ✅ Установка завершена! 3x-ui запущен${plain}"
    echo -e "${green}============================================================================${plain}"

    # Показать URL
    PORT=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "2053")
    BASE_PATH=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "/")
    DOMAIN=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "localhost")
    CERT_FILE=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || echo "")
    KEY_FILE=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webKeyFile';" 2>/dev/null || echo "")

    [ -n "$PORT" ] || PORT="2053"
    [ -n "$BASE_PATH" ] || BASE_PATH="/"
    [ -n "$DOMAIN" ] || DOMAIN="localhost"
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$LOCAL_IP" ] || LOCAL_IP="127.0.0.1"

    if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        if [ "$CERT_FILE" = "/etc/x-ui/fallback-web.crt" ]; then
            echo -e "  📍 Панель (HTTPS, IP):  https://${LOCAL_IP}:${PORT}${BASE_PATH}"
            if [ -n "$XUI_DOMAIN" ] && [ "$XUI_DOMAIN" != "localhost" ] && [ "$XUI_DOMAIN" != "$LOCAL_IP" ]; then
                echo -e "  📍 Домен (fallback):    https://${XUI_DOMAIN}:${PORT}${BASE_PATH}"
            fi
            echo -e "  📍 Локально (туннель):  http://localhost:${PORT}${BASE_PATH}"
            echo -e "  ⚠ Сертификат Let's Encrypt не выпущен — активен самоподписанный SSL с привязкой к IP"
        elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "localhost" ]; then
            echo -e "  📍 Панель (HTTPS):      https://${DOMAIN}:${PORT}${BASE_PATH}"
            echo -e "  📍 Локально (туннель):  http://localhost:${PORT}${BASE_PATH}"
        else
            echo -e "  📍 Панель (HTTPS):      https://${LOCAL_IP}:${PORT}${BASE_PATH}"
            echo -e "  📍 Локально (туннель):  http://localhost:${PORT}${BASE_PATH}"
        fi
    elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "localhost" ]; then
        echo -e "  📍 Домен (без SSL):     http://${DOMAIN}:${PORT}${BASE_PATH}"
        echo -e "  📍 Локально на сервере: http://localhost:${PORT}${BASE_PATH}"
        if [ -n "$LOCAL_IP" ] && [ "$LOCAL_IP" != "127.0.0.1" ]; then
            echo -e "  📍 По сети / через IP:  http://${LOCAL_IP}:${PORT}${BASE_PATH}"
        fi
        echo -e "  ⚠ HTTPS не активен: сертификат для ${DOMAIN} не найден на диске"
    else
        echo -e "  📍 Локально на сервере: http://localhost:${PORT}${BASE_PATH}"
        if [ -n "$LOCAL_IP" ] && [ "$LOCAL_IP" != "127.0.0.1" ]; then
            echo -e "  📍 По сети / через IP:  http://${LOCAL_IP}:${PORT}${BASE_PATH}"
        fi
        echo -e "  🔒 SSH туннель:         ssh -N -L 8080:localhost:${PORT} user@server-ip"
        echo -e "  🌐 Через туннель:       http://localhost:8080${BASE_PATH}"
    fi

    DECOY_DOM=$(grep "^XUI_SELFSTEAL_DOMAIN=" "${XUI_ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    if [ -n "$DECOY_DOM" ] && [ "$DECOY_DOM" != "localhost" ]; then
        echo -e "  🎭 Сайт-заглушка:       https://${DECOY_DOM}/"
    fi

    # Учётные данные и токен
    ADMIN_USER=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT username FROM users LIMIT 1;" 2>/dev/null || echo "")
    ADMIN_PASS="${XUI_ADMIN_PASSWORD:-}"
    API_TOKEN=""
    SECRET_KEY=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='secret';" 2>/dev/null || echo "")

    if [ -f "${XUI_CONFIG_DIR}/install-result.env" ]; then
        if [ -z "$ADMIN_USER" ]; then
            ADMIN_USER=$(grep -iE "^(XUI_)?USERNAME=" "${XUI_CONFIG_DIR}/install-result.env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        fi
        if [ -z "$ADMIN_PASS" ]; then
            ADMIN_PASS=$(grep -iE "^(XUI_)?PASSWORD=" "${XUI_CONFIG_DIR}/install-result.env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        fi
        API_TOKEN=$(grep -iE "^(XUI_)?(API_TOKEN|TOKEN)=" "${XUI_CONFIG_DIR}/install-result.env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi

    echo -e ""
    if [ -n "$ADMIN_USER" ]; then
        echo -e "  👤 Логин:               ${green}${ADMIN_USER}${plain}"
    fi
    if [ -n "$ADMIN_PASS" ]; then
        echo -e "  🔑 Пароль:              ${green}${ADMIN_PASS}${plain}"
    elif [ -n "$ADMIN_USER" ]; then
        echo -e "  🔑 Пароль:              ${yellow}(сохранён в .env / БД)${plain}"
    fi
    if [ -n "$API_TOKEN" ]; then
        echo -e "  🎫 API Token:           ${green}${API_TOKEN}${plain}"
    fi
    if [ -n "${XUI_SECRET_KEY:-}" ]; then
        echo -e "  🛡️ Секретный ключ:      ${XUI_SECRET_KEY}"
    fi
    echo -e ""
    echo -e "  Конфигурация: ${yellow}${XUI_ENV_FILE}${plain}"
    echo -e "  Единый CLI: ${yellow}x-ui-fork help${plain}"
    echo -e "  Обновить upstream + fork: ${yellow}x-ui-fork update${plain}"
    echo -e "  Применить изменения: ${yellow}systemctl restart x-ui${plain}"
    echo -e "  Логи: ${yellow}journalctl -u x-ui -f${plain}"
    echo -e ""
else
    echo -e "${red}  ✗ 3x-ui не запустился. Проверьте: journalctl -u x-ui -e${plain}"
    exit 1
fi

INSTALL_DONE=1
