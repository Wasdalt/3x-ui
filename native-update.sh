#!/bin/bash
# ============================================================================
# Unified native update for 3x-ui with fork overlay re-application.
# Updates upstream 3x-ui, then reapplies .env/init-config/certbot integration.
# ============================================================================

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}Ошибка: запустите скрипт от root${plain}" && exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_PATH="/etc/x-ui/x-ui.db"
BACKUP_PATH=""
UPDATE_DONE=0

restore_backup_on_error() {
    if [ "$UPDATE_DONE" -ne 1 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
        mkdir -p /etc/x-ui
        cp "$BACKUP_PATH" "$DB_PATH"
        rm -f "$BACKUP_PATH"
        echo -e "${yellow}  ⚠ Ошибка обновления, БД восстановлена из бэкапа${plain}"
    fi
}

trap restore_backup_on_error EXIT

echo -e "${green}============================================================================${plain}"
echo -e "${green}  3x-ui unified update: upstream + fork overlay${plain}"
echo -e "${green}============================================================================${plain}"
echo ""

if [ -f "$DB_PATH" ]; then
    BACKUP_PATH="/tmp/x-ui.db.update.$(date +%s)"
    cp "$DB_PATH" "$BACKUP_PATH"
    echo -e "${green}  ✓ Бэкап БД: ${BACKUP_PATH}${plain}"
fi

echo -e "${yellow}[1/2] Обновление официальной 3x-ui...${plain}"
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)

if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
    mkdir -p /etc/x-ui
    cp "$BACKUP_PATH" "$DB_PATH"
    rm -f "$BACKUP_PATH"
    BACKUP_PATH=""
    echo -e "${green}  ✓ БД восстановлена после upstream update${plain}"
fi

echo -e "${yellow}[2/2] Повторное применение fork-обвязки...${plain}"
bash "${SCRIPT_DIR}/native-install.sh"

echo ""
echo -e "${green}✅ Обновление завершено: официальный 3x-ui обновлён, fork-настройки применены.${plain}"
UPDATE_DONE=1
