"""Read-only route selection and nginx rendering, using only synthetic panel DBs."""

import hashlib
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "decoy"))
from reality_routes import RouteError, load_routes, parse_ids, render_routes


class RealityRouteTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="reality-routes-")
        self.db = Path(self.scratch.name) / "panel.db"
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, enable INTEGER, "
                         "protocol TEXT, listen TEXT, port INTEGER, stream_settings TEXT)")

    def tearDown(self):
        self.scratch.cleanup()

    def add(self, inbound_id=1, network="ws", path="/ws", port=12001, listen="127.0.0.1",
            enabled=1, protocol="vless", security="none", stream=None):
        keys = {"ws": "wsSettings", "xhttp": "xhttpSettings", "grpc": "grpcSettings",
                "splithttp": "splithttpSettings", "httpupgrade": "httpupgradeSettings",
                "upgrade": "upgradeSettings"}
        if stream is None:
            stream = {"network": network, "security": security,
                      keys.get(network, "otherSettings"):
                          {"serviceName" if network == "grpc" else "path": path}}
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("INSERT INTO inbounds VALUES (?, ?, ?, ?, ?, ?)",
                         (inbound_id, enabled, protocol, listen, port, json.dumps(stream)))

    def load(self, ids="1"):
        return load_routes(self.db, parse_ids(ids), 10444)

    def test_explicit_ids_only_and_database_is_unchanged(self):
        self.add()
        self.add(inbound_id=2, path="/not-selected", port=12002)
        before = self.db.read_bytes()
        stamp = self.db.stat().st_mtime_ns
        routes = self.load()
        self.assertEqual([route.inbound_id for route in routes], [1])
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(self.db.stat().st_mtime_ns, stamp)

    def test_empty_selection_does_not_even_require_a_database(self):
        missing = self.db.parent / "missing.db"
        self.assertEqual(load_routes(missing, [], 10444), [])
        self.assertFalse(missing.exists())

    def test_missing_database_is_not_created(self):
        missing = self.db.parent / "missing.db"
        with self.assertRaises(RouteError):
            load_routes(missing, [1], 10444)
        self.assertFalse(missing.exists())

    def test_all_supported_web_transports(self):
        networks = ["ws", "httpupgrade", "upgrade", "xhttp", "splithttp", "grpc"]
        for index, network in enumerate(networks, 1):
            self.add(index, network, f"/route{index}", port=12000 + index)
        routes = self.load(",".join(str(index) for index in range(1, 7)))
        text = render_routes(routes)
        self.assertIn("grpc_pass grpc://127.0.0.1:12006;", text)
        self.assertIn("location ^~ /route6/", text)
        self.assertIn("proxy_set_header Upgrade $http_upgrade;", text)
        self.assertIn("proxy_request_buffering off;", text)
        self.assertNotIn("proxy_add_x_forwarded_for", text)

    def test_query_hints_do_not_change_upstream_uri(self):
        self.add(path="/socket?ed=2048")
        text = render_routes(self.load())
        self.assertIn("location ^~ /socket {", text)
        self.assertIn("proxy_pass http://127.0.0.1:12001;", text)
        self.assertNotIn("ed=", text)

    def test_ipv6_loopback_is_bracketed(self):
        self.add(listen="::1")
        self.assertIn("http://[::1]:12001;", render_routes(self.load()))

    def test_bad_id_lists_are_rejected(self):
        for value in ("1,1", "0", "-1", "1, 2", "1;DROP TABLE inbounds", "1,", "9" * 30):
            with self.subTest(value=value), self.assertRaises(RouteError):
                parse_ids(value)

    def test_disabled_public_tls_and_non_http_inbounds_are_rejected(self):
        cases = [{"enabled": 0}, {"listen": ""}, {"listen": "0.0.0.0"},
                 {"listen": "192.168.1.2"}, {"security": "tls"},
                 {"security": "reality"}, {"protocol": "mtproto"},
                 {"protocol": "hysteria"}, {"network": "tcp"},
                 {"port": 443}, {"port": 10444}, {"port": 70000}]
        for index, options in enumerate(cases, 1):
            with self.subTest(options=options):
                self.add(inbound_id=index, **options)
                with self.assertRaises(RouteError):
                    self.load(str(index))

    def test_unsafe_paths_are_rejected(self):
        paths = ["/", "", "/api;}", "/a\nlocation /", "/a/$host", "/a/../b",
                 "/.well-known", "/a//b", "/a/%2f", "relative"]
        for index, path in enumerate(paths, 1):
            with self.subTest(path=path):
                self.add(index, path=path)
                with self.assertRaises(RouteError):
                    self.load(str(index))

    def test_duplicate_and_overlapping_paths_are_rejected(self):
        self.add(1, path="/api")
        self.add(2, network="xhttp", path="/api/upload", port=12002)
        with self.assertRaises(RouteError):
            self.load("1,2")

    def test_unknown_id_and_malformed_stream_are_rejected(self):
        with self.assertRaises(RouteError):
            self.load("999")
        for index, stream in enumerate(([1], {"network": "ws", "security": {}},
                                         {"network": "ws", "wsSettings": []}), 1):
            self.add(index, stream=stream)
            with self.assertRaises(RouteError):
                self.load(str(index))

    def test_read_only_wal_snapshot_includes_committed_changes(self):
        with closing(sqlite3.connect(self.db)) as writer, writer:
            writer.execute("PRAGMA journal_mode=WAL")
            self.add()
            before = hashlib.sha256(self.db.read_bytes()).hexdigest()
            self.assertEqual(self.load()[0].inbound_id, 1)
            self.assertEqual(hashlib.sha256(self.db.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
