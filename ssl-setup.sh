#!/bin/bash
# ============================================================================
# Скрипт для получения SSL сертификата Let's Encrypt
# Использование: sudo ./ssl-setup.sh yourdomain.com admin@yourdomain.com
# ============================================================================

set -e

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
if netstat -tuln | grep -q ':80 '; then
    echo "⚠️  Порт 80 занят. Остановите сервис или используйте --webroot"
    echo "   Пробуем с --standalone и --preferred-challenges http..."
fi

# Получаем сертификат
sudo certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN" \
    --preferred-challenges http

if [ $? -eq 0 ]; then
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
    echo "🚀 Затем перезапустите контейнер:"
    echo "   sudo docker-compose down && sudo docker-compose up -d --build"
else
    echo "❌ Ошибка получения сертификата"
    exit 1
fi
