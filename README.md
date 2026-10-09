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
nano .env                   # опционально: домен, порт, HAProxy, логирование и т.д.
sudo bash native-install.sh # интерактивный выбор версии (Enter для latest, или укажите vX.Y.Z)
# или быстрая установка конкретной версии:
# sudo bash native-install.sh v2.5.0
```

Скрипт автоматически:
1. Предлагает выбор версии официального 3x-ui (последняя стабильная, конкретный релиз или dev). Если 3x-ui уже установлен — определяет текущую версию и предлагает обновить/сменить или оставить.
2. Делает бэкап БД перед установкой/обновлением и восстанавливает его при ошибке.
3. Создаёт симлинк `/etc/x-ui/.env` → `.env` в проекте.
4. Настраивает systemd на чтение `.env` при каждом старте.
5. Запускает `init-config.sh` перед каждым стартом панели.
6. Разворачивает HAProxy для приёма всех Reality/TLS соединений на единый порт 443 и синхронизирует узлы в подписках.
7. Разворачивает SelfSteal (локальный Decoy веб-сервер) для защиты от активного зондирования ТСПУ на порту 443 с коллекцией реалистичных HTML5-сайтов.
8. Копирует fork-обвязку в `/usr/local/x-ui/` и ставит единый CLI `x-ui-fork`.
9. Настраивает certbot + автообновление сертификатов через `certbot.timer` или cron fallback.

## Обновление

### 1. Полное обновление (Официальный 3x-ui + Fork-обвязка)
Рекомендуется для получения новых версий 3x-ui, ядра Xray и всех улучшений fork:

```bash
cd ~/3x-ui
git pull
x-ui-fork update          # обновит официальный 3x-ui до latest
# или с указанием конкретной версии:
# x-ui-fork update v2.5.0
```
- Автоматически создаётся бэкап базы данных `/etc/x-ui/x-ui.db`.
- Устанавливается свежая (или указанная) версия 3x-ui и Xray от автора.
- Поверх автоматически накатывается fork-обвязка (`.env`, `init-config.sh`, HAProxy, хуки certbot).
- > 💡 **Подсказка:** Если установщик в процессе спросит `Choose SSL certificate setup method`, выберите **`4`** (*Skip SSL*), так как SSL настраивается автоматически через `.env` и Certbot.

---

### 2. Быстрое обновление только fork-слоя (1-2 секунды, без простоя)
Если нужно подтянуть только свежие скрипты, исправления и хуки из репозитория:

```bash
cd ~/3x-ui
git pull
x-ui-fork apply
```

---

### 3. Откат на конкретную версию автора (Downgrade)
```bash
x-ui-fork downgrade 2.4.3
```

---

## Единый CLI (`x-ui-fork`)

Команда `x-ui-fork` доступна глобально в системе и автоматически запрашивает `sudo` при необходимости:

```bash
x-ui-fork menu           # открыть официальное меню автора 3x-ui
x-ui-fork update [v]     # полное обновление (официальный 3x-ui + fork, опционально версия)
x-ui-fork apply          # быстро применить fork-обвязку (.env/init-config/certbot)
x-ui-fork downgrade [v]  # откат на конкретную версию (например, 2.4.3)
x-ui-fork restart        # перезапустить службу x-ui
x-ui-fork status         # статус служб x-ui и HAProxy
x-ui-fork log            # просмотр логов x-ui в реальном времени
x-ui-fork backup         # создать мгновенный бэкап базы данных
x-ui-fork haproxy        # статус HAProxy, конфиг и логи SNI в реальном времени
x-ui-fork url            # показать актуальные URL панели, статус SSL, логин и пароль
x-ui-fork env            # показать путь к активному .env
x-ui-fork help           # показать справку по всем командам
```

**Применение изменений `.env`:**
```bash
nano .env             # отредактировать в папке проекта
x-ui-fork restart     # перезапустить и применить
```

> **Поддерживаемые ОС:** Debian/Ubuntu (`apt`), CentOS/RHEL/Alma/Rocky/Fedora (`yum`/`dnf`), Alpine (`apk`), Arch Linux/EndeavourOS/Manjaro (`pacman`).
> Для удаления fork-обвязки (с сохранением 3x-ui): `sudo bash native-uninstall.sh`.

## HAProxy и SNI-маршрутизация на порт 443

В форке реализован встроенный реверс-прокси **HAProxy**, решающий задачу мультиплексирования трафика: **приём всех Reality и TLS подключений на единый внешний порт 443**.

### Как это устроено:
1. **Мультиплексирование на порту 443:**
   HAProxy слушает внешний порт `443` в режиме TCP-проксирования (`mode tcp`).
2. **Маршрутизация по SNI без расшифровки:**
   При входящем TLS-подключении HAProxy считывает поле SNI из `Client Hello` и прозрачно перенаправляет трафик на локальный порт соответствующего входящего подключения (inbound) Xray.
3. **Разные протоколы и независимые маскировки:**
   Каждый inbound в панели 3x-ui создаётся на отдельном внутреннем порту (например, Reality 1 на `10443` с маскировкой `nothing.tech`, Reality 2 на `20443` с маскировкой `speedtest.net`).
4. **Автоматический перенос существующих инбаундов:**
   Если в панели уже был инбаунд на 443 порту, `init-config.sh` автоматически переносит его на свободный внутренний порт (например, `10443`), освобождая порт 443 для HAProxy.
5. **Синхронизация узлов подписок (`hosts`):**
   При включённом HAProxy и заданном домене (`XUI_HAPROXY_DOMAIN` или `XUI_DOMAIN`), `init-config.sh` автоматически синхронизирует таблицу `hosts` в базе данных `x-ui.db`. Все локальные хосты заменяются на внешний домен сервера с портом `443`. При импорте подписки клиенты подключаются на порт 443, а маскировка SNI берётся из настроек инбаунда.
6. **Логирование подключений (`tcplog`):**
   Ведётся детальный журнал соединений (IP клиента, дата/время, выбранный бэкенд, запрошенный SNI).
7. **Пре-валидация конфигурации:**
   Перед каждым перезапуском конфиг проверяется (`haproxy -c -f`). В случае ошибок синтаксиса служба не прерывает работу панели.
8. **Управление и мониторинг:**
   Просмотреть статус, конфиг и свежие логи соединений можно одной командой:
   ```bash
   x-ui-fork haproxy
   ```

## SelfSteal: Сайт-заглушка (Decoy Site) и защита от Active Probing

Для защиты от систем цензуры, ТСПУ и активных сетевых сканеров (Active Probing) в форк интегрирована система **SelfSteal** (self-hosted Decoy-сайт, аналогично архитектуре Remnawave):

### Как это работает:
1. **Локальный защищённый веб-сервер (Nginx / Python fallback):**
   На локальном порту `127.0.0.1:10444` разворачивается изолированный веб-сервер Nginx (в нативном режиме или Docker `3x-decoy`), отдающий полноценный реалистичный веб-сайт по HTTPS с поддержкой TLS 1.2 / TLS 1.3 и HTTP/2.
2. **Маршрутизация в HAProxy (порт 443):**
   - Все запросы без SNI, прямые обращения по IP-адресу (`https://IP:443`) или запросы с неизвестными доменными именами автоматически направляются в Decoy Site.
   - Запросы к вашему основному домену (`XUI_HAPROXY_DOMAIN` / `XUI_DOMAIN`), если для него не настроен отдельный инбаунд, отдают сайт-заглушку.
