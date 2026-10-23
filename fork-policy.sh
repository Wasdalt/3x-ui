#!/bin/sh
# Shared opt-in policy. Sourcing this file has no filesystem/service side effects.

fork_policy_enabled() {
    case "$1" in XUI_*) ;; *) return 2 ;; esac
    case "$1" in *[!A-Z0-9_]*) return 2 ;; esac
    eval 'fork_policy_value=${'"$1"':-false}'
    case "$fork_policy_value" in
        true|TRUE|1|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

fork_allow() {
    if fork_policy_enabled "$1"; then
        printf '[ALLOW] %s — явно разрешено %s=true\n' "$2" "$1"
        return 0
    fi
    printf '[SKIP] %s — требуется явное %s=true\n' "$2" "$1"
    return 1
}

fork_policy_report() {
    printf '[POLICY] Безопасные значения по умолчанию; параметры .env применяются только если заданы\n'
    for fork_policy_name in XUI_AUTO_DB_APPLY XUI_AUTO_CERTS XUI_AUTO_CERT_DOMAINS \
        XUI_HAPROXY_ENABLE XUI_SELFSTEAL_ENABLE XUI_SELFSTEAL_PUBLIC \
        XUI_REWRITE_INBOUNDS XUI_SYNC_INBOUND_CERTS XUI_HOSTS_SYNC XUI_HOSTS_INHERIT_TLS \
        XUI_TUNE_NETWORK XUI_CLEANUP_ORPHANS XUI_DB_MAINTENANCE \
        XUI_MANAGE_SYSTEM_NGINX XUI_CERTBOT_STOP_WEB_SERVER XUI_REPAIR_XRAY_TEMPLATE \
        XUI_SELFSTEAL_ALLOW_FALLBACK_CERT; do
        if fork_policy_enabled "$fork_policy_name"; then
            printf '[POLICY] %s=true\n' "$fork_policy_name"
        else
            printf '[POLICY] %s=false (без автоматических изменений)\n' "$fork_policy_name"
        fi
    done
}

fork_setting_reason() {
    case "$1" in
        webPort) printf 'явный XUI_PORT' ;;
        webBasePath) printf 'явный XUI_BASE_PATH' ;;
        subPort) printf 'явный XUI_SUB_PORT' ;;
        subPath) printf 'явный XUI_SUB_PATH' ;;
        subEnable) printf 'XUI_SUB_ENABLE или защита от публикации без TLS' ;;
        webDomain|webCertFile|webKeyFile) printf 'проверенная конфигурация TLS панели' ;;
        subDomain|subCertFile|subKeyFile) printf 'проверенная конфигурация TLS подписки' ;;
        *) printf 'явный параметр окружения' ;;
    esac
}

fork_setting_log() {
    # Never print values: paths may contain private URLs, tokens or credentials.
    printf '[%s] setting=%s; причина: %s; значение скрыто\n' "$1" "$2" "$3"
    case "$1" in
        CHANGE|NEW) FORK_SETTING_CHANGES=$((${FORK_SETTING_CHANGES:-0} + 1)) ;;
        KEEP) FORK_SETTING_KEPT=$((${FORK_SETTING_KEPT:-0} + 1)) ;;
        SKIP) FORK_SETTING_SKIPPED=$((${FORK_SETTING_SKIPPED:-0} + 1)) ;;
    esac
}

fork_warn() {
    FORK_WARNINGS=$((${FORK_WARNINGS:-0} + 1))
    printf '[WARN] %s\n' "$1"
}

fork_summary() {
    printf '[SUMMARY] Параметры settings: изменено=%s, сохранено=%s, пропущено=%s; предупреждений=%s\n' \
        "${FORK_SETTING_CHANGES:-0}" "${FORK_SETTING_KEPT:-0}" "${FORK_SETTING_SKIPPED:-0}" "${FORK_WARNINGS:-0}"
    printf '[SUMMARY] Это не проверка подключения клиента; сверяйте [WARN]/[ERROR] и статусы служб\n'
}
