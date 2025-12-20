#!/bin/sh
# ============================================================================
# SSL Certificate Auto-setup / Автоматическая настройка SSL
# Supports separate domains for panel and subscription
# Includes DNS verification before certificate issue
# ============================================================================

set -e

PANEL_DOMAIN="${XUI_DOMAIN:-}"
SUB_DOMAIN="${XUI_SUB_DOMAIN:-}"
EMAIL="${XUI_ADMIN_EMAIL:-admin@$PANEL_DOMAIN}"

echo "🔐 SSL Auto-setup"
echo "   Panel: ${PANEL_DOMAIN:-not set}"
echo "   Sub: ${SUB_DOMAIN:-same as panel}"

check_dns() {
    domain=$1
    [ -z "$domain" ] || [ "$domain" = "localhost" ] && return 0
    
    echo "🔍 Checking DNS for $domain..."
    
    VPS_IP=$(wget -4 -qO- --timeout=5 ifconfig.me 2>/dev/null || wget -4 -qO- --timeout=5 api.ipify.org 2>/dev/null || echo "")
    [ -z "$VPS_IP" ] && echo "⚠️  Cannot detect server IP" && return 0
    
    DOMAIN_IP=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
    [ -z "$DOMAIN_IP" ] && DOMAIN_IP=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    
    if [ -z "$DOMAIN_IP" ]; then
        echo "❌ DNS not found for $domain"
        echo "   Add A record: $domain -> $VPS_IP"
        return 1
    fi
    
    if [ "$DOMAIN_IP" = "$VPS_IP" ]; then
        echo "✅ DNS OK: $domain -> $VPS_IP"
        return 0
    else
        echo "❌ DNS mismatch: $domain -> $DOMAIN_IP (server: $VPS_IP)"
        return 1
    fi
}

get_cert() {
    domain=$1
    [ -z "$domain" ] || [ "$domain" = "localhost" ] && return 0
    
    cert_path="/etc/letsencrypt/live/$domain"
    
    if [ -d "$cert_path" ] && [ -f "$cert_path/fullchain.pem" ]; then
        echo "✅ Certificate exists: $domain"
    else
        check_dns "$domain" || { echo "⚠️  Skipping $domain (DNS not configured)"; return 1; }
        
        echo "📋 Requesting certificate for $domain..."
        sleep 3
        
        certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$domain" \
            --preferred-challenges http \
            || echo "⚠️  Failed to get certificate for $domain"
        
        [ -f "$cert_path/fullchain.pem" ] && echo "✅ Certificate obtained: $domain"
    fi
}

if [ -z "$PANEL_DOMAIN" ] || [ "$PANEL_DOMAIN" = "localhost" ]; then
    echo "⚠️  XUI_DOMAIN not set"
    
    # Check for backup domain request flag
    if [ -f "/etc/letsencrypt/request-cert.flag" ]; then
        BACKUP_DOMAIN=$(cat /etc/letsencrypt/request-cert.flag)
        if [ -n "$BACKUP_DOMAIN" ]; then
            echo "📋 Certificate request from backup: $BACKUP_DOMAIN"
            EMAIL="${XUI_ADMIN_EMAIL:-admin@$BACKUP_DOMAIN}"
            get_cert "$BACKUP_DOMAIN"
            rm -f /etc/letsencrypt/request-cert.flag
        fi
    else
        echo "   Entering renewal-only mode..."
    fi
else
    get_cert "$PANEL_DOMAIN"
    [ -n "$SUB_DOMAIN" ] && [ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ] && get_cert "$SUB_DOMAIN"
fi

# Auto-renewal loop (every 12 hours)
echo "🔄 Starting renewal loop..."
trap exit TERM
while :; do
    certbot renew --standalone --quiet || true
    sleep 12h &
    wait
done