3. **Использование в Reality inbounds (двойная маскировка):**
   Вместо использования внешних сайтов (которые могут заблокировать по IP или изменить TLS-отпечаток), в Reality инбаунде можно указать:
   - **Dest (Target):** `127.0.0.1:10444`
   - **Server Names (SNI):** ваш домен сервера или любой доверенный домен
   При сканировании ТСПУ запрос передаётся локальному веб-серверу Decoy, подтверждая подлинность работающего сайта!

### Встроенные шаблоны сайтов:
В комплекте поставляются 4 полностью готовых, современных, адаптивных шаблона (чистый HTML5/CSS, без внешних CDN для мгновенной отдачи):
- `tech` — Платформа облачной инфраструктуры и Edge Computing (по умолчанию)
- `converter` — Сервис онлайн-конвертации медиа и документов OmniConvert
- `blog` — Персональный блог системного инженера о распределённых сетях
- `corporate` — Корпоративный сайт консалтинговой IT-компании Apex Digital

### Управление через CLI:
```bash
x-ui-fork selfsteal templates              # Список доступных шаблонов
x-ui-fork selfsteal template converter     # Переключить сайт на конвертер
x-ui-fork selfsteal status                 # Проверить статус Decoy-сервера и локальный ответ
```

## Telegram WEB Proxy (Официальный WebView Bridge)

В форк интегрирована поддержка нового протокола **Telegram WEB Proxy** (экспериментальный транспорт 2026 года от команды Telegram Desktop и Android, репозиторий `telegramdesktop/tproxy-server`).

