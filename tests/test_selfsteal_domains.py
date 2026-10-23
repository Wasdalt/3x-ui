"""Domain discovery reads explicit local SelfSteal targets, never panel guesses."""

from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("selfsteal_domains", ROOT / "decoy/selfsteal_domains.py")
domains = importlib.util.module_from_spec(spec)
spec.loader.exec_module(domains)


class SelfStealDomainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="selfsteal-names-")
        self.db = Path(self.temp.name) / "panel.db"
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY,enable INTEGER,stream_settings TEXT)")

    def tearDown(self):
        self.temp.cleanup()

    def add(self, inbound_id, names, target="/run/x-ui-selfsteal/https.sock", enable=1):
        stream = {"security": "reality", "realitySettings": {"serverNames": names, "target": target}}
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("INSERT INTO inbounds VALUES (?,?,?)", (inbound_id, enable, json.dumps(stream)))

    def test_collects_unique_local_names_and_preserves_database(self):
        self.add(4, ["studio.example.com"])
        self.add(6, ["studio.example.com"])
        self.add(13, ["media.example.com"])
        before = self.db.read_bytes()
        self.assertEqual(domains.discover(self.db), ["studio.example.com", "media.example.com"])
        self.assertEqual(self.db.read_bytes(), before)

    def test_external_target_and_disabled_profile_are_not_site_domains(self):
        self.add(4, ["foreign.example.com"], target="foreign.example.com:443")
        self.add(6, ["disabled.example.com"], enable=0)
        self.assertEqual(domains.discover(self.db, primary="own.example.com"), ["own.example.com"])

    def test_explicit_primary_wins_but_new_local_alias_is_discovered(self):
        self.add(4, ["studio.example.com", "media.example.com"])
        self.assertEqual(domains.discover(self.db, primary="studio.example.com"),
                         ["studio.example.com", "media.example.com"])

    def test_no_name_is_invented_and_missing_db_is_not_created(self):
        missing = self.db.parent / "missing.db"
        with self.assertRaises(ValueError):
            domains.discover(missing)
        self.assertFalse(missing.exists())
        with self.assertRaises(ValueError):
            domains.discover(self.db)

    def test_invalid_name_stops_discovery_without_writing(self):
        self.add(4, ["bad.example.com; include"])
        before = self.db.read_bytes()
        with self.assertRaises(ValueError):
            domains.discover(self.db)
        self.assertEqual(self.db.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
