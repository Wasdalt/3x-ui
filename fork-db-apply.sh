#!/bin/sh
# ============================================================================
# Apply fork DB/env configuration after x-ui database changes.
# Auto-syncs HAProxy routing and settings seamlessly on every panel change.
# ============================================================================

set -e

XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
XUI_CONFIG_DIR="${XUI_CONFIG_DIR:-/etc/x-ui}"
XUI_ENV_FILE="${XUI_ENV_FILE:-${XUI_CONFIG_DIR}/.env}"
XUI_XRAY_CONFIG="${XUI_XRAY_CONFIG:-${XUI_DIR}/bin/config.json}"
LOCK_FILE="/run/x-ui-fork-db-apply.lock"
SIG_FILE="/run/x-ui-fork-db-apply.sig"
DB_PATH="${XUI_DB_PATH:-${XUI_CONFIG_DIR}/x-ui.db}"

[ -f "$DB_PATH" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0

current_sig=$(sqlite3 "$DB_PATH" "SELECT id, port, enable, stream_settings FROM inbounds ORDER BY id; SELECT id, inbound_id, address, port, sni FROM hosts ORDER BY id; SELECT key, value FROM settings WHERE key IN ('webPort','webDomain','webCertFile','webKeyFile','subDomain') ORDER BY key;" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
last_sig=$(cat "$SIG_FILE" 2>/dev/null || echo "")

if [ -n "$current_sig" ] && [ -n "$last_sig" ] && [ "$current_sig" = "$last_sig" ]; then
    exit 0
fi

exec 200>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -n 200 || exit 0
fi

last_sig=$(cat "$SIG_FILE" 2>/dev/null || echo "")
if [ -n "$current_sig" ] && [ -n "$last_sig" ] && [ "$current_sig" = "$last_sig" ]; then
    exit 0
fi

sleep 1

current_sig=$(sqlite3 "$DB_PATH" "SELECT id, port, enable, stream_settings FROM inbounds ORDER BY id; SELECT id, inbound_id, address, port, sni FROM hosts ORDER BY id; SELECT key, value FROM settings WHERE key IN ('webPort','webDomain','webCertFile','webKeyFile','subDomain') ORDER BY key;" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
echo "$current_sig" > "$SIG_FILE" 2>/dev/null || true

if [ -x "${XUI_DIR}/fork-sync.sh" ]; then
    "${XUI_DIR}/fork-sync.sh" || true
fi

if [ -f "$XUI_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$XUI_ENV_FILE"
    set +a
fi

export XUI_XRAY_CONFIG
export XUI_SKIP_PKILL=true

if [ -x "${XUI_DIR}/init-config.sh" ]; then
    "${XUI_DIR}/init-config.sh" || echo "[FORK-DB-APPLY] init-config.sh exited non-zero (non-fatal)"
fi

new_sig=$(sqlite3 "$DB_PATH" "SELECT id, port, enable, stream_settings FROM inbounds ORDER BY id; SELECT id, inbound_id, address, port, sni FROM hosts ORDER BY id; SELECT key, value FROM settings WHERE key IN ('webPort','webDomain','webCertFile','webKeyFile','subDomain') ORDER BY key;" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
if [ -n "$new_sig" ]; then
    echo "$new_sig" > "$SIG_FILE" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
    echo "[FORK-DB-APPLY] Restarting x-ui to apply updated database configuration seamlessly..."
    systemctl restart x-ui || true
elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^3xui_app$"; then
    echo "[FORK-DB-APPLY] Restarting 3xui_app docker container..."
    docker restart 3xui_app || true
fi
