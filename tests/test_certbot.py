"""Regression tests for ACME routing, serialization and preserved panel settings.

All services/ACME clients are fakes. Only temporary files and synthetic DBs change.
"""

from contextlib import closing
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CertbotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="certbot-tests-")
        self.base = Path(self.temp.name)
        self.calls = self.base / "calls"
        self.env = os.environ.copy()
        self.env.update(XUI_CERTBOT_STATE_DIR=str(self.base / "state"),
                        XUI_CERTBOT_LIVE_DIR=str(self.base / "live"),
                        XUI_CERTBOT_WEBROOT=str(self.base / "webroot"),
                        XUI_CERTBOT_RETRY_DELAY="300")

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self, owner="", certbot_result=0, extra="", invocation=None):
        if invocation is None:
            invocation = "certbot_issue_domain_cert test.example.com ''"
        # Function overrides never call the real Certbot, ss or systemctl.
        source = f'''
. "$1"
ss() {{
    if [ -n "{owner}" ] && [ ! -f "{self.base}/stopped" ]; then
        printf 'LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:(("web",pid=1234,fd=4))\\n'
    fi
}}
systemctl() {{
    printf 'systemctl:%s\\n' "$*" >> "{self.calls}"
    case "$1" in
        is-active) [ "$3" = "{owner}" ] ;;
        show) printf '1234\\n' ;;
        stop) touch "{self.base}/stopped" ;;
        start) rm -f "{self.base}/stopped" ;;
        *) return 99 ;;
    esac
}}
certbot() {{
    printf 'certbot:%s\\n' "$*" >> "{self.calls}"
    if [ {certbot_result} -eq 0 ]; then
        mkdir -p "$XUI_CERTBOT_LIVE_DIR/test.example.com"
        touch "$XUI_CERTBOT_LIVE_DIR/test.example.com/fullchain.pem"
        touch "$XUI_CERTBOT_LIVE_DIR/test.example.com/privkey.pem"
    fi
    return {certbot_result}
}}
openssl() {{ return 1; }}
{extra}
{invocation}
'''
        return subprocess.run(["sh", "-c", source, "test", str(ROOT / "certbot-domain.sh")],
                              env=self.env, capture_output=True, text=True)

    def test_decoy_uses_webroot_and_does_not_stop_services(self):
        result = self.run_helper("x-ui-decoy.service")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        calls = self.calls.read_text()
        self.assertIn("--webroot --webroot-path", calls)
        self.assertNotIn("systemctl:stop", calls)
        self.assertNotIn("systemctl:start", calls)

    def test_free_port_uses_standalone_80_not_global_8088(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--standalone --http-01-port 80", self.calls.read_text())

    def test_haproxy_uses_existing_backend_without_stopping_it(self):
        result = self.run_helper("haproxy.service")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls.read_text()
        self.assertIn("--standalone --http-01-port 8088", calls)
        self.assertNotIn("systemctl:stop", calls)
        self.assertNotIn("systemctl:start", calls)

    def test_only_active_owner_is_restored_after_failure(self):
        result = self.run_helper("nginx.service", certbot_result=1)
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls.read_text()
        self.assertIn("systemctl:stop nginx.service", calls)
        self.assertIn("systemctl:start nginx.service", calls)
        self.assertNotIn("systemctl:start haproxy", calls)
        self.assertEqual(calls.count("certbot:"), 1)
        self.assertFalse((self.base / "stopped").exists())

    def test_active_owner_is_restored_after_success(self):
        result = self.run_helper("nginx.service")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("systemctl:start nginx.service", self.calls.read_text())
        self.assertFalse((self.base / "stopped").exists())

    def test_unknown_listener_is_not_killed(self):
        # A PID is visible, but none of the managed units owns it.
        result = self.run_helper("unknown.service")
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls.read_text()
        self.assertNotIn("certbot:", calls)
        self.assertNotIn("systemctl:stop", calls)
        self.assertNotIn("systemctl:start", calls)

    def test_repeated_failure_has_cooldown(self):
        result = self.run_helper(certbot_result=1, invocation='''
certbot_issue_domain_cert test.example.com '' || true
certbot_issue_domain_cert test.example.com ''
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cooldown", result.stdout)
        self.assertEqual(self.calls.read_text().count("certbot:"), 1)

    def test_explicit_retry_can_bypass_cooldown(self):
        self.env["XUI_CERTBOT_RETRY_DELAY"] = "0"
        result = self.run_helper(certbot_result=1, invocation='''
certbot_issue_domain_cert test.example.com '' || true
certbot_issue_domain_cert test.example.com ''
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text().count("certbot:"), 2)

    @unittest.skipUnless(shutil.which("flock"), "requires flock")
    def test_parallel_fork_request_is_skipped(self):
        result = self.run_helper(extra='''
flock() { return 1; }
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another fork certificate request", result.stdout)
        self.assertFalse(self.calls.exists())


@unittest.skipUnless(shutil.which("sqlite3"), "requires sqlite3 CLI")
class PanelPreservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="panel-tls-tests-")
        self.base = Path(self.temp.name)
        self.db = self.base / "panel.db"
        self.calls = self.base / "calls"
        self.cert = self.base / "saved-cert.pem"
        self.key = self.base / "saved-key.pem"
        self.cert.touch()
        self.key.touch()
        self.settings = {"webDomain": "saved.example.com", "webPort": "50550",
                         "webBasePath": "/keep-me/", "webCertFile": str(self.cert),
                         "webKeyFile": str(self.key), "subDomain": "sub.saved.example.com",
                         "subCertFile": str(self.cert), "subKeyFile": str(self.key),
                         "subPort": "49726", "subPath": "/keep-sub/", "subEnable": "true"}
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            conn.executemany("INSERT INTO settings (key,value) VALUES (?,?)", self.settings.items())

    def tearDown(self):
        self.temp.cleanup()

    def apply_failure(self, extra=""):
        source = (ROOT / "init-config.sh").read_text()
        functions = source[source.index("preserve_tls_setting() {"):source.index("random_uint16() {")]
        settings = source[source.index('ENV_DOMAIN="$XUI_DOMAIN"'):source.index("# Check if subPort conflicts")]
        script = f'''
set -e
DB_PATH="$1"
sqlite_escape() {{ printf '%s' "$1" | sed "s/'/''/g"; }}
sqlite_db() {{ sqlite3 "$DB_PATH" "$@"; }}
{functions}
try_use_domain() {{ printf '%s\\n' "$1" >> "{self.calls}"; return 1; }}
certbot_issue_domain_cert() {{ return 1; }}
is_domain_name() {{ return 0; }}
domain_points_to_this_server() {{ return 1; }}
XUI_DOMAIN=new.example.com
XUI_SUB_DOMAIN=new-sub.example.com
XUI_SUB_ENABLE=true
{extra}
{settings}
'''
        return subprocess.run(["sh", "-c", script, "test", str(self.db)],
                              capture_output=True, text=True)

    def read_settings(self):
        with closing(sqlite3.connect(self.db)) as conn:
            return dict(conn.execute("SELECT key,value FROM settings"))

    def test_failed_acme_preserves_urls_ports_and_tls_settings(self):
        result = self.apply_failure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read_settings(), self.settings)
        self.assertEqual(self.calls.read_text().splitlines().count("new.example.com"), 1)

    def test_missing_stored_cert_is_not_replaced_or_cleared(self):
        self.cert.unlink()
        self.key.unlink()
        result = self.apply_failure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actual = self.read_settings()
        for key in self.settings.keys() - {"subEnable"}:
            self.assertEqual(actual[key], self.settings[key], key)
        self.assertEqual(actual["subEnable"], "false")
        self.assertIn("no automatic HTTP downgrade", result.stdout)

    def test_explicit_port_and_path_overrides_still_work(self):
        result = self.apply_failure('XUI_PORT=51515; XUI_BASE_PATH=/explicit/')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actual = self.read_settings()
        self.assertEqual(actual["webPort"], "51515")
        self.assertEqual(actual["webBasePath"], "/explicit/")
        self.assertEqual(actual["webDomain"], self.settings["webDomain"])

    def test_same_env_and_database_domain_is_tried_once(self):
        result = self.apply_failure("XUI_DOMAIN=saved.example.com")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["saved.example.com"])

    def test_failed_transition_does_not_sync_hosts_or_inbound_certificates(self):
        source = (ROOT / "init-config.sh").read_text()
        start = source.index('effective_domain="${FINAL_DOMAIN:-${XUI_DOMAIN:-${ENV_DOMAIN:-$DB_DOMAIN}}}"')
        stop = source.index("# Session /", start)
        script = '''
PRESERVE_WEB_TLS=1
XUI_SELFSTEAL_MODE=legacy
sync_inbound_tls_certs() { echo unexpected-inbound; }
sync_haproxy_and_hosts() { echo unexpected-hosts; }
''' + source[start:stop]
        result = subprocess.run(["sh", "-c", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unexpected-", result.stdout)


if __name__ == "__main__":
    unittest.main()
