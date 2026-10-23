#!/bin/bash
# Explicit L4 SNI router for native SelfSteal. No database mutations.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="$SCRIPT_DIR"
source "${SCRIPT_DIR}/decoy-setup.sh"
unit="x-ui-sni-router.service"
config="/etc/x-ui/sni-router.cfg"
renderer="${DECOY_ROOT}/sni_routes.py"

validate_router() {
    [ "$SELFSTEAL_MODE" = reality ] || { echo "[ERROR] SNI router requires XUI_SELFSTEAL_MODE=reality" >&2; return 1; }
    command -v python3 >/dev/null && command -v haproxy >/dev/null || {
        echo "[ERROR] Требуются python3 и haproxy" >&2; return 1;
    }
    validate_reality_config || return 1
    python3 "$renderer" --db "${XUI_DB_PATH:-${CONFIG_DIR}/x-ui.db}" \
        --ids "${XUI_SNI_ROUTER_INBOUNDS:-}" --fallback-port "$SELFSTEAL_PORT" --format domains > "$work/domains" || return 1
    local domain
    while IFS= read -r domain; do
        if ! printf '%s\n' "$REALITY_DOMAINS" | tr ' ' '\n' | grep -Fxiq "$domain"; then
            echo "[ERROR] SNI ${domain} не включён в HTTPS-имена SelfSteal. Добавьте его в XUI_SELFSTEAL_EXTRA_DOMAINS и SAN сертификата" >&2
            return 1
        fi
    done < "$work/domains"
    python3 "$renderer" --db "${XUI_DB_PATH:-${CONFIG_DIR}/x-ui.db}" \
        --ids "${XUI_SNI_ROUTER_INBOUNDS:-}" --fallback-port "$SELFSTEAL_PORT" --format config > "$work/router.cfg" || return 1
    haproxy -c -f "$work/router.cfg" || return 1
}

case "${1:-status}" in
    plan|apply)
        fork_allow XUI_SNI_ROUTER_ENABLE "Отдельный SNI-router на TCP443" || exit 0
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        validate_router
        python3 "$renderer" --db "${XUI_DB_PATH:-${CONFIG_DIR}/x-ui.db}" \
            --ids "${XUI_SNI_ROUTER_INBOUNDS:-}" --fallback-port "$SELFSTEAL_PORT" --format plan
        [ "$1" != plan ] || exit 0
        validate_reality_runtime
        # Test that each intended Xray backend is already listening and can
        # serve the correct trusted site for unauthenticated probes.
        python3 "$renderer" --db "${XUI_DB_PATH:-${CONFIG_DIR}/x-ui.db}" \
            --ids "${XUI_SNI_ROUTER_INBOUNDS:-}" --fallback-port "$SELFSTEAL_PORT" --check-backends
        python3 "$renderer" --db "${XUI_DB_PATH:-${CONFIG_DIR}/x-ui.db}" \
            --ids "${XUI_SNI_ROUTER_INBOUNDS:-}" --fallback-port "$SELFSTEAL_PORT" --format config > "$work/current.cfg"
        if ! cmp -s "$work/router.cfg" "$work/current.cfg"; then
            echo "[ERROR] Выбранные маршруты изменились во время проверки; повторите plan/apply после сохранения формы" >&2
            exit 1
        fi
        listeners=$(ss -H -ltnp '( sport = :443 )')
        was_active=0
        if systemctl is-active --quiet "$unit"; then
            was_active=1
            group=$(systemctl show --property=ControlGroup --value "$unit")
            pids=$(printf '%s\n' "$listeners" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
            [ -n "$group" ] && [ -n "$pids" ] || { echo "[ERROR] Не удалось определить владельца TCP443" >&2; exit 1; }
            for pid in $pids; do
                if ! awk -F: -v group="$group" '$3==group || index($3,group"/")==1 {found=1} END {exit !found}' "/proc/$pid/cgroup"; then
                    echo "[ERROR] TCP443 занят процессом вне управляемого router; службы не остановлены" >&2
                    exit 1
                fi
            done
        elif [ -n "$listeners" ]; then
            echo "[ERROR] TCP443 занят. Сначала загрузите БД с локальными портами и примените конфигурацию панели. Чужие процессы не останавливаются" >&2
            exit 1
        fi
        [ ! -f "$config" ] || cp -p "$config" "$work/old.cfg"
        [ ! -f "/etc/systemd/system/$unit" ] || cp -p "/etc/systemd/system/$unit" "$work/old.unit"
        install -m 0600 "$work/router.cfg" "$config"
        cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=3x-ui dedicated SNI passthrough router (no TLS termination)
After=network.target x-ui.service x-ui-decoy.service

[Service]
Type=simple
ExecStartPre=$(command -v haproxy) -c -f ${config}
ExecStart=$(command -v haproxy) -W -db -f ${config}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        if ! systemctl daemon-reload || ! systemctl restart "$unit" || ! systemctl is-active --quiet "$unit"; then
            echo "[ERROR] Router не запущен; восстанавливаю предыдущие файлы" >&2
            systemctl stop "$unit" || true
            if [ -f "$work/old.cfg" ]; then cp -p "$work/old.cfg" "$config"; else rm -f "$config"; fi
            if [ -f "$work/old.unit" ]; then cp -p "$work/old.unit" "/etc/systemd/system/$unit"; else rm -f "/etc/systemd/system/$unit"; fi
            systemctl daemon-reload || true
            [ "$was_active" -ne 1 ] || systemctl start "$unit" || true
            exit 1
        fi
        systemctl enable "$unit" >/dev/null
        echo "[OK] SNI-router запущен. БД/Hosts не менялись; x-ui и Nginx не перезапускались"
        ;;
    status)
        systemctl status "$unit" --no-pager
        ;;
    stop)
        echo "[ACTION] Явная остановка только ${unit}; входящие/БД не меняются"
        systemctl disable --now "$unit"
        ;;
    *) echo "Usage: $0 {plan|apply|status|stop}" >&2; exit 1 ;;
esac
