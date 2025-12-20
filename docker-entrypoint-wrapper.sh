#!/bin/sh
# ============================================================================
# 3x-ui Docker Entrypoint Wrapper
# Runs init-config.sh after DB creation, then starts panel
# ============================================================================

set -e

# ============================================================================
# Fail2ban Setup / Настройка Fail2ban
# ============================================================================
if [ "${XUI_ENABLE_FAIL2BAN}" = "true" ]; then
    BANTIME="${XUI_FAIL2BAN_BANTIME:-30}"
    MAXRETRY="${XUI_FAIL2BAN_MAXRETRY:-2}"
    FINDTIME="${XUI_FAIL2BAN_FINDTIME:-32}"
    
    if [ "${XUI_IP_WEBHOOK_ENABLE}" = "true" ]; then
        LOGPATH="/var/log/3xipl-f2b.log"
        echo "🔒 Fail2ban (webhook mode): $LOGPATH"
    else
        LOGPATH="/var/log/3xipl.log"
        echo "🔒 Fail2ban (auto-ban mode)"
    fi
    
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d
    
    cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${LOGPATH}
maxretry=${MAXRETRY}
findtime=${FINDTIME}
bantime=${BANTIME}m
EOF

    cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*SRC\s*=\s*<ADDR>
ignoreregex =
EOF

    cat > /etc/fail2ban/action.d/3x-ipl.conf << 'EOF'
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<name>

actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'
actionban = <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>

[Init]
name = default
protocol = tcp
chain = INPUT
EOF

    touch /var/log/3xipl.log /var/log/3xipl-banned.log
    echo "✅ Fail2ban configured"
fi

# Start original entrypoint in background
/app/DockerEntrypoint.sh &
PID=$!

sleep 3

# Apply environment configuration
/app/init-config.sh

# ============================================================================
# Auto-request certificate if domain found but cert missing
# ============================================================================
if [ -z "$XUI_DOMAIN" ]; then
    DB_DOMAIN=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
    [ -n "$DB_DOMAIN" ] && XUI_DOMAIN="$DB_DOMAIN"
fi

if [ -n "$XUI_DOMAIN" ]; then
    CERT_PATH="/etc/letsencrypt/live/${XUI_DOMAIN}/fullchain.pem"
    if [ ! -f "$CERT_PATH" ]; then
        echo "[AUTO-CERT] No certificate for $XUI_DOMAIN, creating request flag"
        echo "$XUI_DOMAIN" > /etc/letsencrypt/request-cert.flag
    else
        echo "[SSL] Certificate: $CERT_PATH"
    fi
fi

# ============================================================================
# Print Panel URL
# ============================================================================
echo ""
echo "============================================================================"
echo "🚀 3X-UI Panel started!"
echo "============================================================================"
if [ -n "$XUI_DOMAIN" ]; then
    PORT="${XUI_PORT:-2053}"
    BASE_PATH="${XUI_BASE_PATH:-/}"
    echo "   📍 Panel: https://${XUI_DOMAIN}:${PORT}${BASE_PATH}"
    [ -n "$XUI_SUB_PORT" ] && echo "   📋 Subscription: https://${XUI_DOMAIN}:${XUI_SUB_PORT}${XUI_SUB_PATH:-/sub/}"
else
    echo "   📍 Panel: https://localhost:${XUI_PORT:-2053}/"
fi
echo "============================================================================"
echo ""

wait $PID
