#!/bin/bash
# ============================================================================
# Apply fork overlay only. Does not install or modify upstream 3x-ui files.
# ============================================================================

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}Ошибка: запустите скрипт от root${plain}" && exit 1

XUI_DIR="/usr/local/x-ui"
XUI_CONFIG_DIR="/etc/x-ui"
XUI_ENV_FILE="${XUI_CONFIG_DIR}/.env"
XUI_SERVICE="/etc/systemd/system/x-ui.service"
XUI_BUNDLED_SERVICE="${XUI_DIR}/x-ui.service"
XUI_FORK_CLI="/usr/bin/x-ui-fork"
XUI_FORK_PROJECT_FILE="${XUI_CONFIG_DIR}/fork-project-dir"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${green}============================================================================${plain}"
echo -e "${green}  Applying 3x-ui fork overlay${plain}"
echo -e "${green}============================================================================${plain}"

if [ ! -d "$XUI_DIR" ]; then
    echo -e "${red}${XUI_DIR} не найден. Сначала установите официальный 3x-ui.${plain}"
    exit 1
fi

mkdir -p "$XUI_CONFIG_DIR" "${XUI_DIR}/xray-logs"

cp -f "${SCRIPT_DIR}/init-config.sh" "${XUI_DIR}/init-config.sh"
chmod +x "${XUI_DIR}/init-config.sh"
echo -e "${green}  ✓ init-config.sh обновлён${plain}"

if [ -f "${SCRIPT_DIR}/fork-sync.sh" ]; then
    cp -f "${SCRIPT_DIR}/fork-sync.sh" "${XUI_DIR}/fork-sync.sh"
    chmod +x "${XUI_DIR}/fork-sync.sh"
    echo -e "${green}  ✓ fork-sync.sh обновлён${plain}"
fi

if [ -f "${SCRIPT_DIR}/fork-db-apply.sh" ]; then
    cp -f "${SCRIPT_DIR}/fork-db-apply.sh" "${XUI_DIR}/fork-db-apply.sh"
    chmod +x "${XUI_DIR}/fork-db-apply.sh"
    echo -e "${green}  ✓ fork-db-apply.sh обновлён${plain}"
fi

if [ -f "${SCRIPT_DIR}/certbot-domain.sh" ]; then
    cp -f "${SCRIPT_DIR}/certbot-domain.sh" "${XUI_DIR}/certbot-domain.sh"
    chmod +x "${XUI_DIR}/certbot-domain.sh"
    echo -e "${green}  ✓ certbot-domain.sh обновлён${plain}"
fi

if [ -f "${SCRIPT_DIR}/x-ui-fork.sh" ]; then
    cp -f "${SCRIPT_DIR}/x-ui-fork.sh" "$XUI_FORK_CLI"
    chmod +x "$XUI_FORK_CLI"
    echo "$SCRIPT_DIR" > "$XUI_FORK_PROJECT_FILE"
    echo -e "${green}  ✓ x-ui-fork обновлён${plain}"
fi

if [ -f "${SCRIPT_DIR}/.env" ]; then
    ln -sf "${SCRIPT_DIR}/.env" "$XUI_ENV_FILE"
    echo -e "${green}  ✓ ${XUI_ENV_FILE} → ${SCRIPT_DIR}/.env${plain}"
elif [ ! -f "$XUI_ENV_FILE" ]; then
    echo -e "${yellow}  ⚠ .env не найден: ${SCRIPT_DIR}/.env${plain}"
fi

if [ ! -f "$XUI_SERVICE" ]; then
    if [ -f "$XUI_BUNDLED_SERVICE" ]; then
        cp "$XUI_BUNDLED_SERVICE" "$XUI_SERVICE"
        echo -e "${green}  ✓ systemd service создан из ${XUI_BUNDLED_SERVICE}${plain}"
    else
        echo -e "${red}${XUI_SERVICE} не найден${plain}"
        exit 1
    fi
fi

if [ ! -f "${XUI_SERVICE}.bak" ]; then
    cp "$XUI_SERVICE" "${XUI_SERVICE}.bak"
fi

if ! grep -q "${XUI_ENV_FILE}" "$XUI_SERVICE"; then
    sed -i "/\[Service\]/a EnvironmentFile=-${XUI_ENV_FILE}" "$XUI_SERVICE"
    echo -e "${green}  ✓ EnvironmentFile добавлен${plain}"
fi

if ! grep -q "XUI_XRAY_CONFIG" "$XUI_SERVICE"; then
    if grep -q "EnvironmentFile" "$XUI_SERVICE"; then
        sed -i "/EnvironmentFile/a Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json" "$XUI_SERVICE"
    else
        sed -i "/\[Service\]/a Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json" "$XUI_SERVICE"
    fi
    echo -e "${green}  ✓ XUI_XRAY_CONFIG добавлен${plain}"
fi

if ! grep -q "init-config.sh" "$XUI_SERVICE"; then
    sed -i "/^ExecStart=/i ExecStartPre=${XUI_DIR}/init-config.sh" "$XUI_SERVICE"
    echo -e "${green}  ✓ ExecStartPre добавлен${plain}"
fi

if [ -f "${XUI_DIR}/fork-sync.sh" ] && ! grep -q "${XUI_DIR}/fork-sync.sh" "$XUI_SERVICE"; then
    if grep -q "^ExecStartPre=.*init-config.sh" "$XUI_SERVICE"; then
        sed -i "\|^ExecStartPre=.*init-config.sh|i ExecStartPre=${XUI_DIR}/fork-sync.sh" "$XUI_SERVICE"
    else
        sed -i "/^ExecStart=/i ExecStartPre=${XUI_DIR}/fork-sync.sh" "$XUI_SERVICE"
    fi
    echo -e "${green}  ✓ Fork sync ExecStartPre добавлен${plain}"
fi

systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1 || true
echo -e "${green}  ✓ x-ui autostart enabled${plain}"

if [ -x "${XUI_DIR}/fork-db-apply.sh" ]; then
    cat > /etc/systemd/system/x-ui-fork-db-apply.service <<EOF
[Unit]
Description=Apply x-ui fork DB/env configuration
After=x-ui.service

[Service]
Type=oneshot
EnvironmentFile=-${XUI_ENV_FILE}
Environment=XUI_XRAY_CONFIG=${XUI_DIR}/bin/config.json
ExecStart=${XUI_DIR}/fork-db-apply.sh
EOF

    cat > /etc/systemd/system/x-ui-fork-db-apply.path <<EOF
[Unit]
Description=Watch x-ui database changes for fork configuration

[Path]
PathChanged=${XUI_CONFIG_DIR}/x-ui.db
Unit=x-ui-fork-db-apply.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now x-ui-fork-db-apply.path >/dev/null 2>&1 || true
    echo -e "${green}  ✓ DB apply path enabled${plain}"
fi

if [ -f "$XUI_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$XUI_ENV_FILE"
    set +a
fi

export XUI_XRAY_CONFIG="${XUI_XRAY_CONFIG:-${XUI_DIR}/bin/config.json}"
"${XUI_DIR}/init-config.sh"

systemctl restart x-ui

echo -e "${green}  ✓ fork overlay applied${plain}"
