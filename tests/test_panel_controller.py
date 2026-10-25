"""Isolated controller tests: temporary SQLite only, no commands/services/network."""

from contextlib import closing, contextmanager, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("panel_controller", ROOT / "panel-controller.py")
pc = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pc
SPEC.loader.exec_module(pc)


@contextmanager
def connection(path):
    with closing(sqlite3.connect(path)) as conn, conn:
        yield conn


class PanelControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.db = self.directory / "panel.db"
        self.state_dir = self.directory / "state"
        self.calls, self.checks = [], []
        self.env = {"XUI_PANEL_CONTROLLER_ENABLE": "true", "XUI_AUTO_DB_APPLY": "false"}
        self.stream = {
            "security": "reality", "network": "tcp",
            "sockopt": {"acceptProxyProtocol": True},
            "realitySettings": {
                "target": "/run/x-ui-selfsteal/https.sock", "xver": 1,
                "serverNames": ["edge.example.com"], "privateKey": "TOP-SECRET-KEY",
                "settings": {"fingerprint": "firefox"}}}
        with connection(self.db) as conn:
            conn.executescript("""
                CREATE TABLE inbounds (
                    id INTEGER PRIMARY KEY, enable INTEGER, protocol TEXT,
                    listen TEXT, port INTEGER, stream_settings TEXT, settings TEXT,
                    remark TEXT DEFAULT '', updated_at INTEGER DEFAULT 1);
                CREATE TABLE hosts (
                    id INTEGER PRIMARY KEY, inbound_id INTEGER NOT NULL,
                    group_id TEXT NOT NULL, address TEXT NOT NULL,
                    port INTEGER NOT NULL, security TEXT NOT NULL, sni TEXT NOT NULL,
                    path TEXT NOT NULL DEFAULT '', host_header TEXT NOT NULL DEFAULT '',
                    fingerprint TEXT NOT NULL DEFAULT '', alpn TEXT NOT NULL DEFAULT '[]',
                    tags TEXT NOT NULL DEFAULT '', is_disabled INTEGER NOT NULL DEFAULT 0,
                    remark TEXT NOT NULL DEFAULT 'schema-default',
                    server_description TEXT NOT NULL,
                    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                    custom_default TEXT NOT NULL DEFAULT 'preserve schema default');
            """)
            conn.execute("INSERT INTO inbounds (id,enable,protocol,listen,port,stream_settings,settings) "
                         "VALUES (1,1,'vless','127.0.0.1',11443,?,?)",
                         (json.dumps(self.stream), json.dumps({"clients": [{
                             "id": "SECRET-CLIENT-UUID", "flow": "xtls-rprx-vision"}]})))
        self.controller = self.make_controller()

    def runner(self, argv, env):
        self.calls.append((argv, env))

    def health(self, routes):
        self.checks.append(routes)

    def test_certificate_primary_is_not_selected_by_alphabetical_san_order(self):
        self.stream["realitySettings"]["serverNames"] = ["studio.example.com", "media.example.com"]
        self.save_stream()
        self.controller.run_once()
        for _, env in self.calls:
            self.assertEqual(env["XUI_SELFSTEAL_DOMAIN"], "studio.example.com")
            self.assertEqual(env["XUI_SELFSTEAL_EXTRA_DOMAINS"], "media.example.com")

    def test_explicit_existing_certificate_primary_is_preserved(self):
        self.stream["realitySettings"]["serverNames"] = ["media.example.com", "studio.example.com"]
        self.save_stream()
        self.env["XUI_SELFSTEAL_DOMAIN"] = "studio.example.com"
        self.make_controller().run_once()
        for _, env in self.calls:
            self.assertEqual(env["XUI_SELFSTEAL_DOMAIN"], "studio.example.com")

    @unittest.skipUnless(all(shutil.which(tool) for tool in
                            ("bash", "python3", "nginx", "haproxy", "openssl", "curl", "ss")),
                         "wrapper dependencies unavailable")
    def test_shell_plan_does_not_write_database_or_state(self):
        config = self.directory / "controller.env"
        config.write_text("XUI_PANEL_CONTROLLER_ENABLE=false\nXUI_AUTO_DB_APPLY=false\n"
                          "XUI_HOSTS_SYNC=false\nXUI_REWRITE_INBOUNDS=false\n")
        env = dict(os.environ, XUI_ENV_FILE=str(config), XUI_DB_PATH=str(self.db),
                   XUI_PANEL_CONTROLLER_STATE_DIR=str(self.state_dir),
                   PYTHONDONTWRITEBYTECODE="1")
        before = self.db.read_bytes()
        result = subprocess.run(["bash", str(ROOT / "panel-controller.sh"), "plan"],
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.removeprefix("[CONTROLLER] "))["status"], "planned")
        self.assertEqual(self.db.read_bytes(), before)
        self.assertFalse(self.state_dir.exists())

    def test_real_router_loader_accepts_only_owned_pending_during_staging(self):
        from decoy.sni_routes import RouterError, load_routes

        def runner(argv, env):
            if Path(argv[0]).name == "sni-router.sh":
                with self.assertRaises(RouterError):
                    load_routes(self.db, [1])
                routes = load_routes(self.db, [1], include_managed_pending=True)
                self.assertEqual([route.domain for route in routes], ["edge.example.com"])
                self.assertEqual(self.rows()[0]["is_disabled"], 1)
            self.runner(argv, env)

        self.make_controller(runner=runner).run_once()
        self.assertEqual(self.rows()[0]["is_disabled"], 0)
        self.assertEqual([route.domain for route in load_routes(self.db, [1])], ["edge.example.com"])

    def make_controller(self, **kwargs):
        options = dict(env=self.env, runner=self.runner, health=self.health,
                       native_check=lambda: True)
        options.update(kwargs)
        return pc.Controller(self.db, self.state_dir, ROOT, **options)

    def execute(self, sql, values=()):
        with connection(self.db) as conn:
            conn.execute(sql, values)

    def rows(self, table="hosts"):
        with connection(self.db) as conn:
            conn.row_factory = sqlite3.Row
            return [dict(row) for row in conn.execute("SELECT * FROM " + table + " ORDER BY id")]

    def save_stream(self):
        self.execute("UPDATE inbounds SET stream_settings=? WHERE id=1", (json.dumps(self.stream),))

    def add_host(self, **values):
        row = dict(inbound_id=1, group_id="manual-group", address="manual.example.com", port=443,
                   security="reality", sni="edge.example.com", path="/manual", host_header="manual",
                   fingerprint="manual-fp", alpn='["h2"]', tags="custom", is_disabled=0,
                   server_description="manual description", created_at=1, updated_at=1)
        row.update(values)
        self.execute("INSERT INTO hosts (" + ",".join(row) + ") VALUES (" +
                     ",".join("?" for _ in row) + ")", list(row.values()))
        return self.rows()[-1]["id"]

    def assert_no_effects(self, hosts, inbounds):
        self.assertEqual(self.rows(), hosts)
        self.assertEqual(self.rows("inbounds"), inbounds)
        self.assertFalse(self.calls)
        self.assertFalse(self.checks)

    def test_opt_in_is_exact_and_required(self):
        for value in (None, "false", "TRUE", "1", "yes"):
            with self.subTest(value=value):
                env = {} if value is None else {"XUI_PANEL_CONTROLLER_ENABLE": value}
                ctrl = self.make_controller(env=env)
                with patch.object(ctrl, "plan", side_effect=AssertionError("must not read")):
                    self.assertEqual(ctrl.run_once(), {"status": "disabled"})
        self.assertFalse(self.state_dir.exists())

    def test_plan_and_dry_run_are_strictly_read_only(self):
        before = self.db.read_bytes()
        hosts, inbounds = self.rows(), self.rows("inbounds")
        with patch.object(pc.sqlite3, "connect", wraps=sqlite3.connect) as connect:
            plan = self.controller.plan()
            result = self.controller.run_once(dry_run=True)
            self.assertTrue(all("mode=ro" in call.args[0] for call in connect.call_args_list))
        self.assertEqual(len(plan.actions), 1)
        self.assertEqual(result["status"], "planned")
        self.assertEqual(self.db.read_bytes(), before)
        self.assert_no_effects(hosts, inbounds)
        self.assertFalse(self.state_dir.exists())

    def test_missing_database_never_created(self):
        self.db.unlink()
        with self.assertRaises((pc.ControllerError, OSError)):
            self.controller.run_once()
        self.assertFalse(self.db.exists())
        self.assertFalse(self.calls)

    def test_native_check_prevents_apply(self):
        with self.assertRaises(pc.ControllerError):
            self.make_controller(native_check=lambda: False).run_once()
        self.assertFalse(self.state_dir.exists())
        self.assertFalse(self.rows())
        self.assertFalse(self.calls)

    def test_manual_host_is_used_read_only_without_duplicate(self):
        self.add_host(tags='["custom","not-fork-managed"]')
        hosts, inbounds = self.rows(), self.rows("inbounds")
        result = self.controller.run_once()
        self.assertEqual(result["changes"], 0)
        self.assertEqual(self.rows(), hosts)
        self.assertEqual(self.rows("inbounds"), inbounds)
        self.assertEqual(len(self.calls), 3)

    def test_inactive_or_incompatible_manual_host_does_not_get_rewritten(self):
        self.add_host(is_disabled=1)
        self.add_host(sni="other.example.com")
        self.add_host(port=8443)
        self.add_host(security="tls")
        originals = self.rows()
        self.controller.run_once()
        self.assertEqual(self.rows()[:4], originals)
        self.assertEqual(len(self.rows()), 5)
        self.assertIn(pc.MANAGED, pc.tags(self.rows()[-1]["tags"]))

    def test_create_stage_order_publish_and_schema_defaults(self):
        inbounds = self.rows("inbounds")

        def runner(argv, env):
            self.runner(argv, env)
            if Path(argv[0]).name == "decoy-setup.sh":
                self.assertEqual(self.rows(), [])
            else:
                row = self.rows()[0]
                self.assertEqual(row["is_disabled"], 1)
                self.assertEqual(set(pc.tags(row["tags"])), {pc.MANAGED, pc.PENDING})
                self.assertEqual(argv[1:], ["apply", "--managed-pending"])

        result = self.make_controller(runner=runner).run_once()
        self.assertEqual(result["status"], "applied")
        row = self.rows()[0]
        self.assertEqual(row["address"], "edge.example.com")
        self.assertEqual(row["sni"], "edge.example.com")
        self.assertEqual(row["port"], 443)
        self.assertEqual(row["security"], "reality")
        self.assertEqual(row["is_disabled"], 0)
        self.assertEqual(pc.tags(row["tags"]), [pc.MANAGED])
        self.assertEqual(row["fingerprint"], "firefox")
        self.assertEqual(row["remark"], "schema-default")
        self.assertEqual(row["custom_default"], "preserve schema default")
        self.assertEqual(row["server_description"], "")
        self.assertEqual(self.rows("inbounds"), inbounds)
        self.assertEqual([args[1:] for args, _ in self.calls],
                         [["certificate"], ["apply"], ["apply", "--managed-pending"]])
        self.assertEqual(len(self.checks), 1)
        for _, env in self.calls:
            self.assertEqual(env["XUI_DB_PATH"], str(self.db))
            self.assertEqual(env["XUI_AUTO_DB_APPLY"], "false")
            self.assertEqual(env["XUI_SNI_ROUTER_INBOUNDS"], "1")
            self.assertEqual(env["XUI_SELFSTEAL_DOMAIN"], "edge.example.com")
            self.assertEqual(env["XUI_SELFSTEAL_EXTRA_DOMAINS"], "")

    def test_ca_and_site_failure_do_not_write_hosts(self):
        self.add_host(tags=pc.MANAGED)
        for fail_phase in ("certificate", "apply"):
            with self.subTest(phase=fail_phase):
                before = self.rows()

                def runner(argv, env):
                    if argv[1] == fail_phase:
                        raise RuntimeError("TOP-SECRET-KEY must not escape")

                with self.assertRaises(pc.ControllerError) as error:
                    self.make_controller(runner=runner).run_once()
                self.assertNotIn("TOP-SECRET", str(error.exception))
                self.assertEqual(self.rows(), before)
                self.assertFalse((self.state_dir / "state.json").exists())

    def test_backend_failure_preserves_previous_host_and_inbounds(self):
        self.add_host(tags=pc.MANAGED)
        hosts, inbounds = self.rows(), self.rows("inbounds")

        def bad_health(routes):
            raise RuntimeError("secret TLS error")

        with self.assertRaises(pc.ControllerError):
            self.make_controller(health=bad_health).run_once()
        self.assertEqual(self.rows(), hosts)
        self.assertEqual(self.rows("inbounds"), inbounds)
        self.assertEqual(len(self.calls), 2)

    def test_router_failure_restores_existing_but_retains_new_pending(self):
        self.add_host(tags='["custom","fork-managed"]')
        before = self.rows()[0]
        self.stream["realitySettings"]["serverNames"].append("extra.example.com")
        self.save_stream()

        def runner(argv, env):
            if Path(argv[0]).name == "sni-router.sh":
                self.assertTrue(all(row["is_disabled"] == 1 for row in self.rows()))
                return 1

        with self.assertRaises(pc.ControllerError):
            self.make_controller(runner=runner).run_once()
        self.assertEqual(self.rows()[0], before)
        pending = self.rows()[1]
        self.assertEqual(pending["is_disabled"], 1)
        self.assertIn(pc.PENDING, pc.tags(pending["tags"]))
        self.assertFalse((self.state_dir / "state.json").exists())
        # A fresh pass may recover a controller-created pending row.
        self.controller.run_once()
        self.assertEqual(len(self.rows()), 2)
        self.assertTrue(all(row["is_disabled"] == 0 for row in self.rows()))

    def test_fingerprint_and_alpn_only_no_worker_or_health_calls(self):
        self.controller.run_once()
        self.calls.clear()
        self.checks.clear()
        self.stream["realitySettings"]["settings"]["fingerprint"] = ""
        self.stream["realitySettings"]["alpn"] = []
        self.save_stream()
        self.controller.run_once()
        self.assertFalse(self.calls)
        self.assertFalse(self.checks)
        self.assertEqual(self.rows()[0]["fingerprint"], "")
        self.assertEqual(self.rows()[0]["alpn"], "[]")
        self.assertEqual(self.rows()[0]["is_disabled"], 0)
        self.assertNotIn(pc.PENDING, pc.tags(self.rows()[0]["tags"]))

    def test_missing_explicit_values_preserve_existing(self):
        del self.stream["realitySettings"]["settings"]["fingerprint"]
        self.save_stream()
        self.add_host(tags=pc.MANAGED)
        self.controller.run_once()
        self.assertEqual(self.rows()[0]["fingerprint"], "manual-fp")
        self.assertEqual(self.rows()[0]["alpn"], '["h2"]')

    def test_repeat_no_commands_db_or_state_writes(self):
        self.controller.run_once()
        self.calls.clear()
        self.checks.clear()
        db_before = self.db.read_bytes()
        state = self.state_dir / "state.json"
        state_before = (state.read_bytes(), state.stat().st_mtime_ns, state.stat().st_ino)
        with patch.object(self.controller.store, "save", side_effect=AssertionError("no save")):
            with patch.object(pc.sqlite3, "connect", wraps=sqlite3.connect) as connect:
                result = self.controller.run_once()
                self.assertTrue(all("mode=ro" in c.args[0] for c in connect.call_args_list))
        self.assertEqual(result["status"], "noop")
        self.assertEqual(self.db.read_bytes(), db_before)
        self.assertEqual((state.read_bytes(), state.stat().st_mtime_ns, state.stat().st_ino), state_before)
        self.assertFalse(self.calls)
        self.assertFalse(self.checks)

    def test_secret_only_edit_no_work_or_public_digest_change(self):
        self.controller.run_once()
        old = self.controller.plan()
        self.calls.clear()
        self.checks.clear()
        self.stream["realitySettings"]["privateKey"] = "DIFFERENT-PRIVATE-KEY"
        self.save_stream()
        self.execute("UPDATE inbounds SET settings=?", ('{"clients":[{"id":"NEW-SECRET"}]}',))
        new = self.controller.plan()
        self.assertEqual((old.site_digest, old.router_digest, old.host_digest),
                         (new.site_digest, new.router_digest, new.host_digest))
        self.assertEqual(self.controller.run_once()["status"], "noop")
        self.assertFalse(self.calls)
        self.assertFalse(self.checks)

    def test_disabled_managed_respected_for_both_tag_formats(self):
        for value in ("custom,fork-managed", '["custom","fork-managed"]'):
            with self.subTest(tags=value):
                self.execute("DELETE FROM hosts")
                self.add_host(tags=value, is_disabled=1)
                hosts, inbounds = self.rows(), self.rows("inbounds")
                self.assertEqual(self.controller.run_once()["status"], "skipped")
                self.assert_no_effects(hosts, inbounds)
                self.assertFalse(self.state_dir.exists())

    def test_disabled_host_suppresses_all_names_without_replacement(self):
        self.add_host(tags=pc.MANAGED, is_disabled=1)
        self.stream["realitySettings"]["serverNames"].append("second.example.com")
        self.save_stream()
        self.assertEqual(self.controller.run_once()["routes"], 0)
        self.assertEqual(len(self.rows()), 1)

    def test_pending_managed_can_resume_in_both_tag_formats(self):
        for value in ("fork-managed,fork-pending,custom", '["fork-managed","fork-pending","custom"]'):
            with self.subTest(tags=value):
                self.execute("DELETE FROM hosts")
                self.add_host(tags=value, is_disabled=1)
                self.controller.run_once()
                row = self.rows()[0]
                self.assertEqual(row["is_disabled"], 0)
                self.assertEqual(set(pc.tags(row["tags"])), {pc.MANAGED, "custom"})
                self.assertEqual(row["tags"].startswith("["), value.startswith("["))

    def test_invalid_domains_abort_without_effects(self):
        for names in ([], ["*.example.com"], ["bad.example.com:443"], ["a.example.com\n"],
                      ["127.0.0.1"], ["https://edge.example.com"], [None],
                      ["edge.example.com", "EDGE.EXAMPLE.COM"]):
            with self.subTest(names=names):
                self.stream["realitySettings"]["serverNames"] = names
                self.save_stream()
                hosts, inbounds = self.rows(), self.rows("inbounds")
                with self.assertRaises(pc.ControllerError):
                    self.controller.run_once()
                self.assert_no_effects(hosts, inbounds)
        self.assertFalse(self.state_dir.exists())

    def test_duplicate_domain_between_inbounds_aborts_entire_pass(self):
        self.execute("INSERT INTO inbounds (id,enable,protocol,listen,port,stream_settings) "
                     "VALUES (2,1,'vless','::1',12443,?)", (json.dumps(self.stream),))
        with self.assertRaises(pc.ControllerError):
            self.controller.run_once()
        self.assertFalse(self.rows())
        self.assertFalse(self.calls)

    def test_invalid_preparation_not_repaired(self):
        original = json.loads(json.dumps(self.stream))
        mutations = [
            ("UPDATE inbounds SET port=443", None),
            ("UPDATE inbounds SET port=10444", None),
            ("UPDATE inbounds SET port=80", None),
            (None, lambda s: s.update(network="ws")),
            (None, lambda s: s["sockopt"].update(acceptProxyProtocol=False)),
            (None, lambda s: s["realitySettings"].update(xver=True)),
            (None, lambda s: s["realitySettings"].update(target="example.com:443")),
            (None, lambda s: s["realitySettings"]["settings"].update(fingerprint=None)),
            (None, lambda s: s["realitySettings"].update(alpn="h2"))]
        for sql, mutation in mutations:
            with self.subTest(sql=sql, mutation=mutation):
                self.stream = json.loads(json.dumps(original))
                self.execute("UPDATE inbounds SET listen='127.0.0.1',port=11443")
                if sql:
                    self.execute(sql)
                if mutation:
                    mutation(self.stream)
                self.save_stream()
                hosts, inbounds = self.rows(), self.rows("inbounds")
                with self.assertRaises(pc.ControllerError):
                    self.controller.run_once()
                self.assert_no_effects(hosts, inbounds)

    def test_public_reality_is_not_reconfigured_or_blocking_prepared_profiles(self):
        public = json.loads(json.dumps(self.stream))
        public["realitySettings"]["serverNames"] = ["direct.example.com"]
        self.execute("INSERT INTO inbounds (id,enable,protocol,listen,port,stream_settings) "
                     "VALUES (2,1,'vless','0.0.0.0',443,?)", (json.dumps(public),))
        result = self.controller.run_once()
        self.assertEqual(result["status"], "applied")
        self.assertIn(2, result["skipped"])
        self.assertEqual([host["inbound_id"] for host in self.rows()], [1])
        self.assertEqual(self.rows("inbounds")[1]["listen"], "0.0.0.0")

    def test_live_traffic_counters_do_not_starve_reconciliation(self):
        self.execute("ALTER TABLE inbounds ADD COLUMN up INTEGER DEFAULT 0")
        self.execute("ALTER TABLE inbounds ADD COLUMN down INTEGER DEFAULT 0")

        def runner(argv, env):
            self.runner(argv, env)
            self.execute("UPDATE inbounds SET up=up+1,down=down+2")

        result = self.make_controller(runner=runner).run_once()
        self.assertEqual(result["status"], "applied")
        self.assertEqual(self.rows()[0]["is_disabled"], 0)
        self.assertGreater(self.rows("inbounds")[0]["up"], 0)

    def test_single_managed_domain_rename_updates_same_host_after_checks(self):
        host_id = self.add_host(tags=pc.MANAGED)
        self.controller.run_once()
        self.calls.clear()
        self.stream["realitySettings"]["serverNames"] = ["renamed.example.com"]
        self.save_stream()
        result = self.controller.run_once()
        self.assertEqual(result["status"], "applied")
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["id"], host_id)
        self.assertEqual(self.rows()[0]["sni"], "renamed.example.com")
        self.assertEqual(self.rows()[0]["is_disabled"], 0)

    def test_supported_transport_fields_and_ipv6(self):
        original = json.loads(json.dumps(self.stream))
        for network, options, expected in (
            ("raw", {}, ("", "")),
            ("xhttp", {"path": "/split", "host": "http.example.com"}, ("/split", "http.example.com")),
            ("splithttp", {"path": "/old", "host": "old.example.com"}, ("/old", "old.example.com")),
            ("grpc", {"serviceName": "service", "authority": "grpc.example.com"}, ("service", "grpc.example.com")),
            ("tcp", {"header": {"type": "http", "request": {
                "path": ["/raw"], "headers": {"Host": ["tcp.example.com"]}}}}, ("/raw", "tcp.example.com"))):
            with self.subTest(network=network):
                self.execute("DELETE FROM hosts")
                self.stream = json.loads(json.dumps(original))
                self.stream["network"] = network
                self.stream[network + "Settings"] = options
                self.save_stream()
                self.execute("UPDATE inbounds SET listen='::1'")
                plan = self.controller.plan()
                self.assertEqual(plan.routes[0].address, "::1")
                self.controller.run_once()
                row = self.rows()[0]
                self.assertEqual((row["path"], row["host_header"]), expected)

    def test_transport_alias_and_conflicting_aliases(self):
        self.stream.update(network="raw", tcpSettings={"header": {
            "type": "http", "request": {"path": ["/alias"]}}})
        self.save_stream()
        self.assertEqual(self.controller.plan().actions[0].values["path"], "/alias")
        self.stream["rawSettings"] = {}
        self.save_stream()
        with self.assertRaisesRegex(pc.ControllerError, "ambiguous"):
            self.controller.run_once()
        self.assertFalse(self.calls)

    def test_explicit_value_precedence_and_empty_new_host(self):
        reality = self.stream["realitySettings"]
        reality["fingerprint"] = "chrome"
        reality["settings"]["fingerprint"] = ""
        reality["alpn"] = []
        reality["settings"]["alpn"] = ["h2"]
        self.save_stream()
        self.controller.run_once()
        row = self.rows()[0]
        self.assertEqual((row["fingerprint"], row["alpn"]), ("", "[]"))

    def test_backend_only_change_needs_router_health_but_not_ca_site(self):
        self.controller.run_once()
        self.calls.clear()
        self.checks.clear()
        self.execute("UPDATE inbounds SET port=12443")
        before = self.rows()
        self.controller.run_once()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(Path(self.calls[0][0][0]).name, "sni-router.sh")
        self.assertEqual(self.checks[0][0].port, 12443)
        self.assertEqual(self.rows(), before)

    def test_state_host_digest_matches_published_projection(self):
        del self.stream["realitySettings"]["settings"]["fingerprint"]
        self.save_stream()
        self.controller.run_once()
        state = json.loads((self.state_dir / "state.json").read_text())
        self.assertEqual(state["host_digest"], self.controller.plan().host_digest)

    def test_updated_at_only_user_edit_prevents_publication(self):
        host_id = self.add_host(tags=pc.MANAGED)

        def runner(argv, env):
            if Path(argv[0]).name == "sni-router.sh":
                self.execute("UPDATE hosts SET updated_at=updated_at+1 WHERE id=?", (host_id,))

        with self.assertRaisesRegex(pc.ControllerError, "source changed"):
            self.make_controller(runner=runner).run_once()
        self.assertEqual(self.rows()[0]["is_disabled"], 1)
        self.assertIn(pc.PENDING, pc.tags(self.rows()[0]["tags"]))

    def test_default_runner_uses_argv_without_shell_and_discards_output(self):
        with patch.object(pc.subprocess, "run") as run:
            run.return_value.returncode = 0
            pc.run_command(["worker", "apply", "--managed-pending"], {"SAFE": "value"})
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["worker", "apply", "--managed-pending"])
        self.assertFalse(kwargs.get("shell", False))
        self.assertEqual(kwargs["env"], {"SAFE": "value"})
        self.assertEqual(kwargs["stdout"], pc.subprocess.DEVNULL)
        self.assertEqual(kwargs["stderr"], pc.subprocess.DEVNULL)
        self.assertTrue(kwargs["check"])

    def test_state_private_atomic_and_contains_no_secrets(self):
        self.controller.run_once()
        state_path = self.state_dir / "state.json"
        self.assertEqual(stat.S_IMODE(state_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.state_dir.stat().st_mode), 0o700)
        self.assertEqual(state_path.stat().st_uid, os.geteuid())
        payload = state_path.read_text()
        self.assertNotIn("TOP-SECRET", payload)
        self.assertNotIn("SECRET-CLIENT-UUID", payload)
        self.assertNotIn("privateKey", payload)
        self.assertNotIn("stream_settings", payload)
        self.assertNotIn("TOP-SECRET", repr(self.controller.plan()))
        self.assertEqual(set(json.loads(payload)),
                         {"version", "db_identity", "site_digest", "router_digest", "host_digest"})
        old_inode = state_path.stat().st_ino
        self.stream["realitySettings"]["settings"]["fingerprint"] = "safari"
        self.save_stream()
        self.controller.run_once()
        self.assertNotEqual(state_path.stat().st_ino, old_inode)
        self.assertFalse(list(self.state_dir.glob(".state-*")))

    def test_source_reread_under_write_lock_prevents_stale_staging(self):
        self.add_host(tags=pc.MANAGED)

        def health(routes):
            self.execute("UPDATE inbounds SET port=12443")

        before = self.rows()
        with self.assertRaisesRegex(pc.ControllerError, "source changed"):
            self.make_controller(health=health).run_once()
        self.assertEqual(self.rows(), before)
        self.assertEqual(len(self.calls), 2)  # no router/publication

    def test_user_edit_or_ownership_removal_blocks_publish_and_undo(self):
        for remove_ownership in (False, True):
            with self.subTest(remove_ownership=remove_ownership):
                self.execute("DELETE FROM hosts")
                host_id = self.add_host(tags=pc.MANAGED)
                user_row = []

                def runner(argv, env):
                    if Path(argv[0]).name == "sni-router.sh":
                        if remove_ownership:
                            self.execute("UPDATE hosts SET tags='user-only',fingerprint='user-edit' WHERE id=?", (host_id,))
                        else:
                            # Same updated_at: full expected-row comparison is required.
                            self.execute("UPDATE hosts SET fingerprint='user-edit' WHERE id=?", (host_id,))
                        user_row[:] = self.rows()

                with self.assertRaisesRegex(pc.ControllerError, "source changed"):
                    self.make_controller(runner=runner).run_once()
                self.assertEqual(self.rows(), user_row)
                self.assertEqual(self.rows()[0]["fingerprint"], "user-edit")
                self.assertFalse((self.state_dir / "state.json").exists())

    def test_router_failure_preserves_user_edit_but_restores_other_owned_row(self):
        self.stream["realitySettings"]["serverNames"].append("second.example.com")
        self.save_stream()
        first = self.add_host(tags=pc.MANAGED)
        self.add_host(tags=pc.MANAGED, sni="second.example.com")
        second = self.rows()[1]

        def runner(argv, env):
            if Path(argv[0]).name == "sni-router.sh":
                self.execute("UPDATE hosts SET remark='user change',updated_at=999 WHERE id=?", (first,))
                raise RuntimeError("router failed")

        with self.assertRaises(pc.ControllerError):
            self.make_controller(runner=runner).run_once()
        self.assertEqual(self.rows()[0]["remark"], "user change")
        self.assertEqual(self.rows()[0]["is_disabled"], 1)
        self.assertEqual(self.rows()[1], second)

    def test_database_replacement_not_published_or_rolled_back(self):
        self.add_host(tags=pc.MANAGED)
        replacement = self.directory / "restore.db"
        with connection(self.db) as source, connection(replacement) as destination:
            source.backup(destination)
        expected = self.rows()

        def runner(argv, env):
            if Path(argv[0]).name == "sni-router.sh":
                os.replace(replacement, self.db)
                return 1

        with self.assertRaises(pc.ControllerError):
            self.make_controller(runner=runner).run_once()
        self.assertEqual(self.rows(), expected)
        self.assertFalse((self.state_dir / "state.json").exists())

    def test_state_replacement_prevents_publication_and_rollback(self):
        self.add_host(tags=pc.MANAGED)

        def runner(argv, env):
            if Path(argv[0]).name == "sni-router.sh":
                foreign = self.state_dir / "state.json"
                foreign.write_text('{"version":1,"foreign":true}')
                foreign.chmod(0o600)

        with self.assertRaisesRegex(pc.ControllerError, "state was replaced"):
            self.make_controller(runner=runner).run_once()
        row = self.rows()[0]
        self.assertEqual(row["is_disabled"], 1)
        self.assertIn(pc.PENDING, pc.tags(row["tags"]))
        self.assertTrue(json.loads((self.state_dir / "state.json").read_text())["foreign"])

    def test_concurrent_controller_rejected(self):
        second = self.make_controller()

        def runner(argv, env):
            if argv[1] == "certificate":
                with self.assertRaisesRegex(pc.ControllerError, "another controller"):
                    second.run_once()

        self.make_controller(runner=runner).run_once()
        self.assertEqual(len(self.rows()), 1)

    def test_unsafe_state_permissions_rejected_before_commands(self):
        self.state_dir.mkdir(mode=0o755)
        with self.assertRaises(pc.ControllerError):
            self.controller.run_once()
        self.assertFalse(self.calls)
        self.assertFalse(self.rows())

    def test_unknown_required_column_fails_before_commands(self):
        self.execute("ALTER TABLE hosts ADD COLUMN unsupported TEXT NOT NULL")
        with self.assertRaises(pc.ControllerError):
            self.controller.run_once()
        self.assertFalse(self.calls)

    def test_schema_without_updated_at_still_has_full_expected_guard(self):
        self.execute("ALTER TABLE hosts DROP COLUMN updated_at")
        self.controller.run_once()
        self.assertEqual(self.rows()[0]["is_disabled"], 0)
        self.assertEqual(self.controller.run_once()["status"], "noop")

    def test_cli_dry_run_and_disabled_once_never_execute_workers(self):
        with patch.dict(os.environ, self.env, clear=True):
            with patch.object(pc, "run_command", side_effect=AssertionError("never execute")):
                output = io.StringIO()
                with redirect_stdout(output):
                    result = pc.main(["--once", "--dry-run", "--db", str(self.db),
                                      "--state-dir", str(self.state_dir), "--scripts-dir", str(ROOT)])
                self.assertEqual(result, 0)
                self.assertIn('"status": "planned"', output.getvalue())
        with patch.dict(os.environ, {}, clear=True), redirect_stdout(io.StringIO()):
            self.assertEqual(pc.main(["--once", "--db", str(self.directory / "missing")]), 0)
        self.assertFalse(self.state_dir.exists())


if __name__ == "__main__":
    unittest.main()
