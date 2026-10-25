#!/usr/bin/env python3
"""Opt-in native panel -> managed Hosts -> SelfSteal/SNI controller (stdlib only).

Integration contract
--------------------
Controller.plan() is read-only. Controller.run_once(dry_run=False) requires the
literal environment value XUI_PANEL_CONTROLLER_ENABLE=true. The default runtime
check requires root, Linux/systemd and no Docker/container marker. Tests inject
runner(argv, env), health(routes), and native_check(); no shell is ever used.
Workers receive XUI_DB_PATH, explicit domain/ID lists and XUI_AUTO_DB_APPLY=false:
  decoy-setup.sh certificate
  decoy-setup.sh apply                 # safe reload when already active
  sni-router.sh apply --managed-pending
The last flag MUST include only fork-managed,fork-pending disabled Hosts, never
ordinary disabled Hosts. Wrappers must preserve the supplied DB/domain/ID scope
when sourcing their environment. This file does not implement those wrappers.

Safety exceptions / intentionally limited reconciliation
-------------------------------------------------------
* Invalid prepared candidates/duplicate SNI abort the entire pass, not a subset.
* No inbound writes, manual Host writes, deletes, migrations or garbage collection.
  Removed/disabled inbounds and obsolete managed Hosts require manual cleanup;
  an empty plan does not tear down the last working site/router configuration.
* An explicitly disabled managed Host suppresses its entire inbound: the existing
  router parser routes ALL serverNames of a selected inbound, not a subset.
* No durable undo journal: a crash after staging leaves disabled pending rows for
  a later retry. Rollback only restores existing rows still equal to our stage;
  newly inserted rows remain disabled/pending. CA/site/router effects cannot be
  rolled back transactionally. User edits or DB/state replacement stop publication.
* State stores only public-field digests and DB device/inode, never streams,
  keys, client IDs or rollback snapshots. Secret-only edits do not trigger work.
  Missing state is a cold start: CA/site/health/router are checked again. Source
   guards include in-memory configuration rows. Inbound up/down counters are
   excluded so normal live traffic cannot starve certificate reconciliation.
* DB replacement is detected at phase/transaction boundaries, not serialized
  against an uncooperative atomic restore during a SQLite commit. Stop the worker
  before restoring databases. An ABA edit restored byte-for-byte is undetectable
  without a panel revision counter (updated_at is checked when present).
* Only DB rows change: panel caches/subscriptions may require their own refresh.
  Renewal scheduling, DNS, service units and safe worker reloads are external.
"""

import argparse
from contextlib import closing, contextmanager
from dataclasses import dataclass, field
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from decoy.sni_routes import Route, check_backends, valid_domain


def _inheritance_module():
    spec = importlib.util.spec_from_file_location(
        "panel_controller_tls", Path(__file__).with_name("hosts-tls-inherit.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_tls = _inheritance_module()
MANAGED, PENDING = "fork-managed", "fork-pending"
REQUIRED = {"id", "inbound_id", "address", "port", "security", "sni",
            "path", "host_header", "fingerprint", "alpn", "tags", "is_disabled"}
# Only these names can appear in INSERT/UPDATE, regardless of DB schema contents.
WRITABLE = REQUIRED - {"id"} | {
    "group_id", "sort_order", "remark", "server_description", "is_hidden",
    "override_sni_from_address", "keep_sni_blank", "pinned_peer_cert_sha256",
    "verify_peer_cert_by_name", "allow_insecure", "ech_config_list", "mux_params",
    "sockopt_params", "final_mask", "vless_route", "exclude_from_sub_types",
    "mihomo_ip_version", "mihomo_x25519", "shuffle_host", "node_guids",
    "created_at", "updated_at"}
INSERT_FALLBACKS = dict.fromkeys(WRITABLE, "")
INSERT_FALLBACKS.update(dict.fromkeys({"sort_order", "is_hidden",
    "override_sni_from_address", "keep_sni_blank", "allow_insecure",
    "mihomo_x25519", "shuffle_host"}, 0))
INSERT_FALLBACKS.update(alpn="[]", pinned_peer_cert_sha256="[]")
PUBLIC_HOST = ("inbound_id", "address", "port", "security", "sni", "path",
               "host_header", "fingerprint", "alpn")


class ControllerError(ValueError):
    """Only fixed, non-payload-bearing messages may escape to daemon logs."""


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=True).encode()).hexdigest()


