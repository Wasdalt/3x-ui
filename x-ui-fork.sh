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
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"

resolve_project_dir() {
    # 1. Environment variable override
    if [ -n "${XUI_FORK_PROJECT_DIR:-}" ] && [ -f "${XUI_FORK_PROJECT_DIR}/native-apply.sh" ]; then
        echo "$XUI_FORK_PROJECT_DIR"
        return 0
    fi

    # 2. Saved project dir file
    if [ -f "$PROJECT_DIR_FILE" ]; then
        saved_dir=$(cat "$PROJECT_DIR_FILE" 2>/dev/null || echo "")
        if [ -n "$saved_dir" ] && [ -f "$saved_dir/native-apply.sh" ]; then
            echo "$saved_dir"
            return 0
        fi
    fi

    # 3. Follow symlink of current script
    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    self_dir="$(dirname "$self_path")"
    if [ -f "$self_dir/native-apply.sh" ]; then
        echo "$self_dir"
        return 0
    fi

    # 4. Current working directory
    if [ -f "$PWD/native-apply.sh" ]; then
        echo "$PWD"
        return 0
    fi

    # 5. Check common user directories
    for candidate in \
        "${SUDO_USER:+/home/$SUDO_USER/3x-ui}" \
        "${SUDO_USER:+/home/$SUDO_USER/project/3x-ui}" \
        "/home/usermain/3x-ui" \
        "/home/usermain/project/3x-ui" \
        "/root/3x-ui" \
        "$HOME/3x-ui"; do
        if [ -n "$candidate" ] && [ -f "$candidate/native-apply.sh" ]; then
            echo "$candidate"
            return 0
        fi
    done

    echo "/home/usermain/3x-ui"
}

PROJECT_DIR=$(resolve_project_dir)
if [ "$EUID" -eq 0 ] && [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/native-apply.sh" ]; then
    mkdir -p "/etc/x-ui"
    echo "$PROJECT_DIR" > "$PROJECT_DIR_FILE" 2>/dev/null || true
fi

need_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            exec sudo "$0" "$@"
        else
            echo -e "${red}Ошибка: запустите от root или через sudo${plain}"
            exit 1
        fi
    fi
}

panel_url() {
    if [ ! -f "$DB_PATH" ]; then
        echo "БД не найдена: $DB_PATH"
        return 1
    fi

    port=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    base_path=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webBasePath' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    domain=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webDomain' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")

    cert_file=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webCertFile' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    key_file=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webKeyFile' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")

    [ -n "$port" ] || port="2053"
    [ -n "$base_path" ] || base_path="/"

    local_ip=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n 1)
    [ -n "$local_ip" ] || local_ip=$(hostname -i 2>/dev/null | awk '{print $1}')

    if [ -n "$domain" ] && [ "$domain" != "localhost" ] && [ -n "$cert_file" ] && [ -n "$key_file" ] && [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        echo "Панель (HTTPS):        https://${domain}:${port}${base_path}"
        echo "Локально (туннель):    http://localhost:${port}${base_path}"
    elif [ -n "$domain" ] && [ "$domain" != "localhost" ]; then
        echo "Домен (без SSL):       http://${domain}:${port}${base_path}"
        echo "Локально на сервере:   http://localhost:${port}${base_path}"
        if [ -n "$local_ip" ] && [ "$local_ip" != "127.0.0.1" ]; then
            echo "По сети / через IP:    http://${local_ip}:${port}${base_path}"
        fi
        echo "⚠ Сертификат SSL для ${domain} не найден, HTTPS не активен"
    else
        echo "Локально на сервере:   http://localhost:${port}${base_path}"
        if [ -n "$local_ip" ] && [ "$local_ip" != "127.0.0.1" ]; then
            echo "По сети / через IP:    http://${local_ip}:${port}${base_path}"
        fi
        echo "SSH туннель:           ssh -N -L 8080:localhost:${port} user@server-ip"
        echo "Через туннель:         http://localhost:8080${base_path}"
    fi

    admin_user=$(sqlite3 "$DB_PATH" "SELECT username FROM users LIMIT 1;" 2>/dev/null || echo "")
    admin_pass=""
    api_token=""

    if [ -f "/etc/x-ui/install-result.env" ]; then
        if [ -z "$admin_user" ]; then
            admin_user=$(grep -iE "^(XUI_)?USERNAME=" "/etc/x-ui/install-result.env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        fi
        admin_pass=$(grep -iE "^(XUI_)?PASSWORD=" "/etc/x-ui/install-result.env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        api_token=$(grep -iE "^(XUI_)?(API_TOKEN|TOKEN)=" "/etc/x-ui/install-result.env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi

    if [ -z "$admin_pass" ] && [ -n "$XUI_ADMIN_PASSWORD" ]; then
        admin_pass="$XUI_ADMIN_PASSWORD"
    fi

    echo ""
    if [ -n "$admin_user" ]; then
        echo "👤 Логин:              ${admin_user}"
    fi
    if [ -n "$admin_pass" ]; then
        echo "🔑 Пароль:             ${admin_pass}"
    fi
    if [ -n "$api_token" ]; then
        echo "🎫 API Token:          ${api_token}"
    fi
    if [ -n "${XUI_SECRET_KEY:-}" ]; then
        echo "🛡️ Секретный ключ:     ${XUI_SECRET_KEY}"
    fi
}

show_help() {
    cat <<EOF
3x-ui fork unified CLI

Usage: x-ui-fork <command>

Commands:
  menu      Open official author x-ui menu
  apply     Apply fork overlay only (.env, init-config, systemd hooks)
  update    Update official 3x-ui, then reapply fork overlay
  downgrade Rollback official 3x-ui to specific version (e.g. 2.4.3)
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
        if [ -f "${PROJECT_DIR}/native-apply.sh" ]; then
            exec bash "${PROJECT_DIR}/native-apply.sh"
        fi
        if [ ! -f "${PROJECT_DIR}/native-install.sh" ]; then
            echo -e "${red}native-apply.sh/native-install.sh не найдены: ${PROJECT_DIR}${plain}"
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
    downgrade|rollback)
        need_root
        version="${2:-}"
        if [ -z "$version" ]; then
            read -r -p "Введите версию 3x-ui для отката (например: 2.4.3): " version
        fi
        version="${version#v}"
        if [ -z "$version" ]; then
            echo -e "${red}Версия не указана${plain}"
            exit 1
        fi
        echo -e "${yellow}Откат на официальную версию v${version}...${plain}"
        bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/v${version}/install.sh") "v${version}"
        if [ -f "${PROJECT_DIR}/native-apply.sh" ]; then
            exec bash "${PROJECT_DIR}/native-apply.sh"
        fi
        ;;
    restart)
        need_root
        systemctl restart x-ui
        echo -e "${green}x-ui restarted${plain}"
        ;;
    url)
        need_root
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
