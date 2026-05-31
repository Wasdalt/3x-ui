#!/bin/bash
# ============================================================================
# Unified CLI for official 3x-ui menu and fork native helpers.
# ============================================================================

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

PROJECT_DIR_FILE="${XUI_FORK_PROJECT_DIR_FILE:-/etc/x-ui/fork-project-dir}"
PROJECT_DIR="${XUI_FORK_PROJECT_DIR:-}"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"

if [ -z "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR_FILE" ]; then
    PROJECT_DIR=$(cat "$PROJECT_DIR_FILE")
fi

[ -n "$PROJECT_DIR" ] || PROJECT_DIR="/home/usermain/project/3x-ui"

need_root() {
    [[ $EUID -ne 0 ]] && echo -e "${red}Ошибка: запустите от root${plain}" && exit 1
}

panel_url() {
    if [ ! -f "$DB_PATH" ]; then
        echo "БД не найдена: $DB_PATH"
        return 1
    fi

    port=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "")
    base_path=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "")
    domain=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null || echo "")

    [ -n "$port" ] || port="2053"
    [ -n "$base_path" ] || base_path="/"

    if [ -n "$domain" ] && [ "$domain" != "localhost" ]; then
        echo "https://${domain}:${port}${base_path}"
    else
        echo "http://server-ip:${port}${base_path}"
        echo "SSH tunnel: ssh -N -L 8080:localhost:${port} user@server-ip"
        echo "Tunnel URL: http://localhost:8080${base_path}"
    fi
}

show_help() {
    cat <<EOF
3x-ui fork unified CLI

Usage: x-ui-fork <command>

Commands:
  menu      Open official author x-ui menu
  apply     Apply fork native overlay (.env, init-config, certbot hooks)
  update    Update official 3x-ui, then reapply fork overlay
  restart   Restart x-ui systemd service
  url       Print current panel URL from DB
  env       Print active .env path
  help      Show this help
EOF
}

case "${1:-help}" in
    menu)
        need_root
        if [ ! -x /usr/bin/x-ui ]; then
            echo -e "${red}/usr/bin/x-ui не найден${plain}"
            exit 1
        fi
        exec /usr/bin/x-ui
        ;;
    apply)
        need_root
        if [ ! -f "${PROJECT_DIR}/native-install.sh" ]; then
            echo -e "${red}native-install.sh не найден: ${PROJECT_DIR}${plain}"
            exit 1
        fi
        exec bash "${PROJECT_DIR}/native-install.sh"
        ;;
    update)
        need_root
        if [ ! -f "${PROJECT_DIR}/native-update.sh" ]; then
            echo -e "${red}native-update.sh не найден: ${PROJECT_DIR}${plain}"
            exit 1
        fi
        exec bash "${PROJECT_DIR}/native-update.sh"
        ;;
    restart)
        need_root
        systemctl restart x-ui
        echo -e "${green}x-ui restarted${plain}"
        ;;
    url)
        panel_url
        ;;
    env)
        echo "/etc/x-ui/.env -> ${PROJECT_DIR}/.env"
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        echo -e "${red}Unknown command: $1${plain}"
        show_help
        exit 1
        ;;
esac
