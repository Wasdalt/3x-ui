"""Manual Hosts must survive apply/restart; explicit sync must not guess TLS values."""

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
SOURCE = (ROOT / "init-config.sh").read_text()
HOSTS_SECTION = SOURCE[SOURCE.index("    # 5. Synchronize hosts table"):
                       SOURCE.index("    # 6. Clean legacy externalProxy")]


@unittest.skipUnless(shutil.which("sqlite3") and shutil.which("jq"), "requires sqlite3 and jq")
class HostsSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hosts-sync-tests-")
        self.db = Path(self.temp.name) / "panel.db"
        self.stream = {"network": "tcp", "security": "tls", "tlsSettings": {
            "serverName": "studio.example.com", "alpn": ["h2"],
            "settings": {"fingerprint": "firefox"}}}
        columns = """group_id inbound_id sort_order remark server_description is_disabled
        is_hidden tags address port security sni host_header path alpn fingerprint
        override_sni_from_address keep_sni_blank pinned_peer_cert_sha256
        verify_peer_cert_by_name allow_insecure ech_config_list mux_params sockopt_params
        final_mask vless_route exclude_from_sub_types mihomo_ip_version mihomo_x25519
        shuffle_host node_guids created_at updated_at""".split()
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, port INTEGER, remark TEXT, "
                         "protocol TEXT, stream_settings TEXT, settings TEXT, enable INTEGER)")
            conn.execute("INSERT INTO inbounds VALUES (1, 10443, 'test', 'vless', ?, ?, 1)",
                         (json.dumps(self.stream), json.dumps({"clients": [{"flow": "xtls-rprx-vision"}]})))
            conn.execute("CREATE TABLE hosts (id INTEGER PRIMARY KEY, " +
                         ", ".join(name + " TEXT" for name in columns) + ")")
            conn.execute("INSERT INTO hosts (id,inbound_id,address,port,sni,security,path,host_header,"
                         "fingerprint,alpn,is_disabled) VALUES "
                         "(1,1,'manual.example.com',24443,'manual-sni.example.com','tls','/manual',"
                         "'manual-host.example.com','chrome','[\"h2\"]',0)")

    def tearDown(self):
        self.temp.cleanup()

    def run_section(self, sync=None):
        script = '''
set -e
DB_PATH="$1"
sqlite_db() { sqlite3 "$DB_PATH" "$@"; }
sqlite_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
get_public_ip() { printf '192.0.2.10\\n'; }
target_domain=studio.example.com
haproxy_enabled=0
''' + HOSTS_SECTION
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("XUI_"):
                del env[key]
        if sync is not None:
            env["XUI_HOSTS_SYNC"] = sync
        return subprocess.run(["sh", "-c", script, "test", str(self.db)], env=env,
                              capture_output=True, text=True)

    def row(self):
        with closing(sqlite3.connect(self.db)) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM hosts ORDER BY id LIMIT 1").fetchone()
            return dict(row) if row else None

    def set_stream(self, stream):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE inbounds SET stream_settings=?", (json.dumps(stream),))

    def test_default_and_false_preserve_all_manual_fields(self):
        expected = self.row()
        before = self.db.read_bytes()
        for value in (None, "false", "0"):
            with self.subTest(value=value):
                result = self.run_section(value)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.row(), expected)
                self.assertEqual(self.db.read_bytes(), before)

    def test_default_does_not_create_missing_host(self):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("DELETE FROM hosts")
        result = self.run_section()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.row())

    def test_opt_in_copies_explicit_h2_and_fingerprint_without_rewriting_inbound(self):
        result = self.run_section("true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        row = self.row()
        self.assertEqual(json.loads(row["alpn"]), ["h2"])
        self.assertEqual(row["fingerprint"], "firefox")
        with closing(sqlite3.connect(self.db)) as conn:
            stream = json.loads(conn.execute("SELECT stream_settings FROM inbounds").fetchone()[0])
        self.assertEqual(stream, self.stream)

    def test_opt_in_does_not_guess_alpn_or_fingerprint_for_vision(self):
        self.set_stream({"network": "tcp", "security": "tls", "tlsSettings": {}})
        result = self.run_section("true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.row()["alpn"], "[]")
        self.assertEqual(self.row()["fingerprint"], "")

    def test_opt_in_does_not_guess_h2_for_grpc(self):
        self.set_stream({"network": "grpc", "security": "tls", "tlsSettings": {},
                         "grpcSettings": {"serviceName": "grpc"}})
        result = self.run_section("true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.row()["alpn"], "[]")

    def test_opt_in_creation_also_uses_only_explicit_values(self):
        self.set_stream({"network": "tcp", "security": "tls", "tlsSettings": {}})
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("DELETE FROM hosts")
        result = self.run_section("true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNotNone(self.row())
        self.assertEqual(self.row()["alpn"], "[]")
        self.assertEqual(self.row()["fingerprint"], "")

    def test_no_server_alpn_rewrite_remains_in_wrapper(self):
        self.assertNotIn("'$.tlsSettings.alpn'", SOURCE)
        self.assertNotIn("has_vision", SOURCE)
        self.assertNotIn('fp="firefox"', SOURCE)

    def test_opt_in_syncs_reality_server_names_into_hosts_address_and_sni(self):
        self.set_stream({"network": "tcp", "security": "reality",
                         "realitySettings": {"serverNames": ["studio.f1.netstability.ru"],
                                             "target": "/run/x-ui-selfsteal/https.sock"}})
        result = self.run_section("true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        row = self.row()
        self.assertEqual(row["address"], "studio.f1.netstability.ru")
        self.assertEqual(row["sni"], "studio.f1.netstability.ru")
        self.assertEqual(row["security"], "reality")
        self.assertEqual(int(row["port"]), 10443)

    def test_init_config_cli_hosts_sync(self):
        self.set_stream({"network": "tcp", "security": "reality",
                         "realitySettings": {"serverNames": ["media.f1.netstability.ru"],
                                             "target": "/run/x-ui-selfsteal/https.sock"}})
        env = os.environ.copy()
        env.update(XUI_DB_PATH=str(self.db), XUI_SELFSTEAL_MODE="reality",
                   XUI_SELFSTEAL_ENABLE="false")
        result = subprocess.run(["bash", str(ROOT / "init-config.sh"), "--hosts-sync"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.row()
        self.assertEqual(row["address"], "media.f1.netstability.ru")
        self.assertEqual(row["sni"], "media.f1.netstability.ru")


if __name__ == "__main__":
    unittest.main()
