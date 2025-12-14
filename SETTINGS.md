# Все доступные настройки 3x-ui

Полный список параметров для базы данных панели.
Ключи соответствуют полям в таблице `settings`.

---

## Веб-панель

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `webListen` | IP для прослушивания | `""` (все) |
| `webDomain` | Домен панели | `""` |
| `webPort` | Порт панели | `2053` |
| `webCertFile` | Путь к SSL сертификату | `""` |
| `webKeyFile` | Путь к SSL ключу | `""` |
| `webBasePath` | Базовый путь URL | `/` |
| `sessionMaxAge` | Таймаут сессии (минуты) | `360` |

---

## Подписка (Subscription)

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `subEnable` | Включить сервер подписок | `true` |
| `subListen` | IP для прослушивания | `""` |
| `subPort` | Порт подписок | `2096` |
| `subPath` | Путь подписок | `/sub/` |
| `subDomain` | Домен подписок | `""` |
| `subCertFile` | SSL сертификат | `""` |
| `subKeyFile` | SSL ключ | `""` |
| `subUpdates` | Интервал обновления (часы) | `12` |
| `subEncrypt` | Шифровать ответы | `true` |
| `subShowInfo` | Показывать инфо клиента | `true` |
| `subURI` | URI сервера подписок | `""` |
| `subTitle` | Заголовок подписки | `""` |

### JSON подписки

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `subJsonEnable` | Включить JSON endpoint | `false` |
| `subJsonPath` | Путь JSON подписок | `/json/` |
| `subJsonURI` | JSON URI | `""` |
| `subJsonFragment` | Fragment настройки | `""` |
| `subJsonNoises` | Noises настройки | `""` |
| `subJsonMux` | Mux настройки | `""` |
| `subJsonRules` | Rules настройки | `""` |

---

## Telegram бот

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `tgBotEnable` | Включить бота | `false` |
| `tgBotToken` | Токен бота | `""` |
| `tgBotChatId` | ID чата/админа | `""` |
| `tgBotProxy` | Прокси для бота | `""` |
| `tgBotAPIServer` | API сервер | `""` |
| `tgRunTime` | Расписание уведомлений | `@daily` |
| `tgBotBackup` | Бекап через бота | `false` |
| `tgBotLoginNotify` | Уведомления о входе | `true` |
| `tgCpu` | Порог CPU для алертов | `80` |
| `tgLang` | Язык бота | `en-US` |

---

## Безопасность

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `twoFactorEnable` | Включить 2FA | `false` |
| `twoFactorToken` | Токен 2FA | `""` |
| `timeLocation` | Часовой пояс | `Local` |
| `secret` | Секретный ключ сессий | (генерируется) |

---

## Интерфейс

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `pageSize` | Элементов на странице | `25` |
| `expireDiff` | Предупреждение истечения (дни) | `0` |
| `trafficDiff` | Предупреждение трафика (%) | `0` |
| `remarkModel` | Шаблон меток | `-ieo` |
| `datepicker` | Формат дат | `gregorian` |

---

## Xray

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `xrayTemplateConfig` | Шаблон конфигурации Xray | `""` |

---

## Внешний трафик

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `externalTrafficInformEnable` | Внешний репорт трафика | `false` |
| `externalTrafficInformURI` | URI для репорта | `""` |

---

## LDAP

| Ключ БД | Описание | По умолчанию |
|---------|----------|--------------|
| `ldapEnable` | Включить LDAP | `false` |
| `ldapHost` | LDAP хост | `""` |
| `ldapPort` | LDAP порт | `389` |
| `ldapUseTLS` | Использовать TLS | `false` |
| `ldapBindDN` | Bind DN | `""` |
| `ldapPassword` | LDAP пароль | `""` |
| `ldapBaseDN` | Base DN | `""` |
| `ldapUserFilter` | Фильтр пользователей | `(objectClass=person)` |
| `ldapUserAttr` | Атрибут пользователя | `mail` |
| `ldapVlessField` | Поле vless | `vless_enabled` |
| `ldapSyncCron` | Cron синхронизации | `@every 1m` |
| `ldapFlagField` | Поле флага | `""` |
| `ldapTruthyValues` | Истинные значения | `true,1,yes,on` |
| `ldapInvertFlag` | Инвертировать флаг | `false` |
| `ldapInboundTags` | Теги inbound | `""` |
| `ldapAutoCreate` | Автосоздание | `false` |
| `ldapAutoDelete` | Автоудаление | `false` |
| `ldapDefaultTotalGB` | ГБ по умолчанию | `0` |
| `ldapDefaultExpiryDays` | Дни истечения | `0` |
| `ldapDefaultLimitIP` | Лимит IP | `0` |

---

## Использование в init-config.sh

```bash
# Всегда перезаписывает (для серверо-специфичных настроек):
set_always "webPort" "$XUI_PORT"

# Только если нет в БД (сохраняет из бекапа):
set_if_empty "pageSize" "25"
```

Для добавления новой настройки:
1. Добавьте переменную в `.env.example`
2. Добавьте `set_always` или `set_if_empty` в `init-config.sh`
