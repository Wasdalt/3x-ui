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
XUI_CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-x-ui.sh"
XUI_FORK_CLI="/usr/bin/x-ui-fork"
XUI_FORK_PROJECT_FILE="/etc/x-ui/fork-project-dir"

echo -e "${yellow}Удаление дополнений .env-конфигурации...${plain}"

# Удалить init-config.sh
if [ -f "${XUI_DIR}/init-config.sh" ]; then
    rm -f "${XUI_DIR}/init-config.sh"
    echo -e "${green}  ✓ init-config.sh удалён${plain}"
fi

if [ -f "${XUI_DIR}/certbot-domain.sh" ]; then
    rm -f "${XUI_DIR}/certbot-domain.sh"
    echo -e "${green}  ✓ certbot-domain.sh удалён${plain}"
fi

if [ -f "${XUI_FORK_CLI}" ]; then
    rm -f "${XUI_FORK_CLI}"
    echo -e "${green}  ✓ x-ui-fork удалён${plain}"
fi

if [ -f "${XUI_FORK_PROJECT_FILE}" ]; then
    rm -f "${XUI_FORK_PROJECT_FILE}"
    echo -e "${green}  ✓ fork-project-dir удалён${plain}"
fi

# Восстановить оригинальный systemd-сервис
if [ -f "${XUI_SERVICE}.bak" ]; then
    cp "${XUI_SERVICE}.bak" "${XUI_SERVICE}"
    rm -f "${XUI_SERVICE}.bak"
    systemctl daemon-reload
    echo -e "${green}  ✓ systemd-сервис восстановлен из бэкапа${plain}"
fi

# Удалить certbot cron, созданный native-install.sh
if crontab -l 2>/dev/null | grep -q "3x-ui certbot auto-renewal"; then
    (crontab -l 2>/dev/null | grep -v "3x-ui certbot auto-renewal" || true) | crontab -
    echo -e "${green}  ✓ certbot cron удалён${plain}"
fi

if [ -f "${XUI_CERTBOT_DEPLOY_HOOK}" ]; then
    rm -f "${XUI_CERTBOT_DEPLOY_HOOK}"
    echo -e "${green}  ✓ certbot deploy-hook удалён${plain}"
fi

echo ""
echo -e "${green}✅ Дополнения удалены. 3x-ui работает в стандартном режиме.${plain}"
echo -e "${yellow}  .env файл сохранён: /etc/x-ui/.env${plain}"
echo -e "${yellow}  Для полного удаления 3x-ui: x-ui uninstall${plain}"

systemctl restart x-ui 2>/dev/null || true
