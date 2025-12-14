# Удалённые файлы

Этот файл документирует файлы, удалённые из оригинального репозитория 3x-ui.
При обновлении из upstream эти файлы не будут восстановлены (настроено в `.gitattributes`).

## Удалённые файлы

### Скриншоты (media/)
- `media/` — вся папка (26 скриншотов, ~3MB)

### README переводы
- `README.ar_EG.md`
- `README.es_ES.md`
- `README.fa_IR.md`
- `README.ru_RU.md`
- `README.zh_CN.md`

### GitHub файлы (.github/)
- `.github/` — вся папка (workflows, issue templates, funding)

### Скрипты установки
- `install.sh`
- `update.sh`

### Системные файлы
- `x-ui.service` (systemd)
- `x-ui.rc` (OpenRC)
- `windows_files/`
- `.vscode/`

## Почему удалены

- **media/** — скриншоты для README, не нужны для работы
- **README переводы** — оставлен только английский README.md
- **.github/** — GitHub Actions и шаблоны issues не используются в форке
- **Скрипты установки** — используем Docker, не нужны
- **Системные файлы** — systemd/OpenRC не используются в Docker

## Обновление из upstream

При `git pull upstream main` эти файлы НЕ будут восстановлены благодаря настройке в `.gitattributes`.
