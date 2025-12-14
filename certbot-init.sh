#!/bin/sh
# ============================================================================
# Скрипт автоматического получения/обновления SSL сертификатов
# Поддерживает отдельные домены для панели и подписки
# Включает проверку DNS перед выпуском сертификата
# ============================================================================

set -e

# Домены
PANEL_DOMAIN="${XUI_DOMAIN:-}"
SUB_DOMAIN="${XUI_SUB_DOMAIN:-}"
EMAIL="${XUI_ADMIN_EMAIL:-admin@$PANEL_DOMAIN}"

echo "🔐 SSL Auto-setup starting..."
echo "   Panel domain: $PANEL_DOMAIN"
echo "   Sub domain: ${SUB_DOMAIN:-same as panel}"
echo "   Email: $EMAIL"

# Функция проверки DNS
check_dns() {
    domain=$1
    if [ -z "$domain" ] || [ "$domain" = "localhost" ]; then
        return 0
    fi
    
    echo "🔍 Проверка DNS для $domain..."
    
    # Получаем IP сервера (IPv4)
    VPS_IP=$(wget -4 -qO- --timeout=5 ifconfig.me 2>/dev/null || wget -4 -qO- --timeout=5 api.ipify.org 2>/dev/null || echo "")
    if [ -z "$VPS_IP" ]; then
        echo "⚠️  Не удалось определить IP сервера, пропускаем проверку"
        return 0
    fi
    
    # Получаем A запись домена
    DOMAIN_IP=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
    if [ -z "$DOMAIN_IP" ]; then
        # Альтернативный метод через getent
        DOMAIN_IP=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    
    if [ -z "$DOMAIN_IP" ]; then
        echo "❌ DNS для $domain не найден!"
        echo "   Добавьте A запись: $domain -> $VPS_IP"
        return 1
    fi
    
    if [ "$DOMAIN_IP" = "$VPS_IP" ]; then
        echo "✅ DNS OK: $domain -> $VPS_IP"
        return 0
    else
        echo "❌ DNS не совпадает!"
        echo "   Домен указывает на: $DOMAIN_IP"
        echo "   IP сервера: $VPS_IP"
        echo "   Обновите A запись: $domain -> $VPS_IP"
        return 1
    fi
}

# Функция получения сертификата
get_cert() {
    domain=$1
    if [ -z "$domain" ] || [ "$domain" = "localhost" ]; then
        return 0
    fi
    
    cert_path="/etc/letsencrypt/live/$domain"
    
    if [ -d "$cert_path" ] && [ -f "$cert_path/fullchain.pem" ]; then
        echo "✅ Сертификат для $domain уже существует"
    else
        # Проверяем DNS перед выпуском
        if ! check_dns "$domain"; then
            echo "⚠️  Пропускаем выпуск сертификата для $domain (DNS не настроен)"
            return 1
        fi
        
        echo "📋 Получаем сертификат для $domain..."
        sleep 3
        
        certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$domain" \
            --preferred-challenges http \
            || echo "⚠️  Не удалось получить сертификат для $domain"
        
        if [ -f "$cert_path/fullchain.pem" ]; then
            echo "✅ Сертификат для $domain получен!"
        fi
    fi
}

# Проверяем домены
if [ -z "$PANEL_DOMAIN" ] || [ "$PANEL_DOMAIN" = "localhost" ]; then
    echo "⚠️  XUI_DOMAIN не указан или равен localhost"
    echo "   Переходим в режим обновления существующих сертификатов..."
else
    # Получаем сертификат для панели
    get_cert "$PANEL_DOMAIN"
    
    # Получаем сертификат для подписки (если отдельный домен)
    if [ -n "$SUB_DOMAIN" ] && [ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ]; then
        get_cert "$SUB_DOMAIN"
    fi
fi

# Цикл автообновления каждые 12 часов
echo "🔄 Запуск цикла автообновления (каждые 12 часов)..."
trap exit TERM
while :; do
    certbot renew --standalone --quiet || true
    sleep 12h &
    wait
done
