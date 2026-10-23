#!/usr/bin/env python3
"""Read-only allowlisted REALITY backends for a dedicated SNI router."""

import argparse
from contextlib import closing
from dataclasses import dataclass
import json
from pathlib import Path
import re
import socket
import sqlite3
import ssl
import sys


class RouterError(ValueError):
    pass


@dataclass(frozen=True)
class Route:
    inbound_id: int
    domain: str
    address: str
    port: int


def parse_ids(value):
    if not value:
        return []
    if not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", value or ""):
        raise RouterError("XUI_SNI_ROUTER_INBOUNDS requires explicit inbound IDs separated by commas")
    parts = value.split(",")
    if len(parts) > 64 or any(len(part) > 19 for part in parts):
        raise RouterError("Too many/invalid inbound IDs")
    ids = [int(part) for part in parts]
    if len(set(ids)) != len(ids) or any(item > 2**63 - 1 for item in ids):
        raise RouterError("Duplicate/invalid inbound IDs")
    return ids


def valid_domain(value):
    return (isinstance(value, str) and len(value) <= 253 and
            re.fullmatch(r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+"
                         r"[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", value))


def load_routes(path, ids, backend_port=10444):
    path = Path(path).resolve()
    if not path.is_file():
        raise RouterError("Database missing; no new database is created")
    routes, domains = [], set()
    try:
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=3)) as conn:
            conn.execute("PRAGMA query_only=ON")
            conn.execute("BEGIN")
            if not ids:
                # Prepared loopback REALITY + existing enabled external443 Host
                # expresses intent in the panel. Never make a public inbound
                # private or create/repair a Host merely to discover a route.
                ids = []
                candidates = conn.execute("""SELECT DISTINCT i.id,i.stream_settings FROM inbounds i
                    JOIN hosts h ON h.inbound_id=i.id WHERE i.enable=1
                    AND i.listen IN ('127.0.0.1','::1') AND i.port<>443
                    AND h.port=443 AND COALESCE(h.is_disabled,0)=0
                    AND h.security IN ('reality','same','') ORDER BY i.id""").fetchall()
                for inbound_id, raw in candidates:
                    try:
                        candidate = json.loads(raw or "{}")
                    except (ValueError, TypeError):
                        continue
                    if (isinstance(candidate, dict) and candidate.get("security") == "reality"
                            and isinstance(candidate.get("realitySettings"), dict)
                            and candidate["realitySettings"].get("target") == "/run/x-ui-selfsteal/https.sock"):
                        ids.append(inbound_id)
                if not ids:
                    raise RouterError("No prepared SNI profiles found: configure loopback REALITY inbounds and active external443 Hosts in the panel first")
            for inbound_id in ids:
                row = conn.execute("SELECT enable,listen,port,protocol,stream_settings "
                                   "FROM inbounds WHERE id=?", (inbound_id,)).fetchone()
                if row is None:
                    raise RouterError(f"Inbound {inbound_id}: not found")
                active, address, port, protocol, raw = row
                if active != 1 or protocol != "vless":
                    raise RouterError(f"Inbound {inbound_id}: must be an active VLESS inbound")
                if address not in ("127.0.0.1", "::1"):
                    raise RouterError(f"Inbound {inbound_id}: explicitly configure a loopback listen first")
                if not isinstance(port, int) or not 1024 <= port <= 65535 or port == backend_port:
                    raise RouterError(f"Inbound {inbound_id}: invalid/looping backend port")
                try:
                    stream = json.loads(raw or "{}")
                except (ValueError, TypeError):
                    raise RouterError(f"Inbound {inbound_id}: invalid stream settings") from None
                if not isinstance(stream, dict) or stream.get("security") != "reality":
                    raise RouterError(f"Inbound {inbound_id}: only REALITY is supported by this router")
                if stream.get("network") not in ("tcp", "raw", "xhttp", "splithttp", "grpc"):
                    raise RouterError(f"Inbound {inbound_id}: unsupported network")
                reality = stream.get("realitySettings") or {}
                sockopt = stream.get("sockopt") or {}
                if not isinstance(reality, dict) or not isinstance(sockopt, dict):
                    raise RouterError(f"Inbound {inbound_id}: invalid REALITY/sockopt options")
                if sockopt.get("acceptProxyProtocol") is not True:
                    raise RouterError(f"Inbound {inbound_id}: sockopt.acceptProxyProtocol=true required")
                if reality.get("target") != "/run/x-ui-selfsteal/https.sock" or reality.get("xver") != 1:
                    raise RouterError(f"Inbound {inbound_id}: local SelfSteal Unix target with xver=1 required")
                names = reality.get("serverNames")
                if not isinstance(names, list) or not names:
                    raise RouterError(f"Inbound {inbound_id}: explicit serverNames required")
                host_snis = conn.execute("""SELECT sni FROM hosts WHERE inbound_id=? AND port=443
                    AND COALESCE(is_disabled,0)=0 AND security IN ('reality','same','')""", (inbound_id,)).fetchall()
                if not host_snis or not any((sni or "").lower() in [str(n).lower() for n in names]
                                            for (sni,) in host_snis):
                    raise RouterError(f"Inbound {inbound_id}: external443 Host SNI must match a configured serverName; Host is not rewritten automatically")
                for domain in names:
                    if not valid_domain(domain):
                        raise RouterError(f"Inbound {inbound_id}: invalid DNS serverName")
                    domain = domain.lower()
                    if domain in domains:
                        raise RouterError("Duplicate SNI: distinct routed inbounds require distinct domains")
                    domains.add(domain)
                    routes.append(Route(inbound_id, domain, address, port))
    except sqlite3.Error:
        raise RouterError("Cannot read selected inbounds; check DB schema/access/lock") from None
    return routes