def tags(value):
    if value is None or value == "":
        return []
    if not isinstance(value, str):
        raise ControllerError("invalid Host tags")
    if value.lstrip().startswith("["):
        try:
            result = json.loads(value)
        except ValueError:
            raise ControllerError("invalid Host tags") from None
        if not isinstance(result, list) or any(not isinstance(x, str) for x in result):
            raise ControllerError("invalid Host tags")
        return result
    return [x.strip() for x in value.split(",") if x.strip()]


def with_pending(value, pending):
    result = [x for x in tags(value) if x != PENDING]
    if MANAGED not in result:
        raise ControllerError("Host ownership was removed")
    if pending:
        result.append(PENDING)
    if isinstance(value, str) and value.lstrip().startswith("["):
        return json.dumps(result, separators=(",", ":"))
    return ",".join(result)


def identity(path):
    info = Path(path).stat()
    if not stat.S_ISREG(info.st_mode):
        raise ControllerError("database is not a regular file")
    return info.st_dev, info.st_ino


@contextmanager
def pinned_database(path):
    # Retain the old inode until the pass ends, so unlink/recreate cannot reuse
    # its number and disguise an atomic restore as the original database.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        token = info.st_dev, info.st_ino
        if not stat.S_ISREG(info.st_mode) or identity(path) != token:
            raise ControllerError("database replaced/unsafe while opening")
        yield token
    finally:
        os.close(fd)


@contextmanager
def database(path, writable=False):
    path = Path(path).absolute()
    # mode=rw cannot create a missing database (unlike sqlite's default mode).
    if not path.is_file() or path.is_symlink():
        raise ControllerError("database missing/unsafe; no database is created")
    with closing(sqlite3.connect(path.as_uri() + ("?mode=rw" if writable else "?mode=ro"),
                                uri=True, timeout=3)) as conn:
        conn.row_factory = sqlite3.Row
        if not writable:
            conn.execute("PRAGMA query_only=ON")
        conn.execute("BEGIN IMMEDIATE" if writable else "BEGIN")
        try:
            yield conn
            if writable:
                conn.commit()
        except BaseException:
            conn.rollback()
            raise


def snapshot(conn):
    schema = [tuple(row) for row in conn.execute("PRAGMA table_info(hosts)")]
    if not REQUIRED <= {row[1] for row in schema}:
        raise ControllerError("required Hosts columns are missing")
    # Full snapshots are in memory only, never hashed, logged or serialized.
    inbounds = [{key: row[key] for key in row.keys() if key not in ("up", "down")}
                for row in conn.execute("SELECT * FROM inbounds ORDER BY id")]
    hosts = [dict(row) for row in conn.execute("SELECT * FROM hosts ORDER BY id")]
    return schema, inbounds, hosts


