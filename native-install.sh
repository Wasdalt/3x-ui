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

if command -v apt-get > /dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq sqlite3 jq certbot cron > /dev/null 2>&1
elif command -v yum > /dev/null 2>&1; then
    yum install -y -q sqlite jq certbot cronie > /dev/null 2>&1
elif command -v apk > /dev/null 2>&1; then
    apk add --no-cache sqlite jq certbot > /dev/null 2>&1
else
    echo -e "${red}Неподдерживаемый менеджер пакетов${plain}"
    exit 1
fi
echo -e "${green}  ✓ sqlite3, jq, certbot установлены${plain}"

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

if [ -f "${XUI_DIR}/x-ui" ]; then
    echo -e "${green}  ✓ 3x-ui уже установлен, пропускаем${plain}"
else
    echo -e "  Запуск оригинального установщика..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
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
    cp -f "${SCRIPT_DIR}/x-ui-fork.sh" "${XUI_FORK_CLI}"
    chmod +x "${XUI_FORK_CLI}"
    echo "${SCRIPT_DIR}" > "${XUI_FORK_PROJECT_FILE}"
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

# Бэкап оригинала
if [ ! -f "${XUI_SERVICE}.bak" ]; then
    cp "${XUI_SERVICE}" "${XUI_SERVICE}.bak"
    echo -e "  Бэкап: ${XUI_SERVICE}.bak"
fi

# Добавляем EnvironmentFile для нашего .env (проверяем именно наш путь)
if ! grep -q "${XUI_ENV_FILE}" "${XUI_SERVICE}"; then
    sed -i "/\[Service\]/a EnvironmentFile=-${XUI_ENV_FILE}" "${XUI_SERVICE}"
    echo -e "${green}  ✓ EnvironmentFile добавлен${plain}"
fi

# Добавляем переменные для нативных путей
if ! grep -q "XUI_XRAY_CONFIG" "${XUI_SERVICE}"; then
    sed -i "/EnvironmentFile/a Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json" "${XUI_SERVICE}"
    echo -e "${green}  ✓ XUI_XRAY_CONFIG задан${plain}"
fi

# Добавляем ExecStartPre для init-config.sh (если ещё нет)
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
echo -e "${green}  ✓ systemd перезагружен${plain}"

if [ -x "${XUI_DIR}/fork-db-apply.sh" ]; then
    cat > /etc/systemd/system/x-ui-fork-db-apply.service <<EOF
[Unit]
Description=Apply x-ui fork DB/env configuration
After=x-ui.service

[Service]
Type=oneshot
EnvironmentFile=-${XUI_ENV_FILE}
Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json
ExecStart=${XUI_DIR}/fork-db-apply.sh
EOF

    cat > /etc/systemd/system/x-ui-fork-db-apply.path <<EOF
[Unit]
Description=Watch x-ui database changes for fork configuration

[Path]
PathChanged=${XUI_CONFIG_DIR}/x-ui.db
Unit=x-ui-fork-db-apply.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now x-ui-fork-db-apply.path >/dev/null 2>&1 || true
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
else
    echo -e "${yellow}  ⚠ ${CERTBOT_HELPER} не найден, certbot пропущен${plain}"
fi

# ============================================================================
# Перезапуск
# ============================================================================
echo ""
systemctl restart x-ui
sleep 2

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
    
    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "localhost" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo -e "  📍 Панель: https://${DOMAIN}:${PORT}${BASE_PATH}"
    elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "localhost" ]; then
        echo -e "  📍 Панель: http://${DOMAIN}:${PORT}${BASE_PATH}"
        echo -e "  ⚠ HTTPS не включён: сертификат для ${DOMAIN} ещё не выпущен"
    else
        echo -e "  📍 Панель: http://server-ip:${PORT}${BASE_PATH}"
        echo -e "  🔒 SSH tunnel: ssh -N -L 8080:localhost:${PORT} user@server-ip"
        echo -e "  🌐 Локально через tunnel: http://localhost:8080${BASE_PATH}"
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
