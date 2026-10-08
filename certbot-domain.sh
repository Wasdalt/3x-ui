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

configure_certbot_cli_ini() {
    mkdir -p /etc/letsencrypt
    cli_ini="/etc/letsencrypt/cli.ini"
    if [ ! -f "$cli_ini" ]; then
        echo "http-01-port = 8088" > "$cli_ini" 2>/dev/null || true
    elif ! grep -q "^http-01-port" "$cli_ini" 2>/dev/null; then
        echo "http-01-port = 8088" >> "$cli_ini" 2>/dev/null || true
    fi
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

    configure_certbot_cli_ini

    cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    if [ -f "$cert_path" ]; then
        if command -v openssl >/dev/null 2>&1 \
           && openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "[CERT] Certificate for ${domain} is valid — skipping issue"
            return 0
        fi

        echo "[CERT] Certificate for ${domain} is expired or expiring within 24 h — renewing"
        if certbot renew --cert-name "$domain" --http-01-port 8088 --quiet 2>/dev/null || certbot renew --cert-name "$domain" --quiet 2>/dev/null; then
            echo "[CERT] Certificate for ${domain} renewed successfully"
            return 0
        fi
        echo "[CERT] Renewal failed for ${domain}, attempting full reissue"
    fi

    echo "[CERT] Requesting Let's Encrypt certificate for ${domain}"

    run_certbot_attempt() {
        _d=$1
        _em=$2
        _opt=$3

        if is_placeholder_email "$_em"; then
            certbot certonly --standalone --non-interactive --agree-tos \
                --register-unsafely-without-email \
                ${_opt} \
                -d "$_d" \
                --preferred-challenges http
        else
            certbot certonly --standalone --non-interactive --agree-tos \
                --email "$_em" --no-eff-email \
                ${_opt} \
                -d "$_d" \
                --preferred-challenges http
        fi
    }

    issued=0

    # 1. Check who is listening on port 80
    if ss -tlpn 2>/dev/null | grep -E ':80\s' | grep -q 'haproxy'; then
        echo "[CERT] HAProxy detected on port 80, attempting ACME via 127.0.0.1:8088"
        if run_certbot_attempt "$domain" "$email" "--http-01-port 8088"; then
            issued=1
        fi
    elif ss -tlpn 2>/dev/null | grep -qE ':80\s'; then
        # Port 80 is occupied by non-HAProxy service (e.g. system default nginx/apache).
        echo "[CERT] Port 80 is occupied by non-haproxy service, stopping it temporarily"
        systemctl stop nginx apache2 httpd 2>/dev/null || true
        sleep 1
        if run_certbot_attempt "$domain" "$email" "--http-01-port 80"; then
            issued=1
        fi
    else
        # Port 80 is free
        if run_certbot_attempt "$domain" "$email" "--http-01-port 80"; then
            issued=1
        fi
    fi

    # 2. Automatic fallback: if challenge on 8088 or first attempt failed, release port 80 and try directly
    if [ "$issued" -eq 0 ] && [ ! -f "$cert_path" ]; then
        echo "[CERT] First attempt failed. Falling back to direct port 80 standalone challenge..."
        systemctl stop haproxy nginx apache2 httpd 2>/dev/null || true
        sleep 1
        if run_certbot_attempt "$domain" "$email" "--http-01-port 80"; then
            issued=1
        fi
        # Restore haproxy if it was enabled
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled haproxy 2>/dev/null | grep -q 'enabled'; then
            systemctl start haproxy 2>/dev/null || true
        fi
    fi

    if [ "$issued" -eq 1 ] && [ -f "$cert_path" ]; then
        echo "[CERT] Successfully issued certificate for ${domain}"
        return 0
    else
        echo "[CERT-WARN] Failed to issue certificate for ${domain} (non-fatal)"
        return 1
    fi
}

certbot_install_xui_deploy_hook() {
    hook_path=${1:-$XUI_CERTBOT_DEPLOY_HOOK}
    service_name=${2:-$XUI_SERVICE_NAME}
    hook_dir=$(dirname "$hook_path")

    mkdir -p "$hook_dir"
    cat > "$hook_path" <<EOF
#!/bin/sh
# Reload x-ui and nginx after certificate renewal.
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
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
    configure_certbot_cli_ini
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
        cron_cmd="0 */12 * * * certbot renew --quiet --http-01-port 8088 # ${cron_marker}"
        (crontab -l 2>/dev/null | grep -v "$cron_marker" || true; echo "$cron_cmd") | crontab -
        echo "[CERT] Auto-renewal enabled via cron"
        return 0
    fi

    echo "[CERT] No systemd timer or cron found; auto-renewal was not configured"
    return 1
}
