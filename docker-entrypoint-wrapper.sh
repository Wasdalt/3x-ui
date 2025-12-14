#!/bin/sh
# ============================================================================
# Wrapper entrypoint для 3x-ui
# Запускает init-config.sh после создания БД, затем стартует панель
# ============================================================================

set -e

# ============================================================================
# Настройка Fail2ban (если включен)
# ============================================================================
if [ "${XUI_ENABLE_FAIL2BAN}" = "true" ]; then
    BANTIME="${XUI_FAIL2BAN_BANTIME:-30}"
    MAXRETRY="${XUI_FAIL2BAN_MAXRETRY:-2}"
    FINDTIME="${XUI_FAIL2BAN_FINDTIME:-32}"
    
    echo "🔒 Configuring Fail2ban..."
    echo "   BanTime: ${BANTIME}m, MaxRetry: ${MAXRETRY}, FindTime: ${FINDTIME}s"
    
    # Создаём директории если нет
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d
    
    # Создаём jail конфигурацию
    cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=/var/log/3xipl.log
maxretry=${MAXRETRY}
findtime=${FINDTIME}
bantime=${BANTIME}m
EOF

    # Создаём filter
    cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*SRC\s*=\s*<ADDR>
ignoreregex =
EOF

    # Создаём action
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

    # Создаём лог файлы если нет
    touch /var/log/3xipl.log /var/log/3xipl-banned.log
    
    echo "✅ Fail2ban configured"
fi

# Запускаем оригинальный entrypoint в фоне
/app/DockerEntrypoint.sh &
PID=$!

# Ждём немного чтобы БД создалась
sleep 3

# Применяем конфигурацию из переменных окружения
/app/init-config.sh

# Ждём основной процесс
wait $PID
