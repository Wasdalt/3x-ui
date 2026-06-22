#!/bin/sh
# Domain certificate helpers for native 3x-ui installs.

set -e

XUI_SERVICE_NAME="${XUI_SERVICE_NAME:-x-ui}"
XUI_CERTBOT_DEPLOY_HOOK="${XUI_CERTBOT_DEPLOY_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/restart-x-ui.sh}"

is_domain_name() {
    domain=$1

    [ -n "$domain" ] || return 1
    [ "$domain" != "localhost" ] || return 1

    case "$domain" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 1 ;;
    esac

    case "$domain" in
        *[!A-Za-z0-9.-]* | .* | *..* | *.) return 1 ;;
    esac

    case "$domain" in
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

is_placeholder_email() {
    email=$1

    [ -n "$email" ] || return 0

    case "$email" in
        *@example.com|*@example.org|*@example.net|admin@localhost|root@localhost) return 0 ;;
        *@*) return 1 ;;
        *) return 0 ;;
    esac
}

certbot_issue_domain_cert() {
    domain=$1
    email=${2:-}

    if ! is_domain_name "$domain"; then
        echo "[CERT] Domain is empty or invalid, skipping certificate issue"
        return 1
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        echo "[CERT] certbot not found, skipping certificate issue"
        return 1
    fi

    cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    if [ -f "$cert_path" ]; then
        if command -v openssl >/dev/null 2>&1 \
           && openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "[CERT] Certificate for ${domain} is valid — skipping issue"
            return 0
        fi

        echo "[CERT] Certificate for ${domain} is expired or expiring within 24 h — renewing"
        if certbot renew --cert-name "$domain" --quiet 2>/dev/null; then
            echo "[CERT] Certificate for ${domain} renewed successfully"
            return 0
        fi
        echo "[CERT] Renewal failed for ${domain}, attempting full reissue"
    fi

    echo "[CERT] Requesting Let's Encrypt certificate for ${domain}"

    if is_placeholder_email "$email"; then
        echo "[CERT] XUI_ADMIN_EMAIL is empty or placeholder, using registration without email"
        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email \
            -d "$domain" \
            --preferred-challenges http
    else
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "$email" --no-eff-email \
            -d "$domain" \
            --preferred-challenges http
    fi
}

certbot_install_xui_deploy_hook() {
    hook_path=${1:-$XUI_CERTBOT_DEPLOY_HOOK}
    service_name=${2:-$XUI_SERVICE_NAME}
    hook_dir=$(dirname "$hook_path")

    mkdir -p "$hook_dir"
    cat > "$hook_path" <<EOF
#!/bin/sh
# Reload x-ui after certificate renewal.
#
# We send SIGHUP to the running x-ui process instead of doing a full
# "systemctl restart". x-ui handles SIGHUP in-process (see main.go):
# it stops/restarts the web server, subscription server, and xray —
# without forking a new process or re-running ExecStartPre scripts.
# This cuts reload time from ~10 s down to ~1-2 s and minimises the
# window during which active proxy connections are dropped.
#
# Fallback: if the service is not running or the HUP fails for any
# reason, a regular restart is attempted so the new cert is always loaded.
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ${service_name} 2>/dev/null; then
        systemctl kill --kill-who=main -s HUP ${service_name} >/dev/null 2>&1 \
            || systemctl restart ${service_name} >/dev/null 2>&1 \
            || true
    else
        systemctl restart ${service_name} >/dev/null 2>&1 || true
    fi
fi
EOF
    chmod +x "$hook_path"
    echo "[CERT] Deploy hook installed: ${hook_path}"
}

certbot_configure_auto_renewal() {
    certbot_install_xui_deploy_hook "$XUI_CERTBOT_DEPLOY_HOOK" "$XUI_SERVICE_NAME"

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files certbot.timer 2>/dev/null | grep -q '^certbot\.timer'; then
        if systemctl enable --now certbot.timer >/dev/null 2>&1; then
            echo "[CERT] Auto-renewal enabled via certbot.timer"
            return 0
        fi
        echo "[CERT] certbot.timer exists but could not be enabled, trying cron"
    fi

    if command -v crontab >/dev/null 2>&1; then
        cron_marker="3x-ui certbot auto-renewal"
        cron_cmd="0 */12 * * * certbot renew --quiet # ${cron_marker}"
        (crontab -l 2>/dev/null | grep -v "$cron_marker" || true; echo "$cron_cmd") | crontab -
        echo "[CERT] Auto-renewal enabled via cron"
        return 0
    fi

    echo "[CERT] No systemd timer or cron found; auto-renewal was not configured"
    return 1
}
