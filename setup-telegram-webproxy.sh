#!/usr/bin/env bash
# ==============================================================================
# Telegram WEB Proxy Setup for 3x-ui / HAProxy stack
#
# Стек:
# 1. MTProxy (127.0.0.1:2398) — официальный бекенд от Telegram
# 2. tproxy-server (127.0.0.1:8080) — официальный WebView релей от Telegram Desktop
# 3. Nginx TLS Bridge (127.0.0.1:8443) — TLS терминация с сертификатом Let's Encrypt
# 4. HAProxy (порт 443) — SNI маршрутизация на 8443 без конфликта с 3x-ui/Reality
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

TPROXY_DIR="/etc/tproxy-server"
BUILD_DIR="/opt/tproxy-build"
MTPROXY_PORT=2398
MTPROXY_STATS_PORT=8888
TPROXY_PORT=8080
TPROXY_ADMIN_PORT=8081
TLS_BRIDGE_PORT=8443

DOMAIN=""
SECRET=""
EMAIL=""

usage() {
    cat <<EOF
Использование:
  sudo ./setup-telegram-webproxy.sh [опции]

Опции:
  --domain DOMAIN     Домен/поддомен для WEB Proxy (например, tg.shopflow.netstability.ru)
  --secret HEX        16-байтный hex-секрет (32 символа). Если не указан — сгенерируется автоматически.
  --email EMAIL       Email для Let's Encrypt сертификата.
  --status            Показать статус сервисов WEB Proxy и реквизиты подключения.
  --help              Показать эту справку.
EOF
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[ОШИБКА] Скрипт должен быть запущен с правами root (sudo)${PLAIN}" >&2
        exit 1
    fi
}

check_status() {
    echo -e "${BLUE}=== Статус Telegram WEB Proxy ===${PLAIN}"
    systemctl status mtproxy --no-pager 2>/dev/null || echo -e "${YELLOW}mtproxy не запущен${PLAIN}"
    systemctl status tproxy-server --no-pager 2>/dev/null || echo -e "${YELLOW}tproxy-server не запущен${PLAIN}"
    
    if [[ -f "${TPROXY_DIR}/credentials.env" ]]; then
        echo -e "\n${GREEN}Сохраненные реквизиты подключения:${PLAIN}"
        cat "${TPROXY_DIR}/credentials.env"
    fi
    exit 0
}

# Разбор аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --secret) SECRET="${2:-}"; shift 2 ;;
        --email) EMAIL="${2:-}"; shift 2 ;;
        --status) check_status ;;
        --help|-h) usage; exit 0 ;;
        *) echo -e "${RED}Неизвестный параметр: $1${PLAIN}"; usage; exit 1 ;;
    esac
done

check_root

echo -e "${BLUE}============================================================${PLAIN}"
echo -e "${BLUE}       Установка и настройка Telegram WEB Proxy            ${PLAIN}"
echo -e "${BLUE}============================================================${PLAIN}"

# 1. Проверка архитектуры
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
    echo -e "${RED}[ОШИБКА] Официальный MTProxy требует архитектуру x86_64 (обнаружено: $ARCH)${PLAIN}" >&2
    exit 1
fi

# 2. Установка зависимостей сборки
echo -e "${YELLOW}[1/6] Проверка и установка пакетов сборки...${PLAIN}"
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential libssl-dev zlib1g-dev git curl jq openssl ca-certificates >/dev/null
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm base-devel openssl zlib git curl jq >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf groupinstall -y "Development Tools" >/dev/null
    dnf install -y openssl-devel zlib-devel git curl jq >/dev/null
fi

# Проверка Go (нужен Go >= 1.21)
ensure_go() {
    if command -v go >/dev/null 2>&1; then
        local go_ver
        go_ver=$(go version | awk '{print $3}' | sed 's/go//')
        echo -e "${GREEN}  ✓ Найден Go версии $go_ver${PLAIN}"
        return 0
    fi

    echo -e "${YELLOW}  Установка Go 1.22 для сборки tproxy-server...${PLAIN}"
    local go_tar="go1.22.8.linux-amd64.tar.gz"
    local go_url="https://go.dev/dl/${go_tar}"
    
    mkdir -p /opt/golang
    curl -fsSL "$go_url" -o "/tmp/${go_tar}"
    rm -rf /opt/golang/go
    tar -C /opt/golang -xzf "/tmp/${go_tar}"
    rm -f "/tmp/${go_tar}"
    
    export PATH="/opt/golang/go/bin:${PATH}"
    echo -e "${GREEN}  ✓ Go успешно установлен в /opt/golang/go/bin${PLAIN}"
}
ensure_go

# 3. Сборка официального MTProxy
mkdir -p "$BUILD_DIR" "$TPROXY_DIR"
cd "$BUILD_DIR"

if [[ ! -f "/usr/local/bin/mtproto-proxy" ]]; then
    echo -e "${YELLOW}[2/6] Сборка официального MTProxy...${PLAIN}"
    rm -rf MTProxy
    git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git
    cd MTProxy
    make -j"$(nproc)"
    cp objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
    chmod 755 /usr/local/bin/mtproto-proxy
    echo -e "${GREEN}  ✓ MTProxy успешно скомпилирован${PLAIN}"
else
    echo -e "${GREEN}[2/6] MTProxy уже установлен (/usr/local/bin/mtproto-proxy)${PLAIN}"
fi