def render_config(routes, fallback_port=10444):
    if not 1024 <= fallback_port <= 65535:
        raise RouterError("Invalid local HTTPS fallback port")
    lines = ["global", "    maxconn 8192", "defaults", "    mode tcp",
             "    timeout connect 5s", "    timeout client 1h", "    timeout server 1h",
             "frontend public_tls", "    bind :443", "    tcp-request inspect-delay 5s",
             "    tcp-request content accept if { req.ssl_hello_type 1 }"]
    for index, route in enumerate(routes):
        lines += [f"    acl sni_{index} req.ssl_sni -i {route.domain}",
                  f"    use_backend inbound_{route.inbound_id} if sni_{index}"]
    lines += ["    default_backend decoy_https", "backend decoy_https",
              f"    server decoy 127.0.0.1:{fallback_port}"]
    seen = set()
    for route in routes:
        if route.inbound_id in seen:
            continue
        seen.add(route.inbound_id)
        address = f"[{route.address}]" if ":" in route.address else route.address
        lines += [f"backend inbound_{route.inbound_id}",
                  f"    server local {address}:{route.port} send-proxy"]
    return "\n".join(lines) + "\n"


def check_backends(routes):
    context = ssl.create_default_context()
    context.set_alpn_protocols(["http/1.1"])
    for route in routes:
        with socket.create_connection((route.address, route.port), timeout=5) as conn:
            local = conn.getsockname()
            family = "TCP6" if ":" in route.address else "TCP4"
            conn.sendall(f"PROXY {family} {local[0]} {route.address} {local[1]} {route.port}\r\n".encode("ascii"))
            with context.wrap_socket(conn, server_hostname=route.domain) as tls:
                tls.sendall(f"GET / HTTP/1.1\r\nHost: {route.domain}\r\nConnection: close\r\n\r\n".encode("ascii"))
                first = tls.recv(1024).split(b"\r\n", 1)[0]
                if not re.match(rb"HTTP/1\.[01] (200|301|302|304)\b", first):
                    raise RouterError(f"Inbound {route.inbound_id}: local HTTPS fallback did not return a site")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True)
    parser.add_argument("--ids", default="")
    parser.add_argument("--fallback-port", type=int, default=10444)
    parser.add_argument("--format", choices=("config", "domains", "plan"), default="plan")
    parser.add_argument("--check-backends", action="store_true")
    args = parser.parse_args()
    try:
        routes = load_routes(args.db, parse_ids(args.ids), args.fallback_port)
        config = render_config(routes, args.fallback_port)
        if args.check_backends:
            check_backends(routes)
        if args.format == "config":
            print(config, end="")
        elif args.format == "domains":
            print("\n".join(route.domain for route in routes))
        else:
            for route in routes:
                print(f"[PLAN] TCP443 SNI {route.domain} -> inbound {route.inbound_id} "
                      f"{route.address}:{route.port}; PROXY v1")
            print("[KEEP] Database/Hosts unchanged; unknown SNI -> local HTTPS site")
    except (RouterError, OSError, ssl.SSLError) as error:
        detail = str(error) if isinstance(error, RouterError) else "backend TLS/connectivity check failed"
        print(f"[ERROR] {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
