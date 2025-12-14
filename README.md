# 3x-ui Docker с автоконфигурацией

Этот форк добавляет поддержку конфигурации через переменные окружения.

## Быстрый старт

```bash
# 1. Создать .env из шаблона
cp .env.example .env

# 2. Отредактировать настройки
nano .env

# 3. Запустить
sudo docker-compose up -d --build
```

## Доступные переменные (.env)

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_PORT` | Порт панели | `2053` |
| `XUI_DOMAIN` | Домен (hostname) | `localhost` |
| `XUI_BASE_PATH` | Базовый путь | `/` |
| `XUI_CERT_FILE` | Путь к SSL сертификату | — |
| `XUI_KEY_FILE` | Путь к SSL ключу | — |
| `XUI_SUB_PORT` | Порт подписок | `2096` |
| `XUI_SUB_PATH` | Путь подписок | `/sub/` |
| `XUI_SESSION_TIMEOUT` | Таймаут сессии (сек) | `60` |
| `XUI_TG_ENABLE` | Telegram бот | `false` |
| `XUI_TG_TOKEN` | Токен бота | — |
| `XUI_TG_ADMIN_ID` | ID админа | — |
| `XUI_ENABLE_FAIL2BAN` | Fail2Ban | `true` |
| `XRAY_VMESS_AEAD_FORCED` | VMESS AEAD | `false` |

## Как это работает

1. При запуске контейнера выполняется `init-config.sh`
2. Скрипт читает переменные окружения из `.env`
3. Записывает их в базу данных панели `/etc/x-ui/x-ui.db`
4. Панель стартует с применёнными настройками

## SSL сертификаты

### Первоначальное получение сертификата

```bash
# Остановите контейнер (порт 80 нужен свободным)
sudo docker-compose down

# Получите сертификат
sudo ./ssl-setup.sh yourdomain.com admin@yourdomain.com

# Обновите .env с правильными путями
# Запустите контейнер
sudo docker-compose up -d --build
```

### Автоматическое обновление

Контейнер `certbot` автоматически проверяет и обновляет сертификаты каждые 12 часов.

После обновления сертификата перезапустите панель:
```bash
sudo docker-compose restart 3xui
```

## Полезные команды

```bash
# Перезапуск БЕЗ пересборки (быстро, если .env не менялся)
sudo docker-compose restart

# Перезапуск с применением изменений из .env (без пересборки образа)
sudo docker-compose down && sudo docker-compose up -d

# Полная пересборка (если менялись Dockerfile, скрипты)
sudo docker-compose down && sudo docker-compose up -d --build

# Просмотр логов
sudo docker logs 3xui_app -f

# Сброс базы данных (полный сброс настроек)
sudo rm -f db/x-ui.db && sudo docker-compose up -d --build
```

