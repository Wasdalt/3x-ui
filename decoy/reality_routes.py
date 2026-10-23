#!/usr/bin/env python3
"""Render selected/opt-in auto-discovered local HTTP inbounds, read-only."""

import argparse
from contextlib import closing
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sqlite3
import sys


HTTP_PROTOCOLS = {"vless", "vmess", "trojan"}
SETTING_KEYS = {"ws": "wsSettings", "httpupgrade": "httpupgradeSettings",
                "upgrade": "upgradeSettings", "xhttp": "xhttpSettings",
                "splithttp": "splithttpSettings", "grpc": "grpcSettings"}


class RouteError(ValueError):
    """An unsafe or unsupported route; never include raw inbound JSON in errors."""


@dataclass(frozen=True)
class Route:
    inbound_id: int
    network: str
    prefix: str
    upstream: str


def parse_ids(value):
    if not value:
        return []
    if not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", value):
        raise RouteError("XUI_SELFSTEAL_PROXY_INBOUNDS: нужны ID через запятую без пробелов")
    parts = value.split(",")
    if len(parts) > 128 or any(len(part) > 19 for part in parts):
        raise RouteError("Слишком много ID или ID вне диапазона SQLite")
    ids = [int(part) for part in parts]
    if any(item > 2**63 - 1 for item in ids):
        raise RouteError("ID вне диапазона SQLite")
    if len(ids) != len(set(ids)):
        raise RouteError("Список ID содержит повторы")
    return ids


def route_from_row(row, backend_port):
    inbound_id, enabled, protocol, listen, port, raw = row
    label = f"Входящий {inbound_id}"
    if enabled != 1:
        raise RouteError(f"{label}: выключен; автоматического включения нет")
    if protocol not in HTTP_PROTOCOLS:
        raise RouteError(f"{label}: протокол не поддерживает этот HTTP-маршрут")
    if listen not in {"127.0.0.1", "::1"}:
        raise RouteError(f"{label}: backend должен явно слушать 127.0.0.1 или ::1")
    if not isinstance(port, int) or not 1024 <= port <= 65535 or port == backend_port:
        raise RouteError(f"{label}: некорректный порт или петля на HTTPS-порт заглушки")
    try:
        stream = json.loads(raw)
    except (TypeError, ValueError):
        raise RouteError(f"{label}: некорректный stream_settings") from None
    if not isinstance(stream, dict):
        raise RouteError(f"{label}: stream_settings должен быть объектом")
    if stream.get("security") not in (None, "", "none"):
        raise RouteError(f"{label}: TLS/REALITY не снимается автоматически; нужен локальный HTTP-backend с security=none")
    network = stream.get("network")
    if not isinstance(network, str) or network not in SETTING_KEYS:
        raise RouteError(f"{label}: поддерживаются WS, HTTPUpgrade, XHTTP/SplitHTTP и gRPC")
    settings = stream.get(SETTING_KEYS[network], {})
    if not isinstance(settings, dict):
        raise RouteError(f"{label}: некорректные настройки транспорта")
    if network == "upgrade" and not settings:
        settings = stream.get("httpupgradeSettings", {})
        if not isinstance(settings, dict):
            raise RouteError(f"{label}: некорректные настройки HTTPUpgrade")
    path = settings.get("serviceName" if network == "grpc" else "path", "")
    if not isinstance(path, str) or not path or len(path) > 1024 or any(ord(c) < 32 for c in path):
        raise RouteError(f"{label}: нужен непустой безопасный path/serviceName")
    if network == "grpc":
        path = "/" + path.strip("/") + "/"
    else:
        # Query options (e.g. WS early-data hints) are not part of nginx location
        # matching. proxy_pass without a URI preserves the original query.
        path = path.split("?", 1)[0]
    if (not re.fullmatch(r"/[A-Za-z0-9_~./-]+", path) or "//" in path
            or any(part.startswith(".") for part in path.split("/") if part)):
        raise RouteError(f"{label}: корневой, неоднозначный или небезопасный path/serviceName")
    address = "[::1]" if listen == "::1" else "127.0.0.1"
    return Route(inbound_id, network, path, f"{address}:{port}")