### Принцип работы:
* Telegram внутри клиента запускает изолированный **Android System WebView**, обращаясь к вашему HTTPS-домену.
* Трафик MTProto упаковывается в стандартные HTTP/2 и WebSocket потоки и передаётся в локальный релей `tproxy-server`, а затем в официальный `MTProxy`.
* Для ТСПУ, DPI и сетевых фильтров соединение выглядит как **100% легитимное посещение обычного веб-сайта через браузер** с валидными TLS-отпечатками.
* При открытии домена в обычном браузере `tproxy-server` автоматически перенаправляет пользователя на Decoy-сайт заглушки (SelfSteal).

### Развертывание:
```bash
# Развертывание и сборка официальных демонов mtproxy и tproxy-server:
sudo ./setup-telegram-webproxy.sh --domain tg.example.com

# Проверить статус и реквизиты подключения:
sudo ./setup-telegram-webproxy.sh --status
```

### Подключение в Telegram:
1. Перейдите в **Настройки → Данные и память → Прокси → Добавить прокси**.
2. Выберите тип: **WEB Proxy**.
3. Введите:
   * **Сервер:** `tg.example.com` (без схемы `https://` и путей)
   * **Ключ:** сгенерированный 16-байтный hex-ключ (32 символа).

## Основные переменные окружения

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_PANEL_VERSION` | Версия официального 3x-ui для установки/обновления (`latest`, `v2.5.0`, `dev`) | `latest` |
| `XUI_PORT` | Порт панели (HTTPS); если пусто и БД пустая, генерируется свободный порт `40000-59999` | авто/`2053` |
| `XUI_DOMAIN` | Домен панели для HTTPS. Если пусто, берётся только `webDomain` из БД | — |
| `XUI_ADMIN_EMAIL` | Email для Let's Encrypt. Если пусто, используется регистрация certbot без email | — |
| `XUI_BASE_PATH` | Базовый путь панели; если пусто и БД пустая, генерируется скрытый путь | авто/`/` |
| `XUI_ADMIN_USERNAME` | Логин администратора | — |
| `XUI_ADMIN_PASSWORD` | Пароль администратора | — |

### HAProxy и порт 443

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_HAPROXY_ENABLE` | Включить HAProxy и автомаршрутизацию Reality/TLS по SNI на порт 443 | `true` |
| `XUI_HAPROXY_DOMAIN` | Внешний домен сервера для клиентов и узлов подписки (например, `vpn.example.com`). Если пусто, используется `XUI_DOMAIN` или IP | — |

### SelfSteal (Сайт-заглушка)

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `XUI_SELFSTEAL_ENABLE` | Включить сайт-заглушку Decoy и маршрутизацию default fallback | `true` |
| `XUI_SELFSTEAL_PORT` | Локальный порт HTTPS веб-сервера Decoy (для Reality dest) | `10444` |
| `XUI_SELFSTEAL_TEMPLATE` | Активный шаблон сайта: `tech`, `converter`, `blog`, `corporate` | `tech` |
| `XUI_SELFSTEAL_DOMAIN` | Домен сайта-заглушки (если пусто, берётся `XUI_HAPROXY_DOMAIN` / `XUI_DOMAIN`) | — |

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
14. Если `XUI_HAPROXY_ENABLE=true`, генерируется конфиг `/etc/x-ui/haproxy.cfg`, при необходимости освобождается порт 443 с переносом инбаунда, синхронизируется таблица `hosts` базы данных для подписок, проверяется синтаксис конфига и запускается служба HAProxy.
15. Панель стартует с применёнными настройками.

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
x-ui-fork log                                          # Логи x-ui в реальном времени (journalctl)
x-ui-fork haproxy                                      # Статус, конфиг и логи HAProxy (порт 443)
x-ui-fork selfsteal status                             # Статус сайта-заглушки Decoy (порт 10444)
x-ui-fork selfsteal templates                          # Доступные шаблоны сайта (tech, converter, blog, corporate)
x-ui-fork selfsteal template <имя>                     # Переключить шаблон сайта-заглушки
x-ui-fork status                                       # Статус x-ui, HAProxy и Decoy
x-ui-fork url                                          # URL панели, логин, пароль
x-ui-fork backup                                       # Сделать бэкап базы данных
sudo bash native-update.sh [v]                         # upstream update + fork overlay (опционально версия)
sudo x-ui-fork update [v]                              # то же самое через CLI
sudo sqlite3 /etc/x-ui/x-ui.db \
  "SELECT key, value FROM settings;"                   # Настройки в БД
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
