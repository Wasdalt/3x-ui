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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

if [ -f "${XUI_DIR}/x-ui" ]; then
    echo -e "${green}  ✓ 3x-ui уже установлен, пропускаем${plain}"
else
    echo -e "  Запуск оригинального установщика..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    echo -e "${green}  ✓ 3x-ui установлен${plain}"
fi

# ============================================================================
# 3. Копирование init-config.sh
# ============================================================================
echo -e "${yellow}[3/6] Настройка init-config.sh...${plain}"

cp -f "${SCRIPT_DIR}/init-config.sh" "${XUI_DIR}/init-config.sh"
chmod +x "${XUI_DIR}/init-config.sh"
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
    echo -e "${red}  ✗ Файл ${XUI_SERVICE} не найден${plain}"
    exit 1
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

systemctl daemon-reload
echo -e "${green}  ✓ systemd перезагружен${plain}"

# ============================================================================
# 6. Настройка certbot cron
# ============================================================================
echo -e "${yellow}[6/6] Настройка certbot...${plain}"

# Читаем домен из .env
XUI_DOMAIN=$(grep "^XUI_DOMAIN=" "${XUI_ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
XUI_ADMIN_EMAIL=$(grep "^XUI_ADMIN_EMAIL=" "${XUI_ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")

if [ -n "$XUI_DOMAIN" ] && [ -n "$XUI_ADMIN_EMAIL" ]; then
    CERT_PATH="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
    if [ ! -f "$CERT_PATH" ]; then
        echo -e "  Получение сертификата для ${XUI_DOMAIN}..."
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "${XUI_ADMIN_EMAIL}" \
            -d "${XUI_DOMAIN}" \
            --preferred-challenges http || echo -e "${yellow}  ⚠ Не удалось получить сертификат (порт 80 занят?)${plain}"
    else
        echo -e "${green}  ✓ Сертификат уже существует${plain}"
    fi

    # Cron для обновления каждые 12 часов
    CRON_CMD="0 */12 * * * certbot renew --quiet --deploy-hook 'systemctl restart x-ui'"
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -
    echo -e "${green}  ✓ Cron для обновления сертификатов настроен${plain}"
else
    echo -e "${yellow}  ⚠ XUI_DOMAIN или XUI_ADMIN_EMAIL не заданы, certbot пропущен${plain}"
    echo -e "${yellow}  Задайте их в ${XUI_ENV_FILE} и запустите:${plain}"
    echo -e "${yellow}  certbot certonly --standalone -d ДОМЕН --email EMAIL${plain}"
fi

# ============================================================================
# Перезапуск
# ============================================================================
echo ""
systemctl restart x-ui
sleep 2

if systemctl is-active --quiet x-ui; then
    echo -e "${green}============================================================================${plain}"
    echo -e "${green}  ✅ Установка завершена! 3x-ui запущен${plain}"
    echo -e "${green}============================================================================${plain}"

    # Показать URL
    PORT=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "2053")
    BASE_PATH=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "/")
    DOMAIN=$(sqlite3 "${XUI_CONFIG_DIR}/x-ui.db" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "localhost")
    
    echo -e "  📍 Панель: https://${DOMAIN}:${PORT}${BASE_PATH}"
    echo -e ""
    echo -e "  Конфигурация: ${yellow}${XUI_ENV_FILE}${plain}"
    echo -e "  Применить изменения: ${yellow}systemctl restart x-ui${plain}"
    echo -e "  Логи: ${yellow}journalctl -u x-ui -f${plain}"
    echo -e ""
else
    echo -e "${red}  ✗ 3x-ui не запустился. Проверьте: journalctl -u x-ui -e${plain}"
    exit 1
fi
