# 3x-ui с автоконфигурацией

Форк [3x-ui](https://github.com/MHSanaei/3x-ui) с поддержкой конфигурации через переменные окружения. Два варианта установки: **Docker** и **нативная** (systemd).

## Быстрый старт (Docker)

`.env` хранится в **корне проекта** рядом с `docker-compose.yml`.

```bash
cp .env.example .env
nano .env
sudo docker compose up -d --build
```

## Нативная установка (systemd, без Docker)

Меньше потребление памяти (~20-40 МБ vs ~60-100 МБ в Docker).
`.env` — **общий** для обоих вариантов (симлинк `/etc/x-ui/.env` → `.env` в проекте).

```bash
git clone https://github.com/Wasdalt/3x-ui.git && cd 3x-ui
cp .env.example .env        # опционально: можно оставить пустым и дать скрипту сгенерировать локальные значения
nano .env                   # опционально: домен, порт, логирование, админ и т.д.
sudo bash native-install.sh
```

Скрипт автоматически:
1. Устанавливает официальный 3x-ui, если он ещё не установлен.
2. Делает бэкап БД перед установкой/обновлением и восстанавливает его при ошибке.
3. Создаёт симлинк `/etc/x-ui/.env` → `.env` в проекте.
4. Настраивает systemd на чтение `.env` при каждом старте.
5. Запускает `init-config.sh` перед каждым стартом панели.
6. Копирует fork-обвязку в `/usr/local/x-ui/` и ставит единый CLI `x-ui-fork`.
7. Настраивает certbot + автообновление сертификатов через `certbot.timer` или cron fallback.

**Применение изменений `.env`:**
```bash
nano .env                        # редактируешь в проекте
sudo systemctl restart x-ui      # применяется автоматически
```

**Обновление (upstream 3x-ui + fork-слой):**
```bash
cd /path/to/3x-ui
sudo bash native-update.sh
```

**Единый CLI для upstream + fork:**
```bash
x-ui-fork menu        # открыть официальное меню автора (авто-sudo)
x-ui-fork apply       # применить fork-обвязку (.env/init-config/certbot)
x-ui-fork update      # обновить официальный 3x-ui и снова применить fork
x-ui-fork restart     # перезапустить systemd-сервис x-ui
x-ui-fork url         # показать актуальные URL панели и статус SSL
x-ui-fork env         # показать путь активного .env
```

> Поддерживаемые дистрибутивы: Debian/Ubuntu (`apt`), CentOS/RHEL/Alma/Rocky (`yum`), Alpine (`apk`), Arch Linux/EndeavourOS/Manjaro (`pacman`).
> Для обновлений используйте `x-ui-fork update` (или `sudo bash native-update.sh`), а не обычный `x-ui update`.

**Удаление .env-дополнений (оставляет 3x-ui):**
```bash
sudo bash native-uninstall.sh
```

## Основные переменные окружения

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_PORT` | Порт панели (HTTPS); если пусто и БД пустая, генерируется свободный порт `40000-59999` | авто/`2053` |
| `XUI_DOMAIN` | Домен панели для HTTPS. Если пусто, берётся только `webDomain` из БД | — |
| `XUI_ADMIN_EMAIL` | Email для Let's Encrypt. Если пусто, используется регистрация certbot без email | — |
| `XUI_BASE_PATH` | Базовый путь панели; если пусто и БД пустая, генерируется скрытый путь | авто/`/` |
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

1. При старте native-сервиса systemd читает `/etc/x-ui/.env`.
2. Перед запуском панели `/usr/local/x-ui/fork-sync.sh` подтягивает свежий fork-слой из проекта, если он доступен.
3. Затем выполняется `/usr/local/x-ui/init-config.sh`.
4. Скрипт применяет заданные переменные окружения в БД `/etc/x-ui/x-ui.db`.
5. `x-ui-fork-db-apply.path` следит за изменением `/etc/x-ui/x-ui.db` и запускает fork-применение после restore backup через панель/API.
6. Если `XUI_PORT` пустой и `webPort` в БД пустой, генерируется свободный порт и записывается только в БД.
7. Если `XUI_BASE_PATH` пустой и `webBasePath` в БД пустой, генерируется скрытый путь и записывается только в БД.
8. Если `XUI_DOMAIN` задан и отличается от `webDomain` из БД, сначала пробуется домен из `.env`.
9. Если `XUI_DOMAIN` пустой, домен берётся только из `webDomain` в БД.
10. Если домена нет ни в `.env`, ни в `webDomain`, SSL-сертификат не выпускается.
11. Если enabled inbound с TLS ссылается на отсутствующий сертификат, путь автоматически заменяется на сертификат `XUI_DOMAIN`.
12. Если `xrayTemplateConfig` не существует, он создаётся из `config.json`.
13. Применяются настройки логов Xray через `jq`.
14. Панель стартует с применёнными настройками.

Значения из `.env` имеют приоритет над БД. Если переменная не задана или закомментирована, сохраняется значение из БД.

## SSL сертификаты

Сертификаты Let's Encrypt получаются автоматически, если есть домен в `XUI_DOMAIN` или `webDomain` в БД.

Домен для панели берётся только из:
```text
XUI_DOMAIN -> webDomain
```

`subDomain` не используется как fallback для домена панели.

Сертификаты внутри inbound хранятся отдельно в `inbounds.stream_settings`. Fork автоматически исправляет только сломанные ссылки enabled inbound, когда `certificateFile` или `keyFile` не существуют на диске, а сертификат для `XUI_DOMAIN` уже есть. Чтобы отключить это поведение:
```env
XUI_SYNC_INBOUND_CERTS=false
```

Автоматика native-режима:
```text
systemctl restart x-ui / reboot
  -> fork-sync.sh
  -> init-config.sh

restore backup через панель/API или изменение /etc/x-ui/x-ui.db
  -> x-ui-fork-db-apply.path
  -> fork-db-apply.sh
  -> fork-sync.sh
  -> init-config.sh
```

`fork-db-apply.sh` использует debounce 20 секунд, чтобы собственные записи `init-config.sh` в БД не запускали бесконечный цикл. Переопределить можно через:
```env
XUI_FORK_DB_APPLY_DEBOUNCE=20
```

В native-режиме устанавливается deploy-hook:
```text
/etc/letsencrypt/renewal-hooks/deploy/restart-x-ui.sh
```

После успешного `certbot renew` hook отправляет **SIGHUP** процессу x-ui (in-process reload: ~1-2 сек вместо ~10 сек при полном restart). Xray и web-сервер перезагружаются, подхватывая новый сертификат. Если сервис не запущен — выполняется обычный `systemctl restart` как fallback.

Сертификат **не перевыпускается повторно**, если уже существует и действителен более 24 часов.

Автообновление работает через системный `certbot.timer`. Если timer недоступен, используется cron fallback с запуском `certbot renew --quiet` каждые 12 часов.

Docker-режим использует контейнер `certbot`, который запускает renew loop каждые 12 часов.

### Ручное получение (если автоматика не сработала)

```bash
sudo ./ssl-setup.sh yourdomain.com admin@yourdomain.com
sudo systemctl restart x-ui
```

## Доступ к панели

### Через домен (рекомендуется)
```
https://yourdomain.com:<webPort><webBasePath>
```

Текущий URL можно вывести из БД:
```bash
x-ui-fork url
```

### SSH туннель (без домена)
```bash
# На локальном компьютере
ssh -N -L 8080:localhost:<webPort> user@server-ip
```
Затем: `http://localhost:8080<webBasePath>`

### HTTP по IP (небезопасно!)
В `.env`:
```env
XUI_ALLOW_HTTP=true
```
Затем: `http://server-ip:<webPort><webBasePath>`

Если `.env` и БД пустые, native-установщик сгенерирует свободный `webPort` и скрытый `webBasePath`, а затем покажет URL в консоли.

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

### Docker

| Действие | Команда |
|---|---|
| Изменил `.env` | `sudo docker compose up -d --force-recreate` |
| Изменил скрипты | `sudo docker compose up -d --build` |
| Полный перезапуск | `sudo docker compose down && sudo docker compose up -d --build` |

### Нативная (systemd)

| Действие | Команда |
|---|---|
| Изменил `.env` | `sudo systemctl restart x-ui` |
| Обновил fork-скрипты | `sudo x-ui-fork apply` или `sudo bash native-apply.sh` |
| Обновить официальный 3x-ui + fork-слой | `sudo bash native-update.sh` или `sudo x-ui-fork update` |
| Показать URL панели | `x-ui-fork url` |

> **⚠️ Важно:**
> - Docker: `docker compose restart` **НЕ перечитывает** `.env` — используйте `up -d --force-recreate`
> - Значения из `.env` **имеют приоритет** над значениями в БД
> - Если переменная не задана или закомментирована — сохраняется значение из БД
> - Обычный `x-ui update` обновляет только авторскую часть; для сохранения fork-обвязки используйте `sudo x-ui-fork update`

## Полезные команды

### Docker

```bash
sudo docker logs 3xui_app -f                          # Логи
sudo docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db \
  "SELECT key, value FROM settings;"                   # Настройки в БД
```

### Нативная

```bash
sudo journalctl -u x-ui -f                            # Логи
sudo sqlite3 /etc/x-ui/x-ui.db \
  "SELECT key, value FROM settings;"                   # Настройки в БД
sudo systemctl status x-ui                             # Статус
x-ui-fork url                                          # URL панели
sudo bash native-update.sh                             # upstream update + fork overlay
sudo x-ui-fork update                                  # то же самое через CLI
```

## Очистка Docker

```bash
# Проверить что занимает место
sudo docker ps -a                                      # Контейнеры
sudo docker images                                     # Образы
sudo docker volume ls                                  # Тома

# Удалить неиспользуемые образы, контейнеры, тома
sudo docker system prune -a --volumes

# Удалить конкретный образ/том
sudo docker image rm ИМЯ_ОБРАЗА
sudo docker volume rm ИМЯ_ТОМА
```

> **⚠️ `prune -a --volumes`** удаляет **ВСЁ** неиспользуемое — образы, остановленные контейнеры, анонимные тома. Работающие контейнеры и их тома не затрагиваются.
