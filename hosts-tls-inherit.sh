#!/bin/bash
# Dedicated live inheritance: never call init-config or restart x-ui/Xray here.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XUI_ENV_FILE="${XUI_ENV_FILE:-/etc/x-ui/.env}"
if [ -r "$XUI_ENV_FILE" ]; then
    set -a
    . "$XUI_ENV_FILE"
    set +a
elif [ -r "${SCRIPT_DIR}/.env" ]; then
    XUI_ENV_FILE="${SCRIPT_DIR}/.env"
    set -a
    . "${SCRIPT_DIR}/.env"
    set +a
fi
. "${SCRIPT_DIR}/fork-policy.sh"
worker="${SCRIPT_DIR}/hosts-tls-inherit.py"
unit="x-ui-hosts-tls-inherit.service"

case "${1:-status}" in
    plan|once)
        if ! fork_allow XUI_HOSTS_INHERIT_TLS "Наследование fingerprint/ALPN входящего в Hosts"; then exit 0; fi
        command -v python3 >/dev/null || { echo "[ERROR] Требуется python3" >&2; exit 1; }
        args=(--db "${XUI_DB_PATH:-/etc/x-ui/x-ui.db}")
        [ "$1" != plan ] || args+=(--dry-run)
        exec python3 "$worker" "${args[@]}"
        ;;
    install)
        [ "$(id -u)" -eq 0 ] && [ -d /run/systemd/system ] || {
            echo "[ERROR] Live inheritance requires a native systemd install and root" >&2; exit 1;
        }
        if ! fork_allow XUI_HOSTS_INHERIT_TLS "Отдельный watcher наследования TLS-полей"; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            exit 0
        fi
        command -v python3 >/dev/null || { echo "[ERROR] Требуется python3" >&2; exit 1; }
        [ -r "$worker" ] || { echo "[ERROR] hosts-tls-inherit.py отсутствует" >&2; exit 1; }
        # Validate IDs and DB schema before replacing/starting the unit.
        python3 "$worker" --db "${XUI_DB_PATH:-/etc/x-ui/x-ui.db}" --dry-run
        cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=Inherit explicit fingerprint and ALPN into Hosts without restarting Xray
After=x-ui.service

[Service]
Type=simple
EnvironmentFile=-${XUI_ENV_FILE}
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=$(command -v python3) ${worker} --watch
Restart=on-failure
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$unit" >/dev/null
        systemctl restart "$unit"
        echo "[OK] Live inheritance enabled (~1s); only this worker restarted, not x-ui/Xray"
        ;;
    status)
        systemctl status "$unit" --no-pager
        ;;
    *) echo "Usage: $0 {plan|once|install|status}" >&2; exit 1 ;;
esac
