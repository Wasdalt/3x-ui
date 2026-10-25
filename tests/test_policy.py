"""Opt-in policy and no-surprise regression tests; no host services are touched."""

from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INIT = (ROOT / "init-config.sh").read_text()


def clean_environment(**values):
    env = {key: value for key, value in os.environ.items() if not key.startswith("XUI_")}
    env.update(values)
    return env


class PolicyTests(unittest.TestCase):
    def shell(self, body, **values):
        return subprocess.run(["sh", "-c", '. "$1"; ' + body, "test", str(ROOT / "fork-policy.sh")],
                              env=clean_environment(**values), capture_output=True, text=True)

    def test_important_actions_are_opt_in(self):
        for flag in ("XUI_PANEL_CONTROLLER_ENABLE", "XUI_REWRITE_INBOUNDS", "XUI_SYNC_INBOUND_CERTS", "XUI_TUNE_NETWORK",
                     "XUI_CLEANUP_ORPHANS", "XUI_DB_MAINTENANCE", "XUI_AUTO_DB_APPLY",
                     "XUI_AUTO_CERTS", "XUI_AUTO_CERT_DOMAINS", "XUI_MANAGE_SYSTEM_NGINX",
                     "XUI_CERTBOT_STOP_WEB_SERVER",
                     "XUI_REPAIR_XRAY_TEMPLATE", "XUI_SELFSTEAL_ALLOW_FALLBACK_CERT"):
            with self.subTest(flag=flag):
                result = self.shell(f'fork_allow {flag} "test action"')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("[SKIP]", result.stdout)
                self.assertIn(flag, result.stdout)
                enabled = self.shell(f'fork_allow {flag} "test action"', **{flag: "true"})
                self.assertEqual(enabled.returncode, 0, enabled.stderr)
                self.assertIn("[ALLOW]", enabled.stdout)

    def test_flag_values_are_not_executed(self):
        result = self.shell("fork_policy_enabled XUI_AUTO_CERTS",
                            XUI_AUTO_CERTS="true; printf secret-injection")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("secret-injection", result.stdout)
        self.assertNotEqual(self.shell("fork_policy_enabled 'XUI_X;echo injected'").returncode, 0)

    def test_summary_and_setting_logs_do_not_print_values(self):
        result = self.shell('fork_setting_log CHANGE tgBotToken "explicit env"; '
                            'fork_setting_log KEEP webBasePath "unchanged"; '
                            'fork_setting_log SKIP webPort "not configured"; fork_summary')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("изменено=1", result.stdout)
        self.assertIn("сохранено=1", result.stdout)
        self.assertIn("пропущено=1", result.stdout)
        self.assertIn("значение скрыто", result.stdout)

    def test_background_worker_exits_before_database_or_service_actions_by_default(self):
        with tempfile.TemporaryDirectory(prefix="policy-worker-") as tmp:
            env_file = Path(tmp) / "empty.env"
            env_file.touch()
            result = subprocess.run(["bash", str(ROOT / "fork-db-apply.sh")],
                                    env=clean_environment(XUI_CONFIG_DIR=tmp, XUI_ENV_FILE=str(env_file)),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[SKIP]", result.stdout)
            self.assertIn("XUI_AUTO_DB_APPLY", result.stdout)
            self.assertEqual(list(Path(tmp).iterdir()), [env_file])

    def test_runtime_policy_is_deployed_to_all_entrypoints(self):
        for file in ("fork-sync.sh", "native-install.sh", "native-apply.sh", "Dockerfile"):
            with self.subTest(file=file):
                self.assertIn("fork-policy.sh", (ROOT / file).read_text())

    def test_policy_cli_is_read_only_and_uses_effective_environment(self):
        with tempfile.TemporaryDirectory(prefix="policy-cli-") as tmp:
            env_file = Path(tmp) / "active.env"
            env_file.write_text("XUI_AUTO_DB_APPLY=false\nXUI_REWRITE_INBOUNDS=true\n")
            marker = Path(tmp) / "must-not-be-created"
            result = subprocess.run(["bash", str(ROOT / "x-ui-fork.sh"), "policy"],
                                    env=clean_environment(XUI_FORK_PROJECT_DIR=str(ROOT),
                                                          XUI_FORK_PROJECT_DIR_FILE=str(marker),
                                                          XUI_ENV_FILE=str(env_file)),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("XUI_REWRITE_INBOUNDS=true", result.stdout)
            self.assertFalse(marker.exists())
            self.assertEqual(list(Path(tmp).iterdir()), [env_file])

    def test_no_implicit_reality_version_override_or_nginx_site_deletion(self):
        self.assertNotIn("'$.realitySettings.minClientVer'", INIT)
        for file in ("native-install.sh", "native-apply.sh"):
            self.assertNotIn("rm -f /etc/nginx/sites-enabled/default", (ROOT / file).read_text())


@unittest.skipUnless(shutil.which("sqlite3") and shutil.which("jq"), "requires sqlite3 and jq")
class InboundSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="inbound-policy-")
        self.db = Path(self.temp.name) / "panel.db"
        self.stream = {"network": "tcp", "security": "reality", "externalProxy": [{"port": 8443}],
                       "realitySettings": {"target": "studio.example.com:443", "minClientVer": "",
                                           "serverNames": ["studio.example.com"], "privateKey": "test-secret"}}
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, port INTEGER, enable INTEGER, "
                         "listen TEXT, protocol TEXT, stream_settings TEXT, settings TEXT, remark TEXT)")
            conn.execute("INSERT INTO inbounds VALUES (1,443,1,'127.0.0.1','vless',?,'{}','test')",
                         (json.dumps(self.stream),))
            conn.execute("CREATE TABLE hosts (id INTEGER PRIMARY KEY, inbound_id INTEGER, is_disabled INTEGER)")
            conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            conn.execute("INSERT INTO settings (key,value) VALUES ('xrayTemplateConfig', ?)",
                         (json.dumps({"metrics": {"listen": "127.0.0.1:11111"}}),))

    def tearDown(self):
        self.temp.cleanup()

    def run_sync(self, **values):
        start = INIT.index("sync_haproxy_and_hosts() {")
        stop = INIT.index("\n# Domain Detection", start)
        function = INIT[start:stop].rsplit("# ============================================================================", 1)[0]
        body = f'''
set -e
. "{ROOT / 'fork-policy.sh'}"
DB_PATH="$1"
SCRIPT_DIR=/not-used
sqlite_db() {{ sqlite3 "$DB_PATH" "$@"; }}
sqlite_escape() {{ printf '%s' "$1" | sed "s/'/''/g"; }}
systemctl() {{ echo UNEXPECTED-SERVICE >&2; return 99; }}
{function}
sync_haproxy_and_hosts studio.example.com
'''
        return subprocess.run(["sh", "-c", body, "test", str(self.db)],
                              env=clean_environment(**values), capture_output=True, text=True)

    def test_default_leaves_database_and_services_unchanged(self):
        before = self.db.read_bytes()
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertIn("XUI_REWRITE_INBOUNDS", result.stdout)
        self.assertNotIn("UNEXPECTED-SERVICE", result.stderr)

    def test_haproxy_conflict_does_not_renumber_existing_inbound(self):
        before = self.db.read_bytes()
        result = self.run_sync(XUI_HAPROXY_ENABLE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[ERROR]", result.stderr)
        self.assertIn("XUI_REWRITE_INBOUNDS", result.stderr)
        self.assertEqual(self.db.read_bytes(), before)

    def test_inbound_certificate_sync_is_disabled_without_permission(self):
        start = INIT.index("sync_inbound_tls_certs() {")
        stop = INIT.index("sync_haproxy_and_hosts() {", start)
        function = INIT[start:stop]
        body = f'. "{ROOT / "fork-policy.sh"}";\n' + function + '''
sqlite_db() { echo UNEXPECTED-DB; return 99; }
sync_inbound_tls_certs example.com /not-used /not-used
'''
        result = subprocess.run(["sh", "-c", body], env=clean_environment(),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[SKIP]", result.stdout)
        self.assertNotIn("UNEXPECTED-DB", result.stdout)

    def test_setting_application_is_idempotent_and_redacts_secret(self):
        functions = INIT[INIT.index("preserve_tls_setting() {"):INIT.index("random_uint16() {")]
        body = f'''
set -e
. "{ROOT / 'fork-policy.sh'}"
DB_PATH="$1"
sqlite_db() {{ sqlite3 "$DB_PATH" "$@"; }}
sqlite_escape() {{ printf '%s' "$1" | sed "s/'/''/g"; }}
{functions}
set_always tgBotToken "secret-value-that-must-not-be-logged"
set_always tgBotToken "secret-value-that-must-not-be-logged"
set_always webPort ""
fork_summary
'''
        result = subprocess.run(["sh", "-c", body, "test", str(self.db)],
                                env=clean_environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("secret-value-that-must-not-be-logged", result.stdout + result.stderr)
        self.assertIn("изменено=1", result.stdout)
        self.assertIn("сохранено=1", result.stdout)
        with closing(sqlite3.connect(self.db)) as conn:
            self.assertEqual(conn.execute("SELECT value FROM settings WHERE key='tgBotToken'").fetchone()[0],
                             "secret-value-that-must-not-be-logged")

    def test_corrupt_xray_template_is_not_replaced_from_disk_by_default(self):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE settings SET value='not-json' WHERE key='xrayTemplateConfig'")
        config = Path(self.temp.name) / "config.json"
        config.write_text('{"routing":{"rules":[]}}')
        before = self.db.read_bytes()
        start = INIT.index("        _configure_xray_logging() {")
        stop = INIT.index("        _configure_xray_logging ||", start)
        function = INIT[start:stop]
        body = f'''
. "{ROOT / 'fork-policy.sh'}"
DB_PATH="$1"
XRAY_CONFIG="$2"
sqlite_db() {{ sqlite3 "$DB_PATH" "$@"; }}
{function}
_configure_xray_logging
'''
        result = subprocess.run(["sh", "-c", body, "test", str(self.db), str(config)],
                                env=clean_environment(), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XUI_REPAIR_XRAY_TEMPLATE", result.stdout)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(config.read_text(), '{"routing":{"rules":[]}}')


if __name__ == "__main__":
    unittest.main()