# Скачивание служебных файлов Telegram MTProxy
echo -e "${YELLOW}  Загрузка конфигурации Telegram DC (proxy-secret и proxy-multi.conf)...${PLAIN}"
curl -fsSL https://core.telegram.org/getProxySecret -o "${TPROXY_DIR}/proxy-secret"
curl -fsSL https://core.telegram.org/getProxyConfig -o "${TPROXY_DIR}/proxy-multi.conf"
chmod 600 "${TPROXY_DIR}/proxy-secret" "${TPROXY_DIR}/proxy-multi.conf"

# 4. Сборка tproxy-server
cd "$BUILD_DIR"
if [[ ! -f "/usr/local/bin/tproxy-server" ]]; then
    echo -e "${YELLOW}[3/6] Сборка tproxy-server (Telegram WebView Relay)...${PLAIN}"
    rm -rf tproxy-server
    git clone --depth 1 https://github.com/telegramdesktop/tproxy-server.git
    cd tproxy-server
    go build -trimpath -ldflags="-s -w" -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
    chmod 755 /usr/local/bin/tproxy-server
    echo -e "${GREEN}  ✓ tproxy-server успешно скомпилирован${PLAIN}"
else
    echo -e "${GREEN}[3/6] tproxy-server уже установлен (/usr/local/bin/tproxy-server)${PLAIN}"
fi

# 5. Генерация секрета
if [[ -z "$SECRET" ]]; then
    if [[ -f "${TPROXY_DIR}/credentials.env" ]]; then
        # Читаем существующий секрет
        # shellcheck disable=SC1091
        source "${TPROXY_DIR}/credentials.env"
    fi
fi
if [[ -z "$SECRET" ]]; then
    SECRET=$(openssl rand -hex 16)
fi

# Создаем системного пользователя mtproxy, если нет
if ! id -u mtproxy >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /var/empty mtproxy || useradd -r -s /bin/false mtproxy
fi
chown -R mtproxy:mtproxy "$TPROXY_DIR"

# 6. Создание конфигурации /etc/tproxy-server/config.json
echo -e "${YELLOW}[4/6] Генерация конфигурации tproxy-server...${PLAIN}"
cat > "${TPROXY_DIR}/config.json" <<EOF
{
  "listen": "127.0.0.1:${TPROXY_PORT}",
  "admin_listen": "127.0.0.1:${TPROXY_ADMIN_PORT}",
  "mtproxy": "127.0.0.1:${MTPROXY_PORT}",
  "base_path": "",
  "profiles": [
    {
      "name": "default",
      "secret": "${SECRET}",
      "public_site": {
        "public_upstream": "http://127.0.0.1:10444"
      }
    }
  ]
}
EOF
chmod 600 "${TPROXY_DIR}/config.json"
chown mtproxy:mtproxy "${TPROXY_DIR}/config.json"

# 7. Создание systemd-сервисов
echo -e "${YELLOW}[5/6] Настройка systemd служб mtproxy и tproxy-server...${PLAIN}"

# mtproxy.service
cat > /etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=Official Telegram MTProto Proxy Backend
After=network.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
WorkingDirectory=${TPROXY_DIR}
ExecStart=/usr/local/bin/mtproto-proxy -u mtproxy -p ${MTPROXY_STATS_PORT} -H ${MTPROXY_PORT} -S ${SECRET} --aes-pwd ${TPROXY_DIR}/proxy-secret ${TPROXY_DIR}/proxy-multi.conf -M 1 --http-stats
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# tproxy-server.service
cat > /etc/systemd/system/tproxy-server.service <<EOF
[Unit]
Description=Telegram WEB Proxy Relay (WebView bridge)
After=network.target mtproxy.service
Wants=mtproxy.service

[Service]
Type=simple
User=mtproxy
Group=mtproxy
WorkingDirectory=${TPROXY_DIR}
ExecStart=/usr/local/bin/tproxy-server -config ${TPROXY_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy
systemctl enable --now tproxy-server

# Сохраняем реквизиты
cat > "${TPROXY_DIR}/credentials.env" <<EOF
WEB_PROXY_DOMAIN="${DOMAIN}"
WEB_PROXY_SECRET="${SECRET}"
MTPROXY_PORT="${MTPROXY_PORT}"
TPROXY_PORT="${TPROXY_PORT}"
TLS_BRIDGE_PORT="${TLS_BRIDGE_PORT}"
EOF
chmod 600 "${TPROXY_DIR}/credentials.env"

echo -e "\n${GREEN}[6/6] Демоны MTProxy и tproxy-server успешно развернуты и запущены!${PLAIN}"
echo -e "${GREEN}  ✓ mtproxy: 127.0.0.1:${MTPROXY_PORT}${PLAIN}"
echo -e "${GREEN}  ✓ tproxy-server: 127.0.0.1:${TPROXY_PORT}${PLAIN}"
echo -e "${GREEN}  ✓ Секрет: ${SECRET}${PLAIN}"

if [[ -n "$DOMAIN" ]]; then
    echo -e "\n${BLUE}============================================================${PLAIN}"
    echo -e "${BLUE}Реквизиты для подключения в приложении Telegram:${PLAIN}"
    echo -e "  Тип:    ${YELLOW}WEB Proxy${PLAIN}"
    echo -e "  Сервер: ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "  Ключ:   ${GREEN}${SECRET}${PLAIN}"
    echo -e "${BLUE}============================================================${PLAIN}"
else
    echo -e "\n${YELLOW}Домен пока не привязан.${PLAIN}"
    echo -e "Когда выберите домен, укажите его через:${PLAIN}"
    echo -e "  sudo ./setup-telegram-webproxy.sh --domain <ваш_домен>"
fi
