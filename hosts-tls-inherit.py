#!/usr/bin/env python3
"""Narrow live inheritance: only explicit inbound fingerprint/ALPN -> existing Hosts.

No service commands, init-config, certificate handling or inbound writes belong here.
"""

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import sys
import time


class InheritanceError(ValueError):
    pass


def parse_ids(value):
    if not value:
        return set()
    if not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", value):
        raise InheritanceError("Host IDs must be positive integers separated by commas")
    parts = value.split(",")
    if len(parts) > 512 or any(len(item) > 19 for item in parts):
        raise InheritanceError("Host ID list is too large")
    result = {int(item) for item in parts}
    if any(item > 2**63 - 1 for item in result):
        raise InheritanceError("Host ID is outside SQLite range")
    return result


def explicit_values(raw_stream, host_security):
    """Missing fields mean KEEP, explicit empty fields mean clear inherited value."""
    try:
        stream = json.loads(raw_stream or "{}")
    except (TypeError, ValueError):
        raise InheritanceError("invalid stream_settings") from None
    if not isinstance(stream, dict):
        raise InheritanceError("stream_settings must be an object")
    security = stream.get("security")
    if security not in ("tls", "reality") or host_security not in (security, "same", ""):
        return {}
    options = stream.get("tlsSettings" if security == "tls" else "realitySettings", {})
    if not isinstance(options, dict):
        raise InheritanceError("invalid TLS/REALITY options")
    settings = options.get("settings", {})
    if not isinstance(settings, dict):
        raise InheritanceError("invalid client share settings")
    values = {}
    # Match the panel's client/share fingerprint precedence, not a browser guess.
    if "fingerprint" in settings or "fingerprint" in options:
        fp = settings["fingerprint"] if "fingerprint" in settings else options["fingerprint"]
        if (not isinstance(fp, str) or len(fp) > 128
                or any(ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF for char in fp)):
            raise InheritanceError("invalid explicit fingerprint")
        values["fingerprint"] = fp
    if "alpn" in options or "alpn" in settings:
        alpn = options["alpn"] if "alpn" in options else settings["alpn"]
        if (not isinstance(alpn, list) or len(alpn) > 32 or any(
                not isinstance(item, str) or not item
                or any(ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF for char in item)
                or len(item.encode("utf-8")) > 255 for item in alpn)):
            raise InheritanceError("invalid explicit ALPN list")
        values["alpn"] = alpn
    return values


def read_candidates(conn, selected, excluded):
    needed = {"id", "inbound_id", "security", "fingerprint", "alpn", "is_disabled"}
    columns = {row[1] for row in conn.execute("PRAGMA table_info(hosts)")}
    if not needed <= columns:
        raise InheritanceError("panel schema lacks the required Hosts columns")
    candidates = []
    skipped = []
    query = """SELECT h.id, h.security, h.fingerprint, h.alpn, i.id, i.stream_settings
               FROM hosts h JOIN inbounds i ON i.id=h.inbound_id
               WHERE COALESCE(h.is_disabled,0)=0 AND i.enable=1 ORDER BY h.id"""
    for host_id, security, fp, alpn, inbound_id, stream in conn.execute(query):
        if host_id in excluded or (selected and host_id not in selected):
            continue
        try:
            values = explicit_values(stream, security)
        except InheritanceError as error:
            skipped.append((host_id, inbound_id, str(error)))
            continue
        changes = {}
        if "fingerprint" in values and fp != values["fingerprint"]:
            changes["fingerprint"] = values["fingerprint"]
        if "alpn" in values:
            try:
                existing = json.loads(alpn or "[]")
            except (TypeError, ValueError):
                existing = None
            if existing != values["alpn"]:
                changes["alpn"] = json.dumps(values["alpn"], separators=(",", ":"))
        if changes:
            candidates.append((host_id, inbound_id, changes))
    return candidates, skipped, "updated_at" in columns


def synchronize(path, selected=None, excluded=None, dry_run=False):
    path = Path(path).resolve()
    if not path.is_file():
        raise InheritanceError("database not found; no database will be created")
    selected, excluded = selected or set(), excluded or set()
    uri = path.as_uri()
    with closing(sqlite3.connect(uri + "?mode=ro", uri=True, timeout=2)) as conn:
        conn.execute("PRAGMA query_only=ON")
        conn.execute("BEGIN")
        changes, skipped, _ = read_candidates(conn, selected, excluded)
    if dry_run or not changes:
        return changes, skipped
    # Re-read under the write lock: a form save or atomic restore may have
    # happened since planning. Never apply stale source values.
    with closing(sqlite3.connect(uri + "?mode=rw", uri=True, timeout=2)) as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            changes, skipped, has_timestamp = read_candidates(conn, selected, excluded)
            for host_id, _, values in changes:
                assignments = [name + "=?" for name in values]
                params = list(values.values())
                if has_timestamp:
                    assignments.append("updated_at=?")
                    params.append(int(time.time() * 1000))
                params.append(host_id)
                conn.execute("UPDATE hosts SET " + ",".join(assignments) + " WHERE id=?", params)
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
    return changes, skipped


def enabled(value):
    return str(value).lower() in ("true", "1", "yes", "on")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=os.environ.get("XUI_DB_PATH", "/etc/x-ui/x-ui.db"))
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()
    if not enabled(os.environ.get("XUI_HOSTS_INHERIT_TLS", "false")):
        print("[SKIP] Live TLS inheritance requires XUI_HOSTS_INHERIT_TLS=true", flush=True)
        return 0
    if args.interval < 0.25 or args.interval > 60:
        parser.error("interval must be between 0.25 and 60 seconds")
    try:
        selected = parse_ids(os.environ.get("XUI_HOSTS_INHERIT_TLS_HOST_IDS", ""))
        excluded = parse_ids(os.environ.get("XUI_HOSTS_INHERIT_TLS_EXCLUDE", ""))
    except InheritanceError as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last_warning = None
    while running:
        try:
            changes, skipped = synchronize(args.db, selected, excluded, args.dry_run)
            for host_id, inbound_id, values in changes:
                label = "PLAN" if args.dry_run else "CHANGE"
                print(f"[{label}] Host {host_id} <- inbound {inbound_id}: "
                      + ",".join(values) + "; explicit values only; no restart", flush=True)
            warning = tuple(skipped)
            if warning != last_warning:
                for host_id, inbound_id, reason in skipped:
                    print(f"[SKIP] Host {host_id}, inbound {inbound_id}: {reason}", flush=True)
            last_warning = warning
            if not args.watch:
                print(f"[SUMMARY] Hosts to change/changed: {len(changes)}; no inbound/service changes", flush=True)
        except (sqlite3.Error, InheritanceError) as error:
            # Do not echo sqlite payloads or client secrets in a daemon log.
            detail = str(error) if isinstance(error, InheritanceError) else "check DB path/schema/lock"
            warning = (type(error).__name__, detail)
            if warning != last_warning:
                print(f"[WARN] Inheritance paused ({type(error).__name__}): {detail}", flush=True)
            last_warning = warning
            if not args.watch:
                return 1
        if not args.watch or args.dry_run:
            break
        time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
