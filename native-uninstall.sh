#!/bin/bash
# ============================================================================
# Удаление дополнений .env-конфигурации из нативной установки 3x-ui
# НЕ удаляет саму 3x-ui — только наши дополнения
# ============================================================================

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}Ошибка: запустите от root${plain}" && exit 1

XUI_DIR="/usr/local/x-ui"
XUI_SERVICE="/etc/systemd/system/x-ui.service"

echo -e "${yellow}Удаление дополнений .env-конфигурации...${plain}"

# Удалить init-config.sh
if [ -f "${XUI_DIR}/init-config.sh" ]; then
    rm -f "${XUI_DIR}/init-config.sh"
    echo -e "${green}  ✓ init-config.sh удалён${plain}"
fi

# Восстановить оригинальный systemd-сервис
if [ -f "${XUI_SERVICE}.bak" ]; then
    cp "${XUI_SERVICE}.bak" "${XUI_SERVICE}"
    rm -f "${XUI_SERVICE}.bak"
    systemctl daemon-reload
    echo -e "${green}  ✓ systemd-сервис восстановлен из бэкапа${plain}"
fi

# Удалить certbot cron
if crontab -l 2>/dev/null | grep -q "certbot renew"; then
    crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
    echo -e "${green}  ✓ certbot cron удалён${plain}"
fi

echo ""
echo -e "${green}✅ Дополнения удалены. 3x-ui работает в стандартном режиме.${plain}"
echo -e "${yellow}  .env файл сохранён: /etc/x-ui/.env${plain}"
echo -e "${yellow}  Для полного удаления 3x-ui: x-ui uninstall${plain}"

systemctl restart x-ui 2>/dev/null || true
