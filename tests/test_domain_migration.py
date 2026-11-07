import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INIT_SCRIPT = ROOT / "init-config.sh"


class DomainMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tmpdir.name)
        self.db = self.base / "x-ui.db"
        self.env_file = self.base / ".env"

        # Create test DB schema and sample data
        with sqlite3.connect(self.db) as conn:
            conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT);")
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, enable NUMERIC, listen TEXT, port INTEGER, protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT);")
            conn.execute("CREATE TABLE hosts (id INTEGER PRIMARY KEY, inbound_id INTEGER, address TEXT, sni TEXT, host_header TEXT, path TEXT, server_description TEXT);")

            # Insert sample settings
            conn.execute("INSERT INTO settings (key, value) VALUES ('webDomain', 'workspace.r1.netstability.ru');")
            conn.execute("INSERT INTO settings (key, value) VALUES ('webCertFile', '/etc/letsencrypt/live/workspace.r1.netstability.ru/fullchain.pem');")
            conn.execute("INSERT INTO settings (key, value) VALUES ('webKeyFile', '/etc/letsencrypt/live/workspace.r1.netstability.ru/privkey.pem');")
            conn.execute("INSERT INTO settings (key, value) VALUES ('subDomain', 'workspace.r1.netstability.ru');")

            # Insert TLS inbound
            stream_tls = '{"network":"tcp","security":"tls","tlsSettings":{"serverName":"studio.r1.netstability.ru","certificates":[{"certificateFile":"/etc/letsencrypt/live/studio.r1.netstability.ru/fullchain.pem","keyFile":"/etc/letsencrypt/live/studio.r1.netstability.ru/privkey.pem"}]}}'
            conn.execute("INSERT INTO inbounds (id, enable, port, protocol, settings, stream_settings, tag) VALUES (1, 1, 443, 'trojan', '{}', ?, 'in-443');", (stream_tls,))

            # Insert Reality inbound
            stream_reality = '{"network":"xhttp","security":"reality","realitySettings":{"dest":"/run/x-ui-selfsteal/https.sock","serverNames":["studio.r1.netstability.ru","media.r1.netstability.ru"]}}'
            conn.execute("INSERT INTO inbounds (id, enable, port, protocol, settings, stream_settings, tag) VALUES (2, 1, 20443, 'vless', '{}', ?, 'in-20443');", (stream_reality,))

            # Insert host entries
            conn.execute("INSERT INTO hosts (id, inbound_id, address, sni, host_header) VALUES (1, 1, 'studio.r1.netstability.ru', 'studio.r1.netstability.ru', 'studio.r1.netstability.ru');")
            conn.execute("INSERT INTO hosts (id, inbound_id, address, sni, host_header) VALUES (2, 2, 'studio.r1.netstability.ru', 'media.r1.netstability.ru', '');")

        # Create sample .env
        self.env_file.write_text(
            "XUI_DOMAIN=workspace.r1.netstability.ru\n"
            "XUI_SELFSTEAL_DOMAIN=studio.r1.netstability.ru\n"
            "XUI_SELFSTEAL_EXTRA_DOMAINS=media.r1.netstability.ru\n"
        )

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_auto_migrate_domains_updates_db_and_env(self):
        script = f'''
set -e
DB_PATH="{self.db}"
SCRIPT_DIR="{self.base}"
. "{ROOT / "fork-policy.sh"}"

sqlite_escape() {{ printf '%s' "$1" | sed "s/'/''/g"; }}
sqlite_db() {{ sqlite3 "$DB_PATH" "$@"; }}

# Source migration functions from init-config.sh
eval "$(sed -n '/migrate_db_domains() {{/,/sync_inbound_tls_certs() {{/p' "{INIT_SCRIPT}" | sed '$d')"

auto_migrate_domains "workspace.r1.netstability.ru" "workspace.r2.netstability.ru"
'''
        proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("[DOMAIN-MIGRATE]", proc.stdout)

        with sqlite3.connect(self.db) as conn:
            # Check settings
            settings = dict(conn.execute("SELECT key, value FROM settings;").fetchall())
            self.assertEqual(settings["webDomain"], "workspace.r2.netstability.ru")
            self.assertEqual(settings["webCertFile"], "/etc/letsencrypt/live/workspace.r2.netstability.ru/fullchain.pem")
            self.assertEqual(settings["subDomain"], "workspace.r2.netstability.ru")

            # Check inbounds stream_settings
            inbounds = dict(conn.execute("SELECT id, stream_settings FROM inbounds;").fetchall())
            self.assertIn("studio.r2.netstability.ru", inbounds[1])
            self.assertNotIn("studio.r1.netstability.ru", inbounds[1])
            self.assertIn("studio.r2.netstability.ru", inbounds[2])
            self.assertIn("media.r2.netstability.ru", inbounds[2])
            self.assertNotIn("r1.netstability.ru", inbounds[2])

            # Check hosts
            hosts = conn.execute("SELECT id, address, sni, host_header FROM hosts;").fetchall()
            self.assertEqual(hosts[0], (1, "studio.r2.netstability.ru", "studio.r2.netstability.ru", "studio.r2.netstability.ru"))
            self.assertEqual(hosts[1], (2, "studio.r2.netstability.ru", "media.r2.netstability.ru", ""))

        # Check .env file update
        env_content = self.env_file.read_text()
        self.assertIn("studio.r2.netstability.ru", env_content)
        self.assertIn("media.r2.netstability.ru", env_content)
        self.assertNotIn("r1.netstability.ru", env_content)

    def test_sync_inbound_tls_certs_matches_san_lineage(self):
        # Create a mock cert with SAN
        live_dir = self.base / "live" / "studio.r2.netstability.ru"
        live_dir.mkdir(parents=True)
        cert_file = live_dir / "fullchain.pem"
        key_file = live_dir / "privkey.pem"
        cert_file.write_text("cert-content")
        key_file.write_text("key-content")

        script = f'''
set -e
DB_PATH="{self.db}"
LETSENCRYPT_LIVE_DIR="{self.base / "live"}"
. "{ROOT / "fork-policy.sh"}"

sqlite_escape() {{ printf '%s' "$1" | sed "s/'/''/g"; }}
sqlite_db() {{ sqlite3 "$DB_PATH" "$@"; }}

# Mock openssl checkhost: return 0 for studio.r1.netstability.ru
openssl() {{
    case "$*" in
        *checkhost*studio.r1.netstability.ru*) return 0 ;;
        *) return 1 ;;
    esac
}}

# Source sync_inbound_tls_certs
eval "$(sed -n '/sync_inbound_tls_certs() {{/,/sync_haproxy_and_hosts() {{/p' "{INIT_SCRIPT}" | sed '$d')"

# Target cert missing, inbound has serverName=studio.r1.netstability.ru
XUI_SYNC_INBOUND_CERTS=true
sync_inbound_tls_certs "" "" ""
'''
        proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                              env={**os.environ, "PATH": f"{self.base}:{os.environ.get('PATH', '')}"})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Linked inbound id=1 to certificate:", proc.stdout)


if __name__ == "__main__":
    unittest.main()
