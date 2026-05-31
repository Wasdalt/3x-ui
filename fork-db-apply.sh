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

if [ -x "${XUI_DIR}/init-config.sh" ]; then
    "${XUI_DIR}/init-config.sh"
fi