def text(value):
    if (not isinstance(value, str) or len(value) > 4096 or any(
            ord(c) < 32 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise ControllerError("invalid public transport field")
    return value


def transport_fields(stream):
    network = stream["network"]
    alias = {"tcp": "raw", "raw": "tcp", "xhttp": "splithttp",
             "splithttp": "xhttp"}.get(network)
    key, alias_key = network + "Settings", (alias + "Settings" if alias else None)
    if alias_key in stream and key in stream and stream[key] != stream[alias_key]:
        raise ControllerError("ambiguous transport alias settings")
    options = stream.get(key, stream.get(alias_key, {}))
    if not isinstance(options, dict):
        raise ControllerError("invalid transport settings")
    if network in ("xhttp", "splithttp"):
        return {"path": text(options.get("path", "")),
                "host_header": text(options.get("host", ""))}
    if network == "grpc":
        # Panel encodes gRPC serviceName in hosts.path, authority in host_header.
        return {"path": text(options.get("serviceName", "")),
                "host_header": text(options.get("authority", ""))}
    header = options.get("header", {})
    if not isinstance(header, dict):
        raise ControllerError("invalid TCP header")
    if header.get("type", "none") == "none":
        return {"path": "", "host_header": ""}
    if header.get("type") != "http":
        raise ControllerError("unsupported TCP header")
    request = header.get("request", {})
    if not isinstance(request, dict) or not isinstance(request.get("headers", {}), dict):
        raise ControllerError("invalid TCP request header")
    paths = request.get("path", ["/"])
    headers = request.get("headers", {})
    names = headers.get("Host", headers.get("host", [""]))
    if (not isinstance(paths, list) or len(paths) != 1 or
            not isinstance(names, list) or len(names) != 1):
        raise ControllerError("multi-value TCP path/Host cannot be represented safely")
    return {"path": text(paths[0]), "host_header": text(names[0])}


@dataclass
class HostAction:
    inbound_id: int
    domain: str
    host_id: object
    values: dict


@dataclass
class Plan:
    routes: list
    actions: list
    skipped: list
    db_identity: tuple
    site_digest: str
    router_digest: str
    host_digest: str
    source: tuple = field(repr=False)

    def summary(self):
        return {"routes": len(self.routes), "changes": len(self.actions),
                "skipped": self.skipped}


def build_plan(conn, db_identity, backend_port):
    source = snapshot(conn)
    schema, inbounds, hosts = source
    routes, actions, skipped, public_hosts = [], [], [], []
    seen = set()
    for inbound in inbounds:
        if inbound.get("enable") != 1 or inbound.get("protocol") != "vless":
            continue
        try:
            stream = json.loads(inbound.get("stream_settings") or "{}")
        except (ValueError, TypeError):
            raise ControllerError("active VLESS has invalid stream settings") from None
        if not isinstance(stream, dict):
            raise ControllerError("active VLESS stream is not an object")
        if stream.get("security") != "reality":
            continue
        inbound_id, address, port = inbound["id"], inbound.get("listen"), inbound.get("port")
        if address not in ("127.0.0.1", "::1"):
            # Direct/public profiles are outside this controller's ownership.
            # They must not block already prepared loopback profiles.
            skipped.append(inbound_id)
            continue
        if (address not in ("127.0.0.1", "::1") or type(port) is not int or
                not 1024 <= port <= 65535 or port in (443, backend_port)):
            raise ControllerError("REALITY requires a prepared non-looping loopback port")
        if stream.get("network") not in ("tcp", "raw", "xhttp", "splithttp", "grpc"):
            raise ControllerError("unsupported REALITY transport")
        reality, sockopt = stream.get("realitySettings"), stream.get("sockopt")
        if (not isinstance(reality, dict) or not isinstance(sockopt, dict) or
                reality.get("target") != "/run/x-ui-selfsteal/https.sock" or
                type(reality.get("xver")) is not int or reality["xver"] != 1 or
                sockopt.get("acceptProxyProtocol") is not True):
            raise ControllerError("REALITY Unix target/xver/PROXY preparation required")
        names = reality.get("serverNames")
        if (not isinstance(names, list) or not names or
                any(not valid_domain(name) for name in names)):
            raise ControllerError("invalid or missing REALITY DNS serverNames")
        names = sorted(name.lower() for name in names)
        for name in names:
            if name in seen:
                raise ControllerError("duplicate REALITY DNS serverName")
            seen.add(name)
        values = transport_fields(stream)
        try:
            explicit = _tls.explicit_values(inbound.get("stream_settings"), "reality")
        except _tls.InheritanceError:
            raise ControllerError("invalid explicit fingerprint/ALPN") from None
        values.update(explicit)
        if "alpn" in values:
            values["alpn"] = json.dumps(values["alpn"], separators=(",", ":"))
        own = [h for h in hosts if h["inbound_id"] == inbound_id and MANAGED in tags(h["tags"])]
        # Never bypass a user's explicit disable by inserting a replacement Host.
        if any(h["is_disabled"] == 1 and PENDING not in tags(h["tags"]) for h in own):
            skipped.append(inbound_id)
            continue
        for name in names:
            matching = [h for h in hosts if h["inbound_id"] == inbound_id and
                        str(h["sni"] or "").lower() == name and h["port"] == 443]
            manual = [h for h in matching if MANAGED not in tags(h["tags"]) and
                      h["is_disabled"] in (0, None) and h["security"] in ("reality", "same", "")]
            if manual:
                # Use read-only, even if its address/fingerprint differ from inbound.
                public_hosts.extend({k: h[k] for k in PUBLIC_HOST} for h in manual)
            else:
                managed = [h for h in own if str(h["sni"] or "").lower() == name]
                if not managed and len(names) == 1 and len(own) == 1:
                    # Common rename: keep the identity of the uniquely owned
                    # Host instead of leaving an obsolete published duplicate.
                    managed = own
                if len(managed) > 1:
                    raise ControllerError("ambiguous managed Hosts for one SNI")
                host = managed[0] if managed else None
                desired = dict(values, inbound_id=inbound_id, address=name, port=443,
                               security="reality", sni=name)
                effective = {k: (host[k] if host else None) for k in PUBLIC_HOST}
                effective.update(desired)
                public_hosts.append(effective)
                if host is None or any(host[k] != v for k, v in desired.items()) or PENDING in tags(host["tags"]):
                    # Fail before certificate calls for unrepresentable mandatory columns.
                    if host is None:
                        for _, column, _, notnull, default, pk in schema:
                            if notnull and default is None and not pk and column not in WRITABLE:
                                raise ControllerError("unknown mandatory Host column without a default")
                    actions.append(HostAction(inbound_id, name, host["id"] if host else None, desired))
            routes.append(Route(inbound_id, name, address, port))
    route_fields = [[r.inbound_id, r.domain, r.address, r.port] for r in routes]
    return Plan(routes, actions, skipped, db_identity,
                digest({"domains": sorted(r.domain for r in routes), "fallback_port": backend_port}),
                digest({"routes": route_fields, "fallback_port": backend_port}),
                digest(public_hosts), source)


def run_command(argv, env):
    # Do not leak worker output (which may contain credentials) into daemon logs.
    command = [shutil.which("bash") or "/bin/bash", *argv] if argv[0].endswith(".sh") else argv
    return subprocess.run(command, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=600, check=True)


def native_runtime():
    return (os.geteuid() == 0 and sys.platform.startswith("linux") and
            Path("/run/systemd/system").is_dir() and shutil.which("systemctl") is not None and
            not Path("/.dockerenv").exists() and not Path("/run/.containerenv").exists())


class StateStore:
    """Root-owned in production; effective-UID ownership permits isolated tests."""

    def __init__(self, directory):
        self.directory = Path(directory).absolute()
        self.path = self.directory / "state.json"
        self.token = None
        self.lock_fd = None
        self.state_fd = None

    def secure(self, path, directory=False):
        info = path.lstat()
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if (not expected(info.st_mode) or info.st_uid != os.geteuid() or
                stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600) or
                (not directory and info.st_nlink != 1)):
            raise ControllerError("unsafe controller state ownership/mode/type")
        return info

    def current_token(self):
        try:
            info = self.secure(self.path)
        except FileNotFoundError:
            return None
        return info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns, info.st_size

    def pin_state(self):
        if self.state_fd is not None:
            os.close(self.state_fd)
            self.state_fd = None
        if self.token is not None:
            self.state_fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
            info = os.fstat(self.state_fd)
            if (info.st_dev, info.st_ino) != self.token[:2]:
                raise ControllerError("controller state was replaced while opening")

    def check(self):
        self.secure(self.directory, directory=True)
        if self.current_token() != self.token:
            raise ControllerError("controller state was replaced; retry with a fresh plan")
        info = self.secure(self.directory / "controller.lock")
        opened = os.fstat(self.lock_fd)
        if (info.st_dev, info.st_ino) != (opened.st_dev, opened.st_ino):
            raise ControllerError("controller lock was replaced")

    @contextmanager
    def locked(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.secure(self.directory, directory=True)
        lock_path = self.directory / "controller.lock"
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        self.lock_fd = fd
        try:
            self.secure(lock_path)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ControllerError("another controller is running") from None
            self.token = self.current_token()
            self.pin_state()
            self.check()
            yield
        finally:
            if self.state_fd is not None:
                os.close(self.state_fd)
                self.state_fd = None
            self.lock_fd = None
            os.close(fd)

    def load(self):
        self.check()
        if self.token is None:
            return {}
        fd = os.dup(self.state_fd)
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            handle.seek(0)
            try:
                state = json.load(handle)
            except (ValueError, UnicodeError):
                raise ControllerError("invalid controller state") from None
        self.check()
        if not isinstance(state, dict) or state.get("version") != 1:
            raise ControllerError("unsupported controller state")
        return state

    def save(self, value):
        self.check()
        fd, name = tempfile.mkstemp(prefix=".state-", dir=self.directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump(value, handle, sort_keys=True, separators=(",", ":"))
                handle.flush()
                os.fsync(handle.fileno())
            self.check()
            os.replace(name, self.path)
            self.token = self.current_token()
            self.pin_state()
            directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(name):
                os.unlink(name)


@dataclass
class Stage:
    before: dict = field(repr=False)
    after: dict = field(repr=False)
    expected_source: tuple = field(repr=False)


class Controller:
    def __init__(self, db, state_dir, scripts_dir, *, env=None, runner=run_command,
                 health=check_backends, native_check=native_runtime):
        self.db = Path(db).absolute()
        self.store = StateStore(state_dir)
        self.scripts_dir = Path(scripts_dir).absolute()
        self.env = dict(os.environ if env is None else env)
        self.runner, self.health, self.native_check = runner, health, native_check
        try:
            self.backend_port = int(self.env.get("XUI_SELFSTEAL_PORT", "10444"))
        except (ValueError, TypeError):
            raise ControllerError("invalid SelfSteal port") from None
        if not 1024 <= self.backend_port <= 65535:
            raise ControllerError("invalid SelfSteal port")

    def plan(self):
        before = identity(self.db)
        with database(self.db) as conn:
            result = build_plan(conn, before, self.backend_port)
            if identity(self.db) != before:
                raise ControllerError("database was replaced while planning")
        return result

    def check_context(self, plan):
        self.store.check()
        if identity(self.db) != plan.db_identity:
            raise ControllerError("database was replaced; refusing stale work")

    def guard(self, conn, plan, expected):
        self.check_context(plan)
        if snapshot(conn) != expected:
            raise ControllerError("source changed; refusing stale plan/publication")

    def update(self, conn, host_id, values, expected):
        if not values or not values.keys() <= WRITABLE:
            raise ControllerError("non-whitelisted Host write")
        # Full expected row checked under BEGIN IMMEDIATE; timestamp is an extra
        # SQL-level optimistic guard, not the only defense (it can have ms ties).
        where, params = "id=?", [host_id]
        if "updated_at" in expected:
            where += " AND updated_at IS ?"
            params.append(expected["updated_at"])
        cursor = conn.execute("UPDATE hosts SET " + ",".join(k + "=?" for k in values) +
                              " WHERE " + where, list(values.values()) + params)
        if cursor.rowcount != 1:
            raise ControllerError("Host optimistic guard failed")

    def timestamp(self, row):
        now = time.time_ns() // 1_000_000
        previous = row.get("updated_at")
        return max(now, previous + 1) if type(previous) is int else now

    def stage(self, plan):
        before, after = {}, {}
        with database(self.db, writable=True) as conn:
            self.guard(conn, plan, plan.source)
            schema = plan.source[0]
            columns = {row[1] for row in schema}
            for action in plan.actions:
                values = dict(action.values, is_disabled=1)
                if action.host_id is None:
                    values["tags"] = MANAGED + "," + PENDING
                    for _, name, _, notnull, default, pk in schema:
                        if name not in values and notnull and default is None and not pk:
                            if name not in INSERT_FALLBACKS:
                                raise ControllerError("unsupported required Host column")
                            values[name] = INSERT_FALLBACKS[name]
                    if "group_id" in columns:
                        values["group_id"] = uuid.uuid4().hex
                    for name in ("created_at", "updated_at"):
                        if name in columns:
                            values[name] = self.timestamp({})
                    if not values.keys() <= WRITABLE:
                        raise ControllerError("non-whitelisted Host insert")
                    cursor = conn.execute("INSERT INTO hosts (" + ",".join(values) +
                        ") VALUES (" + ",".join("?" for _ in values) + ")", list(values.values()))
                    host_id = cursor.lastrowid
                    before[host_id] = None
                else:
                    host_id = action.host_id
                    old = dict(conn.execute("SELECT * FROM hosts WHERE id=?", (host_id,)).fetchone())
                    if MANAGED not in tags(old["tags"]):
                        raise ControllerError("Host ownership was removed")
                    before[host_id] = old
                    values["tags"] = with_pending(old["tags"], True)
                    if "updated_at" in columns:
                        values["updated_at"] = self.timestamp(old)
                    self.update(conn, host_id, values, old)
                after[host_id] = dict(conn.execute("SELECT * FROM hosts WHERE id=?", (host_id,)).fetchone())
            expected = snapshot(conn)
            self.check_context(plan)
        return Stage(before, after, expected)

    def publish(self, plan, stage):
        with database(self.db, writable=True) as conn:
            self.guard(conn, plan, stage.expected_source)
            for host_id, expected in stage.after.items():
                if MANAGED not in tags(expected["tags"]) or PENDING not in tags(expected["tags"]):
                    raise ControllerError("pending Host ownership required")
                values = {"is_disabled": 0, "tags": with_pending(expected["tags"], False)}
                if "updated_at" in expected:
                    values["updated_at"] = self.timestamp(expected)
                self.update(conn, host_id, values, expected)
            # Store the actual public projection, including schema defaults used
            # for new rows, not the pre-insert projection with missing values.
            published = build_plan(conn, plan.db_identity, self.backend_port)
            if published.actions:
                raise ControllerError("published Host fields differ from the approved plan")
            self.check_context(plan)
        return published.host_digest

    def rollback(self, plan, stage):
        # Do not touch a replacement DB/state, even if row IDs happen to match.
        self.check_context(plan)
        with database(self.db, writable=True) as conn:
            self.check_context(plan)
            for host_id, expected in stage.after.items():
                old = stage.before[host_id]
                if old is None:
                    continue
                row = conn.execute("SELECT * FROM hosts WHERE id=?", (host_id,)).fetchone()
                if row is None or dict(row) != expected or MANAGED not in tags(row["tags"]):
                    continue
                # Restore only columns actually written; unknown/user fields stay untouched.
                values = {k: old[k] for k in WRITABLE if k in old and old[k] != expected[k]}
                if values:
                    self.update(conn, host_id, values, expected)
            self.check_context(plan)

    def worker(self, script, arguments, plan):
        self.check_context(plan)
        env = dict(self.env)
        domains = sorted({route.domain for route in plan.routes})
        primary = env.get("XUI_SELFSTEAL_DOMAIN")
        if primary not in domains:
            first = plan.routes[0]
            inbound = next(row for row in plan.source[1] if row["id"] == first.inbound_id)
            names = json.loads(inbound["stream_settings"])["realitySettings"]["serverNames"]
            primary = next(name.lower() for name in names if name.lower() in domains)
        domains.remove(primary)
        domains.insert(0, primary)
        env.update(XUI_DB_PATH=str(self.db), XUI_AUTO_DB_APPLY="false",
                   XUI_PANEL_CONTROLLER_CONTEXT="1",
                   XUI_SNI_ROUTER_ENABLE="true", XUI_SELFSTEAL_ENABLE="true",
                   XUI_SELFSTEAL_MODE="reality", XUI_SELFSTEAL_PUBLIC="false",
                   XUI_HAPROXY_ENABLE="false", XUI_AUTO_CERTS="false",
                   XUI_REWRITE_INBOUNDS="false", XUI_HOSTS_SYNC="false",
                   XUI_SELFSTEAL_DOMAIN=domains[0],
                   XUI_SELFSTEAL_EXTRA_DOMAINS=",".join(domains[1:]),
                   XUI_SNI_ROUTER_INBOUNDS=",".join(str(n) for n in sorted(
                       {route.inbound_id for route in plan.routes})),
                   XUI_SELFSTEAL_PORT=str(self.backend_port))
        try:
            result = self.runner([str(self.scripts_dir / script)] + arguments, env)
            code = result if type(result) is int else getattr(result, "returncode", 0)
            if code not in (None, 0):
                raise ControllerError("worker returned failure")
        except Exception:
            raise ControllerError("external " + arguments[0] + " phase failed") from None

    def run_once(self, dry_run=False):
        if self.env.get("XUI_PANEL_CONTROLLER_ENABLE") != "true":
            return {"status": "disabled"}
        with pinned_database(self.db) as token:
            plan = self.plan()
            if plan.db_identity != token:
                raise ControllerError("database was replaced; refusing stale plan")
            return self._apply_plan(plan, dry_run)

    def _apply_plan(self, plan, dry_run=False):
        # Internal phase driver. Public entry points are plan() and run_once().
        if dry_run:
            return dict(plan.summary(), status="planned",
                        profiles=[{"inbound": r.inbound_id, "domain": r.domain,
                                   "backend": f"{r.address}:{r.port}"} for r in plan.routes],
                        hosts=[{"inbound": a.inbound_id, "host_id": a.host_id,
                                "domain": a.domain, "fields": sorted(a.values)} for a in plan.actions])
        if not self.native_check():
            raise ControllerError("controller apply requires native root/systemd runtime")
        if not plan.routes:
            return dict(plan.summary(), status="skipped")
        with self.store.locked():
            self.check_context(plan)
            state = self.store.load()
            if state.get("db_identity") != list(plan.db_identity):
                state = {}
            site_changed = state.get("site_digest") != plan.site_digest
            router_changed = state.get("router_digest") != plan.router_digest
            if not plan.actions and not site_changed and not router_changed:
                return dict(plan.summary(), status="noop")
            if site_changed:
                self.worker("decoy-setup.sh", ["certificate"], plan)
                self.worker("decoy-setup.sh", ["apply"], plan)
            if site_changed or router_changed:
                self.check_context(plan)
                try:
                    if self.health(plan.routes) is False:
                        raise ControllerError("backend health failed")
                except Exception:
                    raise ControllerError("backend health failed; Hosts unchanged") from None
            stage = self.stage(plan)
            try:
                if router_changed:
                    self.worker("sni-router.sh", ["apply", "--managed-pending"], plan)
                host_digest = self.publish(plan, stage)
            except BaseException:
                # Preserve the original safe phase error; rollback errors contain no
                # useful payload and must not cause a blind second write attempt.
                try:
                    self.rollback(plan, stage)
                except (OSError, sqlite3.Error, ControllerError):
                    pass
                raise
            self.check_context(plan)
            self.store.save({"version": 1, "db_identity": list(plan.db_identity),
                             "site_digest": plan.site_digest,
                             "router_digest": plan.router_digest,
                             "host_digest": host_digest})
            return dict(plan.summary(), status="applied")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--db", default=os.environ.get("XUI_DB_PATH", "/etc/x-ui/x-ui.db"))
    parser.add_argument("--state-dir", default=os.environ.get(
        "XUI_PANEL_CONTROLLER_STATE_DIR", "/var/lib/x-ui-panel-controller"))
    parser.add_argument("--scripts-dir", default=os.environ.get(
        "XUI_PANEL_CONTROLLER_SCRIPTS_DIR", str(Path(__file__).absolute().parent)))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--watch", action="store_true")
    mode.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args(argv)
    if not 0.25 <= args.interval <= 3600:
        parser.error("interval must be between 0.25 and 3600 seconds")
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    last = None
    failed_token, retry_at, failures = None, 0.0, 0
    while running:
        status = 0
        token = None
        try:
            controller = Controller(args.db, args.state_dir, args.scripts_dir)
            if args.watch and controller.env.get("XUI_PANEL_CONTROLLER_ENABLE") == "true":
                pending = controller.plan()
                token = digest([pending.site_digest, pending.router_digest, pending.host_digest,
                                [[a.inbound_id, a.domain, a.host_id, a.values] for a in pending.actions]])
                if token == failed_token and time.monotonic() < retry_at:
                    time.sleep(args.interval)
                    continue
            result = controller.run_once(args.dry_run)
            failed_token, retry_at, failures = None, 0.0, 0
            message = "[CONTROLLER] " + json.dumps(result, sort_keys=True)
        except (ControllerError, sqlite3.Error, OSError) as error:
            detail = str(error) if isinstance(error, ControllerError) else "DB/state/access failure"
            message, status = "[ERROR] " + detail, 1
            if args.watch:
                failures = failures + 1 if token == failed_token else 1
                failed_token = token
                delay = min(300, 5 * (2 ** min(failures - 1, 6)))
                retry_at = time.monotonic() + delay
                message += f"; unchanged configuration retry in {delay}s"
        if message != last:
            print(message, flush=True)
            last = message
        if not args.watch or args.dry_run:
            return status
        time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