def load_routes(db_path, ids, backend_port, auto=False):
    """Auto is explicit opt-in, never repair or enable an inbound.

    Select all active local loopback HTTP profiles with explicit security=none;
    unrelated protocols, public listeners and TLS/REALITY are not candidates.
    Invalid candidate paths/ports and ambiguous prefixes abort the whole plan.
    Re-evaluated at plan/apply time only: no watch/reload daemon is added here.
    """
    if auto and ids:
        raise RouteError("Выберите auto или список ID, не оба режима")
    if not ids and not auto:
        return []
    path = Path(db_path).resolve()
    if not path.is_file():
        raise RouteError("БД выбранных маршрутов не найдена; новая БД не создаётся")
    try:
        # Do not use immutable=1: a running panel may have committed data in WAL.
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)) as conn:
            conn.execute("PRAGMA query_only=ON")
            conn.execute("BEGIN")
            rows = []
            if auto:
                columns = {row[1] for row in conn.execute("PRAGMA table_info(inbounds)")}
                local_only = " AND (node_id IS NULL OR node_id=0)" if "node_id" in columns else ""
                candidates = conn.execute("SELECT id,enable,protocol,listen,port,stream_settings "
                    "FROM inbounds WHERE enable=1 AND listen IN ('127.0.0.1','::1') "
                    "AND protocol IN ('vless','vmess','trojan')" + local_only + " ORDER BY id")
                for row in candidates:
                    try:
                        stream = json.loads(row[5])
                    except (TypeError, ValueError):
                        raise RouteError(f"Входящий {row[0]}: некорректный stream_settings") from None
                    if not isinstance(stream, dict):
                        raise RouteError(f"Входящий {row[0]}: stream_settings должен быть объектом")
                    network = stream.get("network")
                    if (stream.get("security") == "none" and isinstance(network, str)
                            and network in SETTING_KEYS):
                        rows.append(row)
            else:
                for inbound_id in ids:
                    row = conn.execute("SELECT id, enable, protocol, listen, port, stream_settings "
                                       "FROM inbounds WHERE id = ?", (inbound_id,)).fetchone()
                    if row is None:
                        raise RouteError(f"Входящий {inbound_id}: отсутствует в БД")
                    rows.append(row)
    except sqlite3.Error:
        raise RouteError("Не удалось прочитать БД: проверьте путь, доступ и схему inbounds") from None
    routes = [route_from_row(row, backend_port) for row in rows]
    for index, route in enumerate(routes):
        for other in routes[:index]:
            if route.prefix.startswith(other.prefix) or other.prefix.startswith(route.prefix):
                raise RouteError(f"Входящие {other.inbound_id} и {route.inbound_id}: пути совпадают или перекрываются")
    return routes


def render_routes(routes):
    blocks = []
    for route in routes:
        lines = [f"        # inbound {route.inbound_id}: {route.network} {route.prefix} -> {route.upstream}",
                 f"        location ^~ {route.prefix} {{"]
        if route.network == "grpc":
            lines += [f"            grpc_pass grpc://{route.upstream};",
                      "            grpc_set_header Host $host;",
                      "            grpc_set_header X-Real-IP $selfsteal_client_ip;",
                      "            grpc_set_header X-Forwarded-For $selfsteal_client_ip;",
                      "            grpc_set_header X-Forwarded-Proto https;",
                      "            grpc_read_timeout 3600s;",
                      "            grpc_send_timeout 3600s;"]
        else:
            lines += [f"            proxy_pass http://{route.upstream};",
                      "            proxy_http_version 1.1;",
                      "            proxy_set_header Host $host;",
                      "            proxy_set_header X-Real-IP $selfsteal_client_ip;",
                      "            proxy_set_header X-Forwarded-For $selfsteal_client_ip;",
                      "            proxy_set_header X-Forwarded-Proto https;",
                      "            proxy_buffering off;",
                      "            proxy_request_buffering off;",
                      "            proxy_read_timeout 3600s;",
                      "            proxy_send_timeout 3600s;"]
            if route.network in {"ws", "upgrade", "httpupgrade"}:
                lines += ["            proxy_set_header Upgrade $http_upgrade;",
                          "            proxy_set_header Connection $selfsteal_connection_upgrade;"]
            else:
                lines.append('            proxy_set_header Connection "";')
        lines.append("        }")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True)
    parser.add_argument("--ids", required=True)
    parser.add_argument("--backend-port", type=int, required=True)
    args = parser.parse_args()
    try:
        auto = args.ids == "auto"
        routes = load_routes(args.db, [] if auto else parse_ids(args.ids), args.backend_port, auto=auto)
        output = render_routes(routes)
    except RouteError as error:
        print(f"[SELFSTEAL-ERROR] {error}", file=sys.stderr)
        return 1
    if output:
        print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
