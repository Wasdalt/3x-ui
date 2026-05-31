#!/bin/bash
# ============================================================================
# Скрипт для получения SSL сертификата Let's Encrypt
# Использование: sudo ./ssl-setup.sh yourdomain.com admin@yourdomain.com
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTBOT_HELPER="${SCRIPT_DIR}/certbot-domain.sh"

[ -f "$CERTBOT_HELPER" ] && . "$CERTBOT_HELPER"

DOMAIN=${1:-$XUI_DOMAIN}
EMAIL=${2:-admin@$DOMAIN}

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "localhost" ]; then
    echo "❌ Укажите домен: ./ssl-setup.sh yourdomain.com"
    echo "   Или задайте XUI_DOMAIN в .env"
    exit 1
fi

echo "🔐 Получение SSL сертификата для: $DOMAIN"
echo "📧 Email: $EMAIL"
echo ""

# Проверяем, не запущен ли уже сервис на порту 80
if command -v netstat >/dev/null 2>&1 && netstat -tuln | grep -q ':80 '; then
    echo "⚠️  Порт 80 занят. Остановите сервис или используйте --webroot"
    echo "   Пробуем с --standalone и --preferred-challenges http..."
fi

# Получаем сертификат
if command -v certbot_issue_domain_cert >/dev/null 2>&1; then
    if sudo XUI_CERTBOT_DOMAIN="$DOMAIN" XUI_CERTBOT_EMAIL="$EMAIL" XUI_CERTBOT_HELPER="$CERTBOT_HELPER" sh -c '. "$XUI_CERTBOT_HELPER"; certbot_issue_domain_cert "$XUI_CERTBOT_DOMAIN" "$XUI_CERTBOT_EMAIL"; certbot_configure_auto_renewal'; then
        CERT_OK=1
    else
        CERT_OK=0
    fi
elif sudo certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        -d "$DOMAIN" \
        --preferred-challenges http; then
    CERT_OK=1
else
    CERT_OK=0
fi

if [ "$CERT_OK" -eq 1 ]; then
    echo ""
    echo "✅ Сертификат успешно получен!"
    echo ""
    echo "📁 Файлы сертификата:"
    echo "   Сертификат: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    echo "   Ключ:       /etc/letsencrypt/live/$DOMAIN/privkey.pem"
    echo ""
    echo "📝 Обновите .env:"
    echo "   XUI_DOMAIN=$DOMAIN"
    echo "   XUI_CERT_FILE=/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    echo "   XUI_KEY_FILE=/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    echo ""
    echo "🚀 Затем перезапустите панель:"
    echo "   sudo systemctl restart x-ui"
    echo "   # или Docker: sudo docker compose up -d --build"
else
    echo "❌ Ошибка получения сертификата"
    exit 1
fi
