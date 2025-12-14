# Расширенная документация 3x-ui

## Маршрутизация (Routing)

### Базовая структура

```json
"routing": {
  "domainStrategy": "AsIs",  // или "IPIfNonMatch", "IPOnDemand"
  "rules": [
    {
      "type": "field",
      "outboundTag": "direct",
      // условия...
    }
  ]
}
```

### Outbounds (исходящие подключения)

| Tag | Протокол | Назначение |
|-----|----------|------------|
| `direct` | freedom | Напрямую в интернет |
| `blocked` | blackhole | Заблокировать |
| `proxy` | vmess/vless/etc | Через прокси |

### Условия правил

| Поле | Описание | Примеры |
|------|----------|---------|
| `ip` | IP адреса | `geoip:ru`, `geoip:private`, `10.0.0.0/8` |
| `domain` | Домены | `geosite:google`, `domain:example.com`, `full:www.example.com` |
| `protocol` | Протоколы | `http`, `tls`, `bittorrent` |
| `port` | Порты | `80,443`, `1000-2000` |
| `network` | Сеть | `tcp`, `udp`, `tcp,udp` |
| `source` | Источник IP | `10.0.0.1` |
| `user` | Email пользователя | `user@example.com` |
| `inboundTag` | Тег входящего | `["vless-in"]` |

### Примеры правил

#### Блокировать торренты
```json
{
  "type": "field",
  "outboundTag": "blocked",
  "protocol": ["bittorrent"]
}
```

#### Блокировать Россию
```json
{
  "type": "field",
  "outboundTag": "blocked",
  "ip": ["geoip:ru"]
}
```

#### Прямой доступ к локальным IP
```json
{
  "type": "field",
  "outboundTag": "direct",
  "ip": ["geoip:private", "127.0.0.1"]
}
```

#### Блокировать рекламу
```json
{
  "type": "field",
  "outboundTag": "blocked",
  "domain": ["geosite:category-ads-all"]
}
```

---

## База данных (таблицы)

### Схема БД

```
/etc/x-ui/x-ui.db (SQLite)
├── settings      ← Настройки панели (SETTINGS.md)
├── users         ← Администраторы
├── inbounds      ← Входящие подключения
├── clients       ← VPN клиенты
├── client_traffics  ← Статистика трафика
└── inbound_client_ips  ← IP клиентов
```

### Таблица `users`

| Поле | Тип | Описание |
|------|-----|----------|
| `id` | int | ID |
| `username` | string | Логин |
| `password` | string | Хеш пароля |
| `login_secret` | string | Секрет 2FA |

### Таблица `inbounds`

| Поле | Тип | Описание |
|------|-----|----------|
| `id` | int | ID |
| `user_id` | int | ID админа |
| `up` | int64 | Входящий трафик (байты) |
| `down` | int64 | Исходящий трафик (байты) |
| `total` | int64 | Лимит трафика |
| `remark` | string | Название |
| `enable` | bool | Активен |
| `expiry_time` | int64 | Время истечения (unix ms) |
| `listen` | string | IP прослушивания |
| `port` | int | Порт |
| `protocol` | string | vmess/vless/trojan/shadowsocks |
| `settings` | json | Настройки протокола |
| `stream_settings` | json | Настройки транспорта |
| `tag` | string | Тег |
| `sniffing` | json | Sniffing настройки |
| `allocate` | json | Allocate настройки |

### Таблица `client_traffics`

| Поле | Тип | Описание |
|------|-----|----------|
| `id` | int | ID |
| `inbound_id` | int | ID inbound |
| `enable` | bool | Активен |
| `email` | string | Email клиента |
| `up` | int64 | Входящий трафик |
| `down` | int64 | Исходящий трафик |
| `expiry_time` | int64 | Время истечения |
| `total` | int64 | Лимит трафика |
| `reset` | int | Период сброса (дни) |

---

## Управление через API

### Endpoints

| Метод | Путь | Описание |
|-------|------|----------|
| POST | `/login` | Авторизация |
| GET | `/panel/api/inbounds/list` | Список inbounds |
| POST | `/panel/api/inbounds/add` | Создать inbound |
| POST | `/panel/api/inbounds/del/{id}` | Удалить inbound |
| POST | `/panel/api/inbounds/update/{id}` | Обновить inbound |
| POST | `/panel/api/inbounds/addClient` | Добавить клиента |
| POST | `/panel/api/inbounds/delClient/{email}` | Удалить клиента |
| GET | `/panel/api/inbounds/getClientTraffics/{email}` | Трафик клиента |

### Пример: Получить список inbounds

```bash
# Авторизация
curl -X POST "https://panel:2053/login" \
  -d "username=admin&password=admin" \
  -c cookies.txt

# Получить inbounds
curl "https://panel:2053/panel/api/inbounds/list" \
  -b cookies.txt
```

---

## Xray шаблон конфигурации

Полный шаблон хранится в `xrayTemplateConfig` (settings).
Можно переопределить в Web UI → Panel Settings → Xray Configs.

### Структура

```json
{
  "log": {},
  "api": {},
  "inbounds": [],
  "outbounds": [],
  "policy": {},
  "routing": {},
  "stats": {},
  "dns": {}
}
```

---

## Переменные окружения (расширенные)

Смотри `SETTINGS.md` для полного списка настроек.

Дополнительные переменные можно добавить в `init-config.sh`:

```bash
# Пример: добавить xray template
set_if_empty "xrayTemplateConfig" "$XUI_XRAY_TEMPLATE"
```
