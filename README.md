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

## Доступ к панели

### Вариант 1: Через домен (рекомендуется)
```
https://yourdomain.com:2053
```

### Вариант 2: SSH туннель (безопасный, без домена)
Если домен не настроен или нет SSL — можно получить доступ через SSH туннель:

```bash
# На вашем локальном компьютере
ssh -p 22 -i ~/.ssh/your_key -N -L 8080:localhost:2053 user@server-ip
```

Затем в браузере:
```
http://localhost:8080
```

> **Примечание:** Флаг `-N` создаёт только туннель без терминала.
> Для диагностики добавьте `-v` (verbose).

### Вариант 3: HTTP по IP (небезопасно!)
Только для первоначальной настройки! Трафик не шифруется.

В `.env`:
```env
XUI_ALLOW_HTTP=true
```

Затем:
```
http://server-ip:2053
```

## Защита IP лимитов

### Режим 1: Fail2ban (по умолчанию)
Автоматическая блокировка, работает сразу. Дополнительные контейнеры **не нужны**.

```env
XUI_ENABLE_FAIL2BAN=true
XUI_FAIL2BAN_BANTIME=30  # минуты
```

### Режим 2: Webhook + xray-iplimit-blocker
Отправляет нарушения на ваш API для принятия решения (ban/ignore/warn).

```env
XUI_IP_WEBHOOK_ENABLE=true
XUI_IP_WEBHOOK_URL=https://your-api.com/webhook
```

**Требует запуск с профилем:**
```bash
sudo docker-compose --profile iplimit up -d
```

> ⚠️ При `XUI_IP_WEBHOOK_ENABLE=true` Fail2ban передаёт управление xray-iplimit-blocker

## Применение изменений

### Изменил только `.env`:
```bash
sudo docker-compose down && sudo docker-compose up -d
```
> Пересборка не нужна! `init-config.sh` автоматически применит настройки к БД при старте.

### Изменил скрипты (`init-config.sh`, `docker-entrypoint-wrapper.sh`, `Dockerfile`):
```bash
sudo docker-compose down && sudo docker-compose build 3xui && sudo docker-compose up -d
```

### ⚠️ `restart` НЕ применяет `.env`:
```bash
# Это НЕ перечитает .env — только перезапустит процесс!
sudo docker-compose restart 3xui
```

## Полезные команды

```bash
# Просмотр логов
sudo docker logs 3xui_app -f

# Проверить применённые настройки в БД
sudo docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db "SELECT key, value FROM settings;"

# Сброс базы данных (полный сброс настроек)
sudo rm -f db/x-ui.db && sudo docker-compose down && sudo docker-compose up -d
```


## Обновление с оригинального репозитория

```bash
# Получить обновления из оригинала
git fetch upstream

# Слить изменения (ваши файлы НЕ перезапишутся)
git merge upstream/main

# Запушить в ваш форк
git push origin main

# Пересобрать контейнер
sudo docker-compose down && sudo docker-compose up -d --build
```

> **Примечание:** Благодаря `.gitattributes` с `merge=ours` ваши кастомные файлы 
> и удалённые файлы не будут затронуты при merge.
