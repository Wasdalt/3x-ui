# 3x-ui Docker с автоконфигурацией

Форк [3x-ui](https://github.com/MHSanaei/3x-ui) с поддержкой конфигурации через переменные окружения.

## Быстрый старт

```bash
# 1. Создать .env из шаблона
cp .env.example .env

# 2. Отредактировать настройки
nano .env

# 3. Запустить
sudo docker compose up -d --build
```

## Основные переменные окружения

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_PORT` | Порт панели (HTTPS) | `2053` |
| `XUI_DOMAIN` | Домен для SSL | — |
| `XUI_ADMIN_EMAIL` | Email для Let's Encrypt | — |
| `XUI_BASE_PATH` | Базовый путь панели | `/` |
| `XUI_ADMIN_USERNAME` | Логин администратора | — |
| `XUI_ADMIN_PASSWORD` | Пароль администратора | — |

### Подписка

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_SUB_PORT` | Порт подписок | `2096` |
| `XUI_SUB_PATH` | Путь подписок | `/sub/` |
| `XUI_SUB_ENABLE` | Включить подписки | `true` |

### Xray логирование

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_XRAY_ACCESS_LOG` | Путь к access log | `./access.log` |
| `XUI_XRAY_ERROR_LOG` | Путь к error log | — |
| `XUI_XRAY_LOG_LEVEL` | Уровень: debug/info/warning/error/none | `info` |

> **Важно:** Для работы torrent/iplimit блокировщиков нужен уровень `info` или `debug`.

### Безопасность

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_SESSION_TIMEOUT` | Таймаут сессии (минуты) | `60` |
| `XUI_SECRET_KEY` | Секретный ключ сессии | — |
| `XUI_ENABLE_FAIL2BAN` | Fail2Ban защита | `true` |

Полный список переменных см. в [.env.example](.env.example).

## Как это работает

1. При запуске контейнера выполняется `init-config.sh`
2. Скрипт читает переменные окружения и записывает их в БД `/etc/x-ui/x-ui.db`
3. Если `xrayTemplateConfig` не существует — создаётся из `config.json`
4. Применяются настройки логов Xray через jq
5. Панель стартует с применёнными настройками

## SSL сертификаты

Сертификаты Let's Encrypt получаются **автоматически** при запуске, если указан `XUI_DOMAIN` и `XUI_ADMIN_EMAIL`.

Контейнер `certbot` проверяет и обновляет сертификаты каждые 12 часов.

### Ручное получение (если автоматика не сработала)

```bash
sudo docker compose down
sudo ./ssl-setup.sh yourdomain.com admin@yourdomain.com
sudo docker compose up -d
```

## Доступ к панели

### Через домен (рекомендуется)
```
https://yourdomain.com:2053/
```

### SSH туннель (без домена)
```bash
# На локальном компьютере
ssh -N -L 8080:localhost:2053 user@server-ip
```
Затем: `http://localhost:8080`

### HTTP по IP (небезопасно!)
В `.env`:
```env
XUI_ALLOW_HTTP=true
```
Затем: `http://server-ip:2053`

## Защита IP лимитов

### Режим 1: Fail2ban (по умолчанию)
Автоматическая блокировка, работает сразу.

```env
XUI_ENABLE_FAIL2BAN=true
XUI_FAIL2BAN_BANTIME=30  # минуты
```

### Режим 2: Webhook + xray-iplimit-blocker
Отправляет нарушения на ваш API.

```env
XUI_ENABLE_FAIL2BAN=false
XUI_IP_WEBHOOK_ENABLE=true
XUI_IP_WEBHOOK_URL=https://your-api.com/webhook
```

**Запуск с профилем:**
```bash
sudo docker compose --profile iplimit up -d
```

## Блокировка торрентов

```bash
sudo docker compose --profile torrent up -d
```

Подробнее см. [xray-torrent-blocker/README.md](xray-torrent-blocker/README.md).

## Применение изменений

### Изменил только `.env`:
```bash
sudo docker compose down && sudo docker compose up -d
```

### Изменил скрипты:
```bash
sudo docker compose down && sudo docker compose build --build-arg CACHEBUST=$(date +%s) && sudo docker compose up -d
```

> **Примечание:** `docker compose restart` НЕ перечитывает `.env`!

## Полезные команды

```bash
# Логи
sudo docker logs 3xui_app -f

# Настройки в БД
sudo docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db "SELECT key, value FROM settings;"

# Xray log section
sudo docker exec 3xui_app cat /app/bin/config.json | jq .log

# Сброс БД
sudo rm -f db/x-ui.db && sudo docker compose down && sudo docker compose up -d
```

## Обновление

```bash
git fetch upstream
git merge upstream/main
git push origin main
sudo docker compose down && sudo docker compose up -d --build
```
