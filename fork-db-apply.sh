#!/bin/bash
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
DEBOUNCE_FILE="/run/x-ui-fork-db-apply.last"
WEB_SUB_SIG_FILE="/run/x-ui-fork-web-sub.sig"
DB_PATH="${XUI_DB_PATH:-${XUI_CONFIG_DIR}/x-ui.db}"

[ -f "$DB_PATH" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0

force_mode=0
if [ "$1" = "--force" ] || [ "$1" = "-f" ]; then
    force_mode=1
fi

if [ -x "${XUI_DIR}/fork-sync.sh" ]; then
    "${XUI_DIR}/fork-sync.sh" || true
fi

now=$(date +%s 2>/dev/null || echo 0)
last_run=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
if [ "$force_mode" -eq 0 ] && [ "$now" -gt 0 ] && [ "$last_run" -gt 0 ] && [ $((now - last_run)) -lt 3 ]; then
    sleep $((3 - (now - last_run)))
fi

calc_sig() {
    sqlite3 "$DB_PATH" "
SELECT id, port, enable, stream_settings FROM inbounds ORDER BY id;
SELECT id, inbound_id, address, port, sni FROM hosts ORDER BY id;
SELECT key, value FROM settings WHERE key IN (
  'webPort','webDomain','webCertFile','webKeyFile','webBasePath',
  'subPort','subDomain','subCertFile','subKeyFile','subEnable','subPath','subURI'
) ORDER BY key;
SELECT count(*) FROM users;
SELECT count(*) FROM inbounds;
SELECT count(*) FROM client_traffics;
" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo ""
}

calc_web_sub_sig() {
    sqlite3 "$DB_PATH" "
SELECT key, value FROM settings WHERE key IN (
  'webPort','webDomain','webCertFile','webKeyFile','webBasePath',
  'subPort','subDomain','subCertFile','subKeyFile','subEnable','subPath','subURI'
) ORDER BY key;
" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo ""
}

current_sig=$(calc_sig)
last_sig=$(cat "$SIG_FILE" 2>/dev/null || echo "")

if [ "$force_mode" -eq 0 ] && [ -n "$current_sig" ] && [ -n "$last_sig" ] && [ "$current_sig" = "$last_sig" ]; then
    exit 0
fi
echo "$now" > "$DEBOUNCE_FILE" 2>/dev/null || true

exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || exit 0
fi

last_sig=$(cat "$SIG_FILE" 2>/dev/null || echo "")
if [ "$force_mode" -eq 0 ] && [ -n "$current_sig" ] && [ -n "$last_sig" ] && [ "$current_sig" = "$last_sig" ]; then
    exit 0
fi

sleep 1

current_sig=$(calc_sig)
echo "$current_sig" > "$SIG_FILE" 2>/dev/null || true

last_web_sub=$(cat "$WEB_SUB_SIG_FILE" 2>/dev/null || echo "")

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

new_sig=$(calc_sig)
if [ -n "$new_sig" ]; then
    echo "$new_sig" > "$SIG_FILE" 2>/dev/null || true
fi

new_web_sub=$(calc_web_sub_sig)
if [ -n "$new_web_sub" ]; then
    echo "$new_web_sub" > "$WEB_SUB_SIG_FILE" 2>/dev/null || true
    # Если изменились параметры веб-панели или сервера подписки (порт, сертификаты, домен) — перезапускаем x-ui
    if [ "$new_web_sub" != "$last_web_sub" ]; then
        echo "[FORK-DB-APPLY] Web/Subscription settings changed, restarting x-ui service..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart x-ui 2>/dev/null || true
        fi
    fi
fi
