#!/bin/bash
# ============================================================================
# Проверка DNS настроек для 3x-ui
# Использование: ./check-dns.sh [domain]
# ============================================================================

# Берём домен из аргумента или из .env
if [ -n "$1" ]; then
    DOMAIN="$1"
elif [ -f ".env" ]; then
    DOMAIN=$(grep -E "^XUI_DOMAIN=" .env | cut -d= -f2)
fi

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "localhost" ]; then
    echo "❌ Укажите домен: ./check-dns.sh yourdomain.com"
    echo "   Или задайте XUI_DOMAIN в .env"
    exit 1
fi

echo "🔍 Проверка DNS для домена: $DOMAIN"
echo "================================================"

# Получение IP сервера (IPv4)
echo ""
echo "🌐 IP адрес вашего сервера:"
VPS_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null)
if [ -n "$VPS_IP" ]; then
    echo "   $VPS_IP"
else
    echo "   ❌ Не удалось определить IP"
    exit 1
fi

# Проверка A записи
echo ""
echo "📋 A запись для $DOMAIN:"
A_RECORD=$(dig +short $DOMAIN A 2>/dev/null | head -1)
if [ -n "$A_RECORD" ]; then
    echo "   Найдено: $A_RECORD"
    if [ "$A_RECORD" = "$VPS_IP" ]; then
        echo "   ✅ IP совпадает с вашим сервером"
        DNS_OK=true
    else
        echo "   ❌ IP НЕ совпадает с вашим сервером"
        echo "   ⚠️  Нужно обновить A запись на: $VPS_IP"
        DNS_OK=false
    fi
else
    echo "   ❌ A запись не найдена"
    echo "   ⚠️  Добавьте A запись: $DOMAIN -> $VPS_IP"
    DNS_OK=false
fi

# Проверка подписки (если указан XUI_SUB_DOMAIN)
if [ -f ".env" ]; then
    SUB_DOMAIN=$(grep -E "^XUI_SUB_DOMAIN=" .env | cut -d= -f2)
    if [ -n "$SUB_DOMAIN" ] && [ "$SUB_DOMAIN" != "$DOMAIN" ]; then
        echo ""
        echo "📋 A запись для подписки ($SUB_DOMAIN):"
        SUB_A=$(dig +short $SUB_DOMAIN A 2>/dev/null | head -1)
        if [ -n "$SUB_A" ]; then
            echo "   Найдено: $SUB_A"
            if [ "$SUB_A" = "$VPS_IP" ]; then
                echo "   ✅ IP совпадает"
            else
                echo "   ❌ IP НЕ совпадает"
                DNS_OK=false
            fi
        else
            echo "   ❌ A запись не найдена"
            DNS_OK=false
        fi
    fi
fi

# Результат
echo ""
echo "================================================"
if [ "$DNS_OK" = "true" ]; then
    echo "✅ DNS настроен правильно!"
    echo ""
    echo "Можете запускать:"
    echo "   sudo docker-compose up -d --build"
else
    echo "❌ DNS требует настройки"
    echo ""
    echo "💡 Рекомендации:"
    echo "   1. Добавьте A запись: $DOMAIN -> $VPS_IP"
    echo "   2. Подождите 5-15 минут для распространения DNS"
    echo "   3. Запустите этот скрипт снова"
fi
