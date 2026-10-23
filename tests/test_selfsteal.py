"""Isolated SelfSteal checks: no writes to /etc, panel DB or system services.

Run: python3 -m unittest discover -s tests -v
"""

import os
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "decoy-setup.sh"


@unittest.skipUnless(all(shutil.which(tool) for tool in ("bash", "openssl", "nginx", "curl")),
                     "requires bash, openssl, nginx and curl")
class SelfStealTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="selfsteal-tests-")
        cls.base = Path(cls.scratch.name)
        cls.env_file = cls.base / "empty.env"
        cls.env_file.touch()
        cls.site = cls.base / "site"
        cls.site.mkdir()
        (cls.site / "index.html").write_text("selfsteal-test-ok\n")
        cls.ca = cls.base / "ca.pem"
        cls.cert = cls.base / "cert.pem"
        cls.key = cls.base / "key.pem"
        cls.ca_dir = cls.base / "empty-ca-dir"
        cls.ca_dir.mkdir()
        cls.run_command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(cls.base / "ca.key"), "-out", str(cls.ca),
                        "-days", "2", "-subj", "/CN=SelfSteal test CA",
                        "-addext", "basicConstraints=critical,CA:TRUE",
                        "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        cls.run_command("openssl", "req", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(cls.key), "-out", str(cls.base / "leaf.csr"),
                        "-subj", "/CN=edge.example.com")
        extensions = cls.base / "extensions"
        extensions.write_text("subjectAltName=DNS:edge.example.com\n"
                              "extendedKeyUsage=serverAuth\n"
                              "keyUsage=critical,digitalSignature,keyEncipherment\n"
                              "basicConstraints=CA:FALSE\n")
        cls.run_command("openssl", "x509", "-req", "-in", str(cls.base / "leaf.csr"),
                        "-CA", str(cls.ca), "-CAkey", str(cls.base / "ca.key"),
                        "-CAcreateserial", "-out", str(cls.cert), "-days", "2",
                        "-extfile", str(extensions))

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    @staticmethod
    def run_command(*args):
        return subprocess.run(args, check=True, capture_output=True, text=True)

    def environment(self, **overrides):
        env = os.environ.copy()
        # Never import a developer's active .env or settings into these checks.
        for key in list(env):
            if key.startswith("XUI_"):
                del env[key]
        env.update(XUI_ENV_FILE=str(self.env_file), XUI_SELFSTEAL_MODE="reality",
                   XUI_SELFSTEAL_ENABLE="true",
                   XUI_SELFSTEAL_DOMAIN="edge.example.com", XUI_HAPROXY_ENABLE="false",
                   XUI_SELFSTEAL_PUBLIC="false", XUI_SELFSTEAL_CERT_FILE=str(self.cert),
                   XUI_SELFSTEAL_KEY_FILE=str(self.key), SSL_CERT_FILE=str(self.ca),
                   SSL_CERT_DIR=str(self.ca_dir), CURL_CA_BUNDLE=str(self.ca))
        env.update(overrides)
        return env

    def shell(self, body, **overrides):
        return subprocess.run(["bash", "-c", 'source "$1"; ' + body, "test", str(SCRIPT)],
                              env=self.environment(**overrides), capture_output=True, text=True)

    def test_valid_configuration_and_read_only_plan(self):
        result = self.shell("reality_plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/run/x-ui-selfsteal/https.sock", result.stdout)
        self.assertIn("НЕ мигрируют", result.stdout)
        self.assertEqual(self.env_file.read_text(), "")

    def test_conflicting_options_are_rejected(self):
        for options in ({"XUI_HAPROXY_ENABLE": "true"},
                        {"XUI_SELFSTEAL_ENABLE": "false"},
                        {"XUI_SELFSTEAL_PUBLIC": "true"},
                        {"XUI_SELFSTEAL_PORT": "443"},
                        {"XUI_SELFSTEAL_PORT": "999999999999999999999"}):
            with self.subTest(options=options):
                self.assertNotEqual(self.shell("validate_reality_config", **options).returncode, 0)

    def test_invalid_domains_and_nginx_injection_are_rejected(self):
        for domain in ("", "localhost", "*.example.com", "https://edge.example.com",
                       "edge.example.com:443", "edge.example.com;", "edge.example.com\n}"):
            with self.subTest(domain=domain):
                result = self.shell("validate_reality_config", XUI_SELFSTEAL_DOMAIN=domain)
                self.assertNotEqual(result.returncode, 0)

    def test_wrong_hostname_or_missing_certificate_are_rejected(self):
        for options in ({"XUI_SELFSTEAL_DOMAIN": "other.example.com"},
                        {"XUI_SELFSTEAL_CERT_FILE": str(self.base / "missing.pem")},
                        {"XUI_SELFSTEAL_KEY_FILE": str(self.base / "ca.key")}):
            with self.subTest(options=options):
                self.assertNotEqual(self.shell("validate_reality_config", **options).returncode, 0)

    def test_untrusted_certificate_is_rejected(self):
        result = self.shell("validate_reality_config", SSL_CERT_FILE="/dev/null")
        self.assertNotEqual(result.returncode, 0)

    def test_bad_mode_is_rejected(self):
        self.assertNotEqual(self.shell("true", XUI_SELFSTEAL_MODE="typo").returncode, 0)

    def test_legacy_remains_default(self):
        result = self.shell('printf "%s" "$SELFSTEAL_MODE"', XUI_SELFSTEAL_MODE="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "legacy")

    def test_failed_backend_healthcheck_restores_configuration_and_service(self):
        with tempfile.TemporaryDirectory(prefix="rollback-", dir=self.base) as tmp:
            folder = Path(tmp)
            conf = folder / "nginx.conf"
            service = folder / "decoy.service"
            calls = folder / "calls"
            (self.site / ".current_template").write_text("shopflow")
            conf.write_text("old-nginx")
            service.write_text("old-service")
            body = f'''
PUBLIC_DIR="{self.site}"; NGINX_CONF="{conf}"; SERVICE_FILE="{service}"
validate_reality_runtime() {{ return 0; }}
generate_reality_nginx_conf() {{ printf new-nginx > "$1"; }}
nginx() {{ return 0; }}
install() {{
    if [ "${{*: -1}}" = /run/x-ui-selfsteal ]; then return 0; fi
    command install "$@"
}}
systemctl() {{ printf '%s\\n' "$*" >> "{calls}"; return 0; }}
curl() {{ return 1; }}
if setup_reality_service; then exit 99; fi
'''
            result = self.shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(conf.read_text(), "old-nginx")
            self.assertEqual(service.read_text(), "old-service")
            self.assertIn("stop x-ui-decoy.service", calls.read_text())
            self.assertIn("start x-ui-decoy.service", calls.read_text())
            self.assertNotIn("enable x-ui-decoy.service", calls.read_text())

    def test_expiring_certificate_is_rejected(self):
        expiring = self.base / "expiring.pem"
        self.run_command("openssl", "x509", "-req", "-in", str(self.base / "leaf.csr"),
                         "-CA", str(self.ca), "-CAkey", str(self.base / "ca.key"),
                         "-CAcreateserial", "-out", str(expiring), "-days", "0",
                         "-extfile", str(self.base / "extensions"))
        self.assertNotEqual(self.shell("validate_reality_config",
                                       XUI_SELFSTEAL_CERT_FILE=str(expiring)).returncode, 0)

    def test_certificate_renew_hook_reloads_separate_decoy_service(self):
        hook = self.base / "renew-hook.sh"
        result = subprocess.run(["sh", "-c", '. "$1"; certbot_install_xui_deploy_hook "$2" x-ui',
                                 "test", str(ROOT / "certbot-domain.sh"), str(hook)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.run_command("sh", "-n", str(hook))
        self.assertIn("systemctl reload x-ui-decoy.service", hook.read_text())

    def test_http_routes_require_explicit_valid_selection(self):
        result = self.shell("validate_reality_config", XUI_SELFSTEAL_PROXY_INBOUNDS="1",
                            XUI_DB_PATH=str(self.base / "missing-panel.db"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "missing-panel.db").exists())

    def test_legacy_private_backend_does_not_bind_public_80_or_443(self):
        with tempfile.TemporaryDirectory(prefix="legacy-", dir=self.base) as tmp:
            conf = Path(tmp) / "nginx.conf"
            body = f'''
NGINX_CONF="{conf}"
resolve_ssl_certs() {{ printf '%s|%s|edge.example.com\\n' "{self.cert}" "{self.key}"; }}
generate_nginx_conf
'''
            result = self.shell(body, XUI_SELFSTEAL_MODE="legacy")
            self.assertEqual(result.returncode, 0, result.stderr)
            text = conf.read_text()
            self.assertNotIn("listen 80;", text)
            self.assertNotIn("listen 443 ", text)
            self.assertIn("listen 127.0.0.1:10444", text)

    def test_legacy_port_443_requires_explicit_public_permission(self):
        with tempfile.TemporaryDirectory(prefix="legacy-public-", dir=self.base) as tmp:
            conf = Path(tmp) / "nginx.conf"
            body = f'''
NGINX_CONF="{conf}"
resolve_ssl_certs() {{ printf '%s|%s|edge.example.com\\n' "{self.cert}" "{self.key}"; }}
generate_nginx_conf
'''
            result = self.shell(body, XUI_SELFSTEAL_MODE="legacy", XUI_SELFSTEAL_PORT="443")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(conf.exists())

    def test_reality_mode_skips_legacy_database_and_host_sync(self):
        source = (ROOT / "init-config.sh").read_text()
        start = source.index("sync_haproxy_and_hosts() {")
        end = source.index("\n# Domain Detection", start)
        # Only load the isolated function, not the initialization script, which
        # deliberately has privileged side effects in its normal entrypoint.
        function = source[start:end].rsplit("# ============================================================================", 1)[0]
        body = function + '''
SCRIPT_DIR=/not-used
XUI_SELFSTEAL_MODE=reality
bash() { printf 'backend-only:%s\\n' "$*"; }
sqlite_db() { printf 'UNEXPECTED-DATABASE-WRITE\\n'; return 99; }
sync_haproxy_and_hosts edge.example.com
'''
        result = subprocess.run(["sh", "-c", body], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("backend-only:", result.stdout)
        self.assertNotIn("UNEXPECTED-DATABASE", result.stdout)

    def test_generated_nginx_unix_proxy_protocol_https_and_http_routes(self):
        # Exercise real nginx/curl, on an unprivileged ephemeral port and private
        # temporary Unix socket. Never start/stop an installed nginx service.
        class Backend(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.end_headers()
                self.wfile.write(b"ws-upgrade-ok")
                self.wfile.flush()
                self.close_connection = True

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                payload = json.dumps({"path": self.path, "body": body.decode(),
                                      "client_ip": self.headers.get("X-Real-IP"),
                                      "forwarded": self.headers.get("X-Forwarded-For"),
                                      "proto": self.headers.get("X-Forwarded-Proto")}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        backend = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        worker = threading.Thread(target=backend.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(backend.server_close)
        self.addCleanup(backend.shutdown)
        with tempfile.TemporaryDirectory(prefix="nginx-", dir=self.base) as tmp:
            folder = Path(tmp)
            conf = folder / "nginx.conf"
            unix = folder / "https.sock"
            with socket.socket() as free:
                free.bind(("127.0.0.1", 0))
                port = free.getsockname()[1]
            db = folder / "panel.db"
            with closing(sqlite3.connect(db)) as conn, conn:
                conn.execute("CREATE TABLE inbounds (id INTEGER, enable INTEGER, protocol TEXT, "
                             "listen TEXT, port INTEGER, stream_settings TEXT)")
                for inbound_id, net, path, setting in ((1, "xhttp", "/upload/", "xhttpSettings"),
                                                       (2, "ws", "/socket", "wsSettings"),
                                                       (3, "grpc", "grpc", "grpcSettings")):
                    stream = {"network": net, "security": "none",
                              setting: {"serviceName" if net == "grpc" else "path": path}}
                    conn.execute("INSERT INTO inbounds VALUES (?, 1, 'vless', '127.0.0.1', ?, ?)",
                                 (inbound_id, backend.server_port, json.dumps(stream)))
            db_before = db.read_bytes()
            result = self.shell('validate_reality_config; '
                                f'PUBLIC_DIR="{self.site}"; REALITY_SOCKET="{unix}"; '
                                f'SELFSTEAL_PORT={port}; generate_reality_nginx_conf "{conf}"',
                                XUI_SELFSTEAL_PROXY_INBOUNDS="1,2,3", XUI_DB_PATH=str(db))
            self.assertEqual(result.returncode, 0, result.stderr)
            text = conf.read_text()
            self.assertNotIn("listen 443", text)
            self.assertNotIn("listen 80", text)
            self.assertIn("proxy_protocol", text)
            text = text.replace("user root;", "")
            text = text.replace("/run/x-ui-decoy.pid", str(folder / "nginx.pid"))
            text = text.replace("/var/log/x-ui-decoy.log", str(folder / "error.log"))
            # nginx's distribution default otherwise opens /var/log/nginx/error.log.
            conf.write_text(text)
            tested = subprocess.run(["nginx", "-p", str(folder), "-e", str(folder / "error.log"),
                                     "-t", "-c", str(conf)], capture_output=True, text=True)
            self.assertEqual(tested.returncode, 0, tested.stderr)
            server = subprocess.Popen(["nginx", "-p", str(folder), "-e", str(folder / "error.log"),
                                       "-c", str(conf), "-g", "daemon off;"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                for _ in range(100):
                    if unix.exists() or server.poll() is not None:
                        break
                    time.sleep(0.02)
                for extra, url in ((["--haproxy-protocol", "--unix-socket", str(unix)],
                                    "https://edge.example.com/"),
                                   (["--resolve", f"edge.example.com:{port}:127.0.0.1"],
                                    f"https://edge.example.com:{port}/")):
                    response = subprocess.run(["curl", "--fail", "--silent", "--show-error",
                                               "--max-time", "5", "--noproxy", "*", *extra, url],
                                              env=self.environment(), capture_output=True, text=True)
                    self.assertEqual(response.returncode, 0, response.stderr)
                    self.assertIn("selfsteal-test-ok", response.stdout)
                upload = subprocess.run(["curl", "--fail", "--silent", "--show-error",
                                         "--max-time", "5", "--noproxy", "*", "--haproxy-protocol",
                                         "--unix-socket", str(unix), "--data-raw", "payload",
                                         "-H", "X-Forwarded-For: untrusted",
                                         "https://edge.example.com/upload/file?token=test"],
                                        env=self.environment(), capture_output=True, text=True)
                self.assertEqual(upload.returncode, 0, upload.stderr)
                document = json.loads(upload.stdout)
                self.assertEqual(document["path"], "/upload/file?token=test")
                self.assertEqual(document["body"], "payload")
                self.assertEqual(document["proto"], "https")
                self.assertNotIn("untrusted", document["forwarded"])
                # A real TLS connection with a valid PROXY v1 client address and
                # HTTP Upgrade: verify both the 101 and tunneled backend bytes.
                with socket.socket(socket.AF_UNIX) as transport:
                    transport.settimeout(5)
                    transport.connect(str(unix))
                    transport.sendall(b"PROXY TCP4 198.51.100.7 127.0.0.1 4567 443\r\n")
                    ctx = ssl.create_default_context(cafile=str(self.ca))
                    with ctx.wrap_socket(transport, server_hostname="edge.example.com") as tls:
                        tls.sendall(b"GET /socket HTTP/1.1\r\nHost: edge.example.com\r\n"
                                    b"Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
                        received = b""
                        while b"ws-upgrade-ok" not in received:
                            chunk = tls.recv(4096)
                            if not chunk:
                                break
                            received += chunk
                        self.assertIn(b"101 Switching Protocols", received)
                        self.assertIn(b"ws-upgrade-ok", received)
                self.assertEqual(db.read_bytes(), db_before)
            finally:
                server.terminate()
                server.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
