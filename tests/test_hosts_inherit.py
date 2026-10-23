"""Live inheritance uses explicit values, not defaults or a full fork restart."""

from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hosts_tls_inherit", ROOT / "hosts-tls-inherit.py")
inherit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inherit)


class HostsInheritanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hosts-inherit-")
        self.db = Path(self.temp.name) / "panel.db"
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, enable INTEGER, "
                         "stream_settings TEXT, port INTEGER, listen TEXT, tag TEXT)")
            conn.execute("CREATE TABLE hosts (id INTEGER PRIMARY KEY, inbound_id INTEGER, "
                         "is_disabled INTEGER, security TEXT, fingerprint TEXT, alpn TEXT, "
                         "address TEXT, port INTEGER, sni TEXT, path TEXT, updated_at INTEGER)")
            stream = {"network": "tcp", "security": "reality", "realitySettings": {
                "settings": {"fingerprint": "firefox"}, "alpn": ["h2"],
                "serverNames": ["studio.example.com"], "privateKey": "test-key"}}
            conn.execute("INSERT INTO inbounds VALUES (1,1,?,443,'','keep-tag')", (json.dumps(stream),))
            for host_id in (45, 55):
                conn.execute("INSERT INTO hosts VALUES (?,1,0,'reality','chrome','[\"http/1.1\"]',"
                             "'keep.example.com',443,'keep-sni.example.com','/keep',123)", (host_id,))

    def tearDown(self):
        self.temp.cleanup()

    def update_stream(self, stream):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE inbounds SET stream_settings=? WHERE id=1", (json.dumps(stream),))

    def rows(self):
        with closing(sqlite3.connect(self.db)) as conn:
            conn.row_factory = sqlite3.Row
            return [dict(row) for row in conn.execute("SELECT * FROM hosts ORDER BY id")]

    def test_only_two_fields_and_change_timestamp_are_updated(self):
        before = self.rows()
        with closing(sqlite3.connect(self.db)) as conn:
            inbound = conn.execute("SELECT * FROM inbounds").fetchall()
        changes, skipped = inherit.synchronize(self.db)
        self.assertEqual(len(changes), 2)
        self.assertEqual(skipped, [])
        for old, row in zip(before, self.rows()):
            self.assertEqual(row["fingerprint"], "firefox")
            self.assertEqual(json.loads(row["alpn"]), ["h2"])
            for key in old.keys() - {"fingerprint", "alpn", "updated_at"}:
                self.assertEqual(old[key], row[key], key)
        with closing(sqlite3.connect(self.db)) as conn:
            self.assertEqual(conn.execute("SELECT * FROM inbounds").fetchall(), inbound)

    def test_dry_run_and_repeated_sync_are_write_free(self):
        original = self.db.read_bytes()
        changes, _ = inherit.synchronize(self.db, dry_run=True)
        self.assertEqual(len(changes), 2)
        self.assertEqual(self.db.read_bytes(), original)
        inherit.synchronize(self.db)
        after = self.db.read_bytes()
        changes, _ = inherit.synchronize(self.db)
        self.assertEqual(changes, [])
        self.assertEqual(self.db.read_bytes(), after)

    def test_missing_fields_preserve_manual_values(self):
        self.update_stream({"security": "reality", "realitySettings": {"settings": {}}})
        before = self.rows()
        self.assertEqual(inherit.synchronize(self.db)[0], [])
        self.assertEqual(self.rows(), before)

    def test_explicit_empty_values_clear_only_inherited_fields(self):
        self.update_stream({"security": "reality", "realitySettings": {
            "settings": {"fingerprint": ""}, "alpn": []}})
        inherit.synchronize(self.db)
        for row in self.rows():
            self.assertEqual(row["fingerprint"], "")
            self.assertEqual(row["alpn"], "[]")
            self.assertEqual(row["sni"], "keep-sni.example.com")

    def test_selection_and_manual_exclusions_use_host_ids(self):
        changes, _ = inherit.synchronize(self.db, selected={45, 55}, excluded={55})
        self.assertEqual([item[0] for item in changes], [45])
        self.assertEqual(self.rows()[1]["fingerprint"], "chrome")

    def test_plain_http_backend_does_not_clear_tls_frontend_host(self):
        self.update_stream({"network": "xhttp", "security": "none", "xhttpSettings": {"path": "/upload"}})
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE hosts SET security='tls'")
        before = self.rows()
        self.assertEqual(inherit.synchronize(self.db)[0], [])
        self.assertEqual(self.rows(), before)

    def test_disabled_and_security_override_hosts_are_skipped(self):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("UPDATE hosts SET is_disabled=1 WHERE id=45")
            conn.execute("UPDATE hosts SET security='tls' WHERE id=55")
        before = self.db.read_bytes()
        self.assertEqual(inherit.synchronize(self.db)[0], [])
        self.assertEqual(self.db.read_bytes(), before)

    def test_invalid_values_do_not_damage_existing_profiles(self):
        self.update_stream({"security": "reality", "realitySettings": {
            "settings": {"fingerprint": "firefox"}, "alpn": "h2"}})
        before = self.rows()
        changes, skipped = inherit.synchronize(self.db)
        self.assertEqual(changes, [])
        self.assertEqual(len(skipped), 2)
        self.assertEqual(self.rows(), before)

    def test_missing_database_is_not_created(self):
        missing = self.db.parent / "missing.db"
        with self.assertRaises(inherit.InheritanceError):
            inherit.synchronize(missing)
        self.assertFalse(missing.exists())

    def test_worker_requires_explicit_permission_before_opening_database(self):
        missing = self.db.parent / "must-not-be-created.db"
        env = {key: value for key, value in os.environ.items() if not key.startswith("XUI_")}
        result = subprocess.run([sys.executable, str(ROOT / "hosts-tls-inherit.py"),
                                 "--db", str(missing)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[SKIP]", result.stdout)
        self.assertFalse(missing.exists())

    def test_replaced_database_is_read_on_next_pass(self):
        inherit.synchronize(self.db)
        replacement = self.db.parent / "restored.db"
        with closing(sqlite3.connect(self.db)) as src, closing(sqlite3.connect(replacement)) as dst:
            src.backup(dst)
            with dst:
                dst.execute("UPDATE inbounds SET stream_settings=?", (json.dumps({"security": "reality",
                            "realitySettings": {"settings": {"fingerprint": "safari"}}}),))
        os.replace(replacement, self.db)
        inherit.synchronize(self.db)
        self.assertEqual(self.rows()[0]["fingerprint"], "safari")
        self.assertEqual(json.loads(self.rows()[0]["alpn"]), ["h2"])

    def test_settings_priority_and_missing_alpn_do_not_guess_h2(self):
        values = inherit.explicit_values(json.dumps({"security": "tls", "tlsSettings": {
            "fingerprint": "chrome", "settings": {"fingerprint": "firefox"}}}), "tls")
        self.assertEqual(values, {"fingerprint": "firefox"})

    def test_live_process_observes_a_saved_inbound_without_service_commands(self):
        env = {key: value for key, value in os.environ.items() if not key.startswith("XUI_")}
        env.update(XUI_HOSTS_INHERIT_TLS="true", PYTHONDONTWRITEBYTECODE="1")
        process = subprocess.Popen([sys.executable, str(ROOT / "hosts-tls-inherit.py"),
                                    "--db", str(self.db), "--watch", "--interval", "0.25"],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and self.rows()[0]["fingerprint"] != "firefox":
                time.sleep(0.05)
            self.assertEqual(self.rows()[0]["fingerprint"], "firefox")
            self.update_stream({"security": "reality", "realitySettings": {
                "settings": {"fingerprint": "safari"}, "alpn": ["h2", "http/1.1"]}})
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and self.rows()[0]["fingerprint"] != "safari":
                time.sleep(0.05)
            self.assertEqual(self.rows()[0]["fingerprint"], "safari")
            self.assertEqual(json.loads(self.rows()[0]["alpn"]), ["h2", "http/1.1"])
        finally:
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
        self.assertNotIn("test-key", stdout + stderr)
        self.assertNotIn("systemctl", stdout + stderr)
        self.assertEqual(process.returncode, 0, stderr)


if __name__ == "__main__":
    unittest.main()
