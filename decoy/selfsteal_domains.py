#!/usr/bin/env python3
"""Discover the configured names of active local SelfSteal targets, read-only."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3
import sys


def valid_domain(value):
    return isinstance(value, str) and len(value) <= 253 and re.fullmatch(
        r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+"
        r"[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", value)


def discover(path, primary="", backend_port=10444):
    names = []
    if primary:
        if not valid_domain(primary):
            raise ValueError("invalid explicitly configured primary domain")
        names.append(primary.lower())
    path = Path(path).resolve()
    if path.is_file():
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=3)) as conn:
            conn.execute("PRAGMA query_only=ON")
            for (raw,) in conn.execute("SELECT stream_settings FROM inbounds WHERE enable=1 ORDER BY id"):
                try:
                    stream = json.loads(raw or "{}")
                except (TypeError, ValueError):
                    continue
                if not isinstance(stream, dict) or stream.get("security") != "reality":
                    continue
                reality = stream.get("realitySettings") or {}
                if not isinstance(reality, dict) or reality.get("target") not in (
                        "/run/x-ui-selfsteal/https.sock", f"127.0.0.1:{backend_port}", f"localhost:{backend_port}"):
                    continue
                values = reality.get("serverNames")
                if not isinstance(values, list):
                    raise ValueError("local SelfSteal inbound has invalid serverNames")
                for name in values:
                    if not valid_domain(name):
                        raise ValueError("local SelfSteal inbound has invalid DNS serverName")
                    name = name.lower()
                    if name not in names:
                        names.append(name)
                    if len(names) > 64:
                        raise ValueError("too many SelfSteal domain names")
    if not names:
        raise ValueError("no local SelfSteal domain found; set serverNames in the panel or explicit XUI_SELFSTEAL_DOMAIN")
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True)
    parser.add_argument("--primary", default="")
    parser.add_argument("--backend-port", type=int, default=10444)
    args = parser.parse_args()
    try:
        print("\n".join(discover(args.db, args.primary, args.backend_port)))
    except (ValueError, sqlite3.Error):
        print("[ERROR] Cannot discover SelfSteal names; check active local targets/serverNames or explicit domain", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
