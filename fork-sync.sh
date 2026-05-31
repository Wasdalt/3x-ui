#!/bin/sh
# ============================================================================
# Sync fork runtime files before x-ui starts. Best-effort and non-destructive.
# ============================================================================

set -e

XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
XUI_CONFIG_DIR="${XUI_CONFIG_DIR:-/etc/x-ui}"
PROJECT_DIR_FILE="${XUI_FORK_PROJECT_DIR_FILE:-${XUI_CONFIG_DIR}/fork-project-dir}"
PROJECT_DIR="${XUI_FORK_PROJECT_DIR:-}"

if [ -z "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR_FILE" ]; then
    PROJECT_DIR=$(cat "$PROJECT_DIR_FILE")
fi

[ -n "$PROJECT_DIR" ] || exit 0
[ -d "$PROJECT_DIR" ] || exit 0
[ -d "$XUI_DIR" ] || exit 0

sync_shell_file() {
    source_file=$1
    target_file=$2

    [ -f "$source_file" ] || return 0

    if ! sh -n "$source_file" >/dev/null 2>&1; then
        echo "[FORK-SYNC] Skip invalid shell file: $source_file"
        return 0
    fi

    cp -f "$source_file" "$target_file"
    chmod +x "$target_file"
    echo "[FORK-SYNC] Synced $(basename "$target_file")"
}

sync_shell_file "${PROJECT_DIR}/init-config.sh" "${XUI_DIR}/init-config.sh"
sync_shell_file "${PROJECT_DIR}/certbot-domain.sh" "${XUI_DIR}/certbot-domain.sh"
