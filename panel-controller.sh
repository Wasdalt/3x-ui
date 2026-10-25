#!/bin/bash
# Native opt-in controller wrapper. No broad init-config/apply/restart calls.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${XUI_ENV_FILE:-/etc/x-ui/.env}"
[ -r "$env_file" ] || env_file="${SCRIPT_DIR}/.env"
if [ -r "$env_file" ]; then
    set -a
    . "$env_file"
    set +a
fi
. "${SCRIPT_DIR}/fork-policy.sh"
unit=x-ui-panel-controller.service
worker="${SCRIPT_DIR}/panel-controller.py"
db="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
state="${XUI_PANEL_CONTROLLER_STATE_DIR:-/var/lib/x-ui-panel-controller}"

check_dependencies() {
    for tool in python3 bash nginx haproxy openssl curl ss; do
        command -v "$tool" >/dev/null || { echo "[ERROR] Controller requires ${tool}" >&2; return 1; }
    done
    [ -r "$worker" ] && [ -r "${SCRIPT_DIR}/hosts-tls-inherit.py" ] &&
    [ -r "${SCRIPT_DIR}/decoy/sni_routes.py" ] || { echo "[ERROR] Controller runtime incomplete; update the complete fork" >&2; return 1; }
    if fork_policy_enabled XUI_AUTO_DB_APPLY || fork_policy_enabled XUI_HOSTS_SYNC ||
       fork_policy_enabled XUI_REWRITE_INBOUNDS; then
        echo "[ERROR] Disable broad AUTO_DB_APPLY/HOSTS_SYNC/REWRITE_INBOUNDS before enabling managed reconciliation" >&2
        return 1
    fi
}

case "${1:-status}" in
    plan|once)
        check_dependencies
        args=(--db "$db" --state-dir "$state" --scripts-dir "$SCRIPT_DIR" --once)
        if [ "$1" = plan ]; then
            # Explicit read-only preview is allowed before the operator enables it.
            export XUI_PANEL_CONTROLLER_ENABLE=true
            args+=(--dry-run)
        elif [ "${XUI_PANEL_CONTROLLER_ENABLE:-}" != true ]; then
            echo "[SKIP] Requires XUI_PANEL_CONTROLLER_ENABLE=true"
            exit 0
        fi
        exec python3 "$worker" "${args[@]}"
        ;;
    install)
        [ "$(id -u)" -eq 0 ] && [ -d /run/systemd/system ] && [ ! -f /.dockerenv ] || {
            echo "[ERROR] Controller requires native root/systemd runtime" >&2; exit 1;
        }
        if [ "${XUI_PANEL_CONTROLLER_ENABLE:-}" != true ]; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            echo "[SKIP] Controller disabled; no database/service reconciliation performed"
            exit 0
        fi
        check_dependencies
        # No state/DB/service writes in the plan. Missing certificate is expected
        # here: the enabled controller will issue it only after ownership checks.
        python3 "$worker" --db "$db" --state-dir "$state" --scripts-dir "$SCRIPT_DIR" --dry-run
        for path in "$SCRIPT_DIR" "$env_file" "$db" "$state"; do
            [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo "[ERROR] Unit paths require absolute paths without whitespace" >&2; exit 1; }
        done
        cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=Reconcile managed panel Hosts, certificates and SNI routes
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${env_file}
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=$(command -v python3) ${worker} --db ${db} --state-dir ${state} --scripts-dir ${SCRIPT_DIR} --watch
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$unit" >/dev/null
        systemctl restart "$unit"
        echo "[OK] Controller enabled; only its own worker restarted. x-ui/Xray were not restarted"
        ;;
    status)
        systemctl status "$unit" --no-pager
        ;;
    log)
        journalctl -u "$unit" --no-pager -n 80
        ;;
    stop)
        echo "[ACTION] Stop only ${unit}; managed Hosts/certificates/router kept as configured"
        systemctl disable --now "$unit"
        ;;
    *) echo "Usage: $0 {plan|once|install|status|log|stop}" >&2; exit 1 ;;
esac
