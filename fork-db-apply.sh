#!/bin/sh
# ============================================================================
# Apply fork DB/env configuration after x-ui database changes.
# Intended for backup restores performed through the running panel/API.
# ============================================================================

set -e

XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
XUI_CONFIG_DIR="${XUI_CONFIG_DIR:-/etc/x-ui}"
XUI_ENV_FILE="${XUI_ENV_FILE:-${XUI_CONFIG_DIR}/.env}"
XUI_XRAY_CONFIG="${XUI_XRAY_CONFIG:-${XUI_DIR}/bin/config.json}"
DEBOUNCE_SECONDS="${XUI_FORK_DB_APPLY_DEBOUNCE:-20}"
STAMP_FILE="/run/x-ui-fork-db-apply.last"
LOCK_DIR="/run/x-ui-fork-db-apply.lock"

now=$(date +%s)
last=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)

case "$last" in
    ''|*[!0-9]*) last=0 ;;
esac

if [ $((now - last)) -lt "$DEBOUNCE_SECONDS" ]; then
    echo "[FORK-DB-APPLY] Skip: debounce ${DEBOUNCE_SECONDS}s"
    exit 0
fi

SIG_FILE="/run/x-ui-fork-db-apply.sig"
DB_PATH="${XUI_DB_PATH:-${XUI_CONFIG_DIR}/x-ui.db}"

if [ -f "$DB_PATH" ] && command -v sqlite3 >/dev/null 2>&1; then
    current_sig=$(sqlite3 "$DB_PATH" "SELECT id, port, enable, stream_settings FROM inbounds ORDER BY id; SELECT key, value FROM settings WHERE key IN ('webPort','webDomain','webCertFile','webKeyFile','subDomain') ORDER BY key;" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
    last_sig=$(cat "$SIG_FILE" 2>/dev/null || echo "")

    # Skip if structure (inbounds and core settings) is unchanged (e.g. only traffic/stats updated)
    if [ -n "$current_sig" ] && [ -n "$last_sig" ] && [ "$current_sig" = "$last_sig" ]; then
        exit 0
    fi
    echo "$current_sig" > "$SIG_FILE" 2>/dev/null || true
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[FORK-DB-APPLY] Skip: already running"
    exit 0
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

echo "$now" > "$STAMP_FILE"

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

if [ -n "$current_inode" ] && [ "$current_inode" != "0" ]; then
    echo "$current_inode" > "$INODE_FILE" 2>/dev/null || true
fi
