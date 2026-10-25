"""Read-only SNI plans and actual HAProxy passthrough, without system services."""

from contextlib import closing
import importlib.util
import json
from pathlib import Path
import shutil
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sni_routes", ROOT / "decoy/sni_routes.py")
sni = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sni
spec.loader.exec_module(sni)


class SniRouterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sni-router-")
        self.base = Path(self.temp.name)
        self.db = self.base / "panel.db"
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY,enable INTEGER,listen TEXT,"
                         "port INTEGER,protocol TEXT,stream_settings TEXT)")
            conn.execute("CREATE TABLE hosts (id INTEGER PRIMARY KEY,inbound_id INTEGER,port INTEGER,"
                         "security TEXT,sni TEXT,is_disabled INTEGER)")

    def tearDown(self):
        self.temp.cleanup()

    def add(self, inbound_id=4, port=10443, domain="studio.example.com", listen="127.0.0.1",
            proxy=True, security="reality", target="/run/x-ui-selfsteal/https.sock"):
        stream = {"network": "tcp", "security": security, "sockopt": {"acceptProxyProtocol": proxy},
                  "realitySettings": {"serverNames": [domain], "target": target, "xver": 1}}
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("INSERT INTO inbounds VALUES (?,1,?,?,'vless',?)",
                         (inbound_id, listen, port, json.dumps(stream)))
            conn.execute("INSERT INTO hosts VALUES (?,?,443,'reality',?,0)",
                         (inbound_id, inbound_id, domain))

    def test_read_only_plan_keeps_database_bytes(self):
        self.add()
        self.add(13, 8443, "media.example.com")
        before = self.db.read_bytes()
        routes = sni.load_routes(self.db, [4, 13])
        self.assertEqual(self.db.read_bytes(), before)
        config = sni.render_config(routes)
        self.assertIn("studio.example.com", config)
        self.assertIn("media.example.com", config)
        self.assertIn("127.0.0.1:10443 send-proxy", config)
        self.assertIn("127.0.0.1:8443 send-proxy", config)
        self.assertNotIn(" ssl ", config)
        self.assertNotIn("bind :80", config)

    def test_public_listen_proxy_mismatch_and_looping_ports_are_rejected(self):
        cases = ({"listen": ""}, {"listen": "0.0.0.0"}, {"proxy": False},
                 {"port": 443}, {"port": 10444}, {"security": "tls"},
                 {"target": "some.example.com:443"}, {"domain": "bad.example.com;"})
        for index, options in enumerate(cases, 1):
            with self.subTest(options=options):
                self.add(inbound_id=index, **options)
                with self.assertRaises(sni.RouterError):
                    sni.load_routes(self.db, [index])

    def test_duplicate_sni_is_not_silently_sent_to_first_inbound(self):
        self.add()
        self.add(13, 8443)
        with self.assertRaises(sni.RouterError):
            sni.load_routes(self.db, [4, 13])

    def test_missing_database_and_invalid_selection_do_not_create_files(self):
        missing = self.base / "missing.db"
        with self.assertRaises(sni.RouterError):
            sni.load_routes(missing, [4])
        self.assertFalse(missing.exists())
        self.assertEqual(sni.parse_ids(""), [])
        for ids in ("4,4", "4;rm", "4, 13", "0"):
            with self.subTest(ids=ids), self.assertRaises(sni.RouterError):
                sni.parse_ids(ids)

    def test_auto_discovery_uses_prepared_hosts_without_rewriting_them(self):
        self.add()
        self.add(13, 8443, "media.example.com")
        self.add(6, 51351, "reserve.example.com", listen="")
        before = self.db.read_bytes()
        routes = sni.load_routes(self.db, [])
        self.assertEqual([route.inbound_id for route in routes], [4, 13])
        self.assertEqual(self.db.read_bytes(), before)

    def test_auto_discovery_rejects_sni_mismatch_and_empty_selection(self):
        self.add()
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE hosts SET sni='other.example.com'")
        with self.assertRaises(sni.RouterError):
            sni.load_routes(self.db, [])

    def test_pending_routes_require_exact_managed_tags_and_explicit_mode(self):
        self.add()
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("ALTER TABLE hosts ADD COLUMN tags TEXT")
            conn.execute("UPDATE hosts SET is_disabled=1,tags='[\"fork-managed\",\"fork-pending\"]'")
        with self.assertRaises(sni.RouterError):
            sni.load_routes(self.db, [4])
        self.assertEqual(len(sni.load_routes(self.db, [4], include_managed_pending=True)), 1)
        for value in ("fork-pending", "not-fork-managed,fork-pending", "fork-managed", "[invalid"):
            with self.subTest(value=value):
                with closing(sqlite3.connect(self.db)) as conn, conn:
                    conn.execute("UPDATE hosts SET tags=?", (value,))
                with self.assertRaises(sni.RouterError):
                    sni.load_routes(self.db, [4], include_managed_pending=True)
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE hosts SET is_disabled=1")
        with self.assertRaises(sni.RouterError):
            sni.load_routes(self.db, [])

    @unittest.skipUnless(shutil.which("haproxy") and shutil.which("openssl"), "requires haproxy and openssl")
    def test_real_sni_passthrough_selects_two_backends_and_sends_proxy_header(self):
        cert, key = self.base / "site.pem", self.base / "site.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(cert), "-days", "2",
                        "-subj", "/CN=studio.example.com", "-addext",
                        "subjectAltName=DNS:studio.example.com,DNS:media.example.com",
                        "-addext", "basicConstraints=critical,CA:TRUE",
                        "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign"],
                       check=True, capture_output=True)
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(cert, key)
        received = []

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(5)
                proxy = b""
                while not proxy.endswith(b"\r\n") and len(proxy) < 256:
                    chunk = self.request.recv(1)
                    if not chunk:
                        return
                    proxy += chunk
                received.append(proxy)
                with server_context.wrap_socket(self.request, server_side=True) as tls:
                    tls.recv(4096)
                    payload = self.server.label.encode()
                    tls.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
                                + str(len(payload)).encode() + b"\r\n\r\n" + payload)

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        servers = []
        for label in ("finland", "bypass"):
            server = Server(("127.0.0.1", 0), Handler)
            server.label = label
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            servers.append(server)
        routes = [sni.Route(4, "studio.example.com", "127.0.0.1", servers[0].server_address[1]),
                  sni.Route(13, "media.example.com", "127.0.0.1", servers[1].server_address[1])]
        with socket.socket() as free:
            free.bind(("127.0.0.1", 0))
            port = free.getsockname()[1]
        config = self.base / "haproxy.cfg"
        config.write_text(sni.render_config(routes).replace("bind :443", f"bind 127.0.0.1:{port}"))
        validation = subprocess.run(["haproxy", "-c", "-f", str(config)], capture_output=True, text=True)
        self.assertEqual(validation.returncode, 0, validation.stderr)
        proxy = subprocess.Popen(["haproxy", "-db", "-f", str(config)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            import time
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    probe = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                    probe.close()
                    break
                except OSError:
                    time.sleep(0.05)
            client_context = ssl.create_default_context(cafile=str(cert))
            for domain, label in (("studio.example.com", b"finland"), ("media.example.com", b"bypass")):
                with socket.create_connection(("127.0.0.1", port), timeout=5) as conn:
                    with client_context.wrap_socket(conn, server_hostname=domain) as tls:
                        tls.sendall(f"GET / HTTP/1.1\r\nHost: {domain}\r\nConnection: close\r\n\r\n".encode())
                        response = b""
                        while True:
                            chunk = tls.recv(4096)
                            if not chunk:
                                break
                            response += chunk
                        self.assertTrue(response.endswith(label), response)
            with mock.patch.object(sni.ssl, "create_default_context", return_value=client_context):
                sni.check_backends(routes)
            self.assertEqual(len(received), 4)
            self.assertTrue(all(header.startswith(b"PROXY TCP4 ") for header in received))
        finally:
            proxy.terminate()
            proxy.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
