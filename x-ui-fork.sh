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
    if [ -n "${XUI_FORK_PROJECT_DIR:-}" ] && [ -f "${XUI_FORK_PROJECT_DIR}/native-apply.sh" ]; then
        echo "$XUI_FORK_PROJECT_DIR"
        return 0
    fi

    if [ -f "$PROJECT_DIR_FILE" ]; then
        saved_dir=$(cat "$PROJECT_DIR_FILE" 2>/dev/null || echo "")
        if [ -n "$saved_dir" ] && [ -f "$saved_dir/native-apply.sh" ]; then
            echo "$saved_dir"
            return 0
        fi
    fi

    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    self_dir="$(dirname "$self_path")"
    if [ -f "$self_dir/native-apply.sh" ]; then
        echo "$self_dir"
        return 0
    fi

    if [ -f "$PWD/native-apply.sh" ]; then
        echo "$PWD"
        return 0
    fi

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

    if [ -n "$cert_file" ] && [ -n "$key_file" ] && [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        if [ "$cert_file" = "/etc/x-ui/fallback-web.crt" ]; then
            echo "Панель (HTTPS, IP):    https://${local_ip}:${port}${base_path}"
            echo "Локально (туннель):    http://localhost:${port}${base_path}"
            echo "⚠ Сертификат Let's Encrypt не выпущен — активен самоподписанный SSL на IP"
        elif [ -n "$domain" ] && [ "$domain" != "localhost" ]; then
            echo "Панель (HTTPS):        https://${domain}:${port}${base_path}"
            echo "Локально (туннель):    http://localhost:${port}${base_path}"
        else
            echo "Панель (HTTPS):        https://${local_ip}:${port}${base_path}"
            echo "Локально (туннель):    http://localhost:${port}${base_path}"
        fi
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
  update    Update official 3x-ui, then reapply fork overlay (optional: [version])
  downgrade Rollback official 3x-ui to specific version (e.g. 2.4.3)
  restart   Restart x-ui systemd service
  status    Show status of x-ui and HAProxy services
  log       Show live logs (journalctl / docker)
  backup    Create instant database backup
  restore   Restore database from backup file and apply configuration (optional: [file])
  haproxy   Show HAProxy container/service status, logs and config
  selfsteal Manage SelfSteal decoy website (status, templates, template <name>)
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
        exec bash "${PROJECT_DIR}/native-install.sh" "${2:-}"
        ;;
    update)
        need_root
        if [ ! -f "${PROJECT_DIR}/native-update.sh" ]; then
            echo -e "${red}native-update.sh не найден: ${PROJECT_DIR}${plain}"
            exit 1
        fi
        exec bash "${PROJECT_DIR}/native-update.sh" "${2:-}"
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
    status)
        need_root
        if command -v systemctl >/dev/null 2>&1; then
            echo -e "${green}=== Статус x-ui ===${plain}"
            systemctl status x-ui --no-pager || true
            echo ""
            if systemctl is-active --quiet haproxy 2>/dev/null; then
                echo -e "${green}=== Статус haproxy ===${plain}"
                systemctl status haproxy --no-pager || true
            fi
            if systemctl is-active --quiet x-ui-decoy 2>/dev/null; then
                echo ""
                echo -e "${green}=== Статус x-ui-decoy (SelfSteal) ===${plain}"
                systemctl status x-ui-decoy --no-pager || true
            fi
        elif command -v docker >/dev/null 2>&1; then
            docker ps -f name=3xui_app -f name=3x-haproxy -f name=3x-decoy
        fi
        ;;
    log|logs)
        need_root
        if command -v journalctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
            journalctl -u x-ui -f
        elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^3xui_app$"; then
            docker logs -f 3xui_app
        else
            journalctl -u x-ui -f 2>/dev/null || docker logs -f 3xui_app 2>/dev/null || echo "Служба не запущена"
        fi
        ;;
    backup)
        need_root
        if [ -f "$DB_PATH" ]; then
            backup_file="/etc/x-ui/x-ui_backup_$(date +%Y%m%d_%H%M%S).db"
            cp "$DB_PATH" "$backup_file"
            echo -e "${green}Бэкап базы данных успешно создан: ${backup_file}${plain}"
        else
            echo -e "${red}База данных не найдена: ${DB_PATH}${plain}"
            exit 1
        fi
        ;;
    restore)
        need_root
        backup_src="${2:-}"
        if [ -z "$backup_src" ]; then
            backup_src=$(ls -t /etc/x-ui/x-ui_backup_*.db /tmp/x-ui.db.backup.* 2>/dev/null | head -n 1 || true)
            if [ -z "$backup_src" ]; then
                echo -e "${red}Файл бэкапа не указан и не найден автоматически${plain}"
                echo -e "Использование: x-ui-fork restore <путь_к_файлу.db>"
                exit 1
            fi
            echo -e "Автоматически выбран последний бэкап: ${yellow}${backup_src}${plain}"
        fi
        if [ ! -f "$backup_src" ]; then
            echo -e "${red}Файл бэкапа не найден: ${backup_src}${plain}"
            exit 1
        fi
        if command -v sqlite3 >/dev/null 2>&1; then
            if ! sqlite3 "$backup_src" "PRAGMA integrity_check;" 2>/dev/null | grep -q "ok"; then
                echo -e "${red}Файл не является корректной базой данных SQLite: ${backup_src}${plain}"
                exit 1
            fi
        fi

        echo -e "${yellow}Восстановление базы данных из ${backup_src}...${plain}"
        systemctl stop x-ui 2>/dev/null || true
        cp -f "$backup_src" "$DB_PATH"
        chmod 644 "$DB_PATH"
        echo -e "${green}✓ База данных скопирована в ${DB_PATH}${plain}"

        init_script=""
        if [ -x "${PROJECT_DIR}/init-config.sh" ]; then
            init_script="${PROJECT_DIR}/init-config.sh"
        elif [ -x "/usr/local/x-ui/init-config.sh" ]; then
            init_script="/usr/local/x-ui/init-config.sh"
        fi
        if [ -n "$init_script" ]; then
            echo -e "${yellow}Применение конфигурации и выпуск сертификатов...${plain}"
            "$init_script" || true
        fi

        systemctl restart x-ui 2>/dev/null || true
        echo -e "${green}✓ x-ui перезапущен с восстановленной базой${plain}"
        echo ""
        panel_url
        ;;
    url)
        need_root
        panel_url
        ;;
    haproxy)
        need_root
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet haproxy 2>/dev/null; then
            echo -e "${green}=== Статус сервиса haproxy.service (systemd) ===${plain}"
            systemctl status haproxy --no-pager
            echo ""
            echo -e "${green}=== Последние логи haproxy (journalctl) ===${plain}"
            journalctl -u haproxy -n 25 --no-pager
            echo ""
            echo -e "${green}=== Конфигурация /etc/x-ui/haproxy.cfg ===${plain}"
            cat /etc/x-ui/haproxy.cfg 2>/dev/null || cat /etc/haproxy/haproxy.cfg 2>/dev/null || echo "Конфиг не найден"
        elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^3x-haproxy$"; then
            echo -e "${green}=== Статус контейнера 3x-haproxy (Docker) ===${plain}"
            docker ps -f name=3x-haproxy
            echo ""
            echo -e "${green}=== Последние логи HAProxy ===${plain}"
            docker logs --tail 25 3x-haproxy
            echo ""
            echo -e "${green}=== Конфигурация /etc/x-ui/haproxy.cfg ===${plain}"
            cat /etc/x-ui/haproxy.cfg 2>/dev/null || echo "Конфиг не найден"
        else
            echo -e "${yellow}HAProxy не запущен (ни как сервис systemd, ни в Docker)${plain}"
        fi
        ;;
    selfsteal|decoy)
        need_root
        decoy_script=""
        if [ -f "${PROJECT_DIR}/decoy-setup.sh" ]; then
            decoy_script="${PROJECT_DIR}/decoy-setup.sh"
        elif [ -f "/usr/local/x-ui/decoy-setup.sh" ]; then
            decoy_script="/usr/local/x-ui/decoy-setup.sh"
        fi
        if [ -n "$decoy_script" ] && [ -x "$decoy_script" ]; then
            shift
            exec "$decoy_script" "$@"
        else
            echo -e "${red}decoy-setup.sh не найден в ${PROJECT_DIR} или /usr/local/x-ui${plain}"
            exit 1
        fi
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
