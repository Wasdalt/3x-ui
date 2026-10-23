"""ShopFlow assets/metadata/UI contracts; no services, network or real databases."""

from html.parser import HTMLParser
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "decoy/templates/shopflow"
PUBLIC = ROOT / "decoy/public"
spec = importlib.util.spec_from_file_location("site_metadata", ROOT / "decoy/site_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.links, self.inputs = set(), [], []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                raise AssertionError("duplicate HTML id")
            self.ids.add(attrs["id"])
        self.links.extend(attrs[k] for k in ("href", "src") if k in attrs)
        if tag == "input":
            self.inputs.append(attrs)


class ShopFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="shopflow-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.site = self.work / "site"
        shutil.copytree(TEMPLATE, self.site)

    def test_all_page_links_and_fragments_exist(self):
        for directory in (TEMPLATE, PUBLIC):
            pages = {}
            for path in directory.glob("*.html"):
                parser = Page()
                parser.feed(path.read_text())
                pages[path.resolve()] = parser
            self.assertEqual(len(pages), 5)
            for path, page in pages.items():
                for link in page.links:
                    with self.subTest(root=directory.name, page=path.name, link=link):
                        url = urlsplit(link)
                        if url.scheme or url.netloc:
                            continue
                        target = ((directory / unquote(url.path).lstrip("/")) if url.path.startswith("/")
                                  else path.parent / unquote(url.path)) if url.path else path
                        if target.is_dir():
                            target /= "index.html"
                        target = target.resolve()
                        self.assertTrue(target.is_file())
                        if url.fragment and target in pages:
                            self.assertIn(url.fragment, pages[target].ids)

    def test_public_copy_matches_template(self):
        for path in TEMPLATE.rglob("*"):
            if path.is_file():
                self.assertEqual(path.read_bytes(), (PUBLIC / path.relative_to(TEMPLATE)).read_bytes())

    def test_no_foreign_domain_or_live_credential_example(self):
        for path in TEMPLATE.rglob("*"):
            if path.suffix in (".html", ".xml", ".txt", ".js"):
                self.assertNotIn("shopflow.io", path.read_text())
                self.assertNotIn("sec_live_", path.read_text())

    def test_forms_do_not_collect_credentials_or_contact_details(self):
        for path in TEMPLATE.glob("*.html"):
            page = Page()
            page.feed(path.read_text())
            self.assertFalse(any(field.get("type") in ("password", "email") for field in page.inputs))
        source = (TEMPLATE / "js/app.js").read_text()
        for forbidden in ("fetch(", "XMLHttpRequest", "sendBeacon", "localStorage", "sessionStorage",
                          "Заявка успешно принята", "Проверка ключа доступа"):
            self.assertNotIn(forbidden, source)
        self.assertIn("заявка не отправлена", source)

    def test_render_configured_origin_and_all_pages(self):
        self.assertEqual(set(metadata.render(self.site, "https://studio.example.com")),
                         {"robots.txt", "sitemap.xml"})
        xml = ET.parse(self.site / "sitemap.xml")
        locations = [el.text for el in xml.findall(".//{*}loc")]
        self.assertEqual(locations, ["https://studio.example.com/" + page for page in metadata.PAGES])
        self.assertIn("Sitemap: https://studio.example.com/sitemap.xml", (self.site / "robots.txt").read_text())
        self.assertNotIn("__SITE_ORIGIN__", (self.site / "sitemap.xml").read_text())

    def test_render_is_idempotent_and_updates_domain_without_template_switch(self):
        metadata.render(self.site, "https://studio.example.com")
        before = {name: (self.site / name).stat().st_mtime_ns for name in ("robots.txt", "sitemap.xml")}
        self.assertEqual(metadata.render(self.site, "https://studio.example.com"), [])
        self.assertEqual(before, {name: (self.site / name).stat().st_mtime_ns for name in before})
        metadata.render(self.site, "https://media.example.com")
        for name in before:
            self.assertNotIn("studio.example.com", (self.site / name).read_text())
            self.assertIn("media.example.com", (self.site / name).read_text())

    def test_loopback_preview_and_https_port(self):
        for origin in ("http://localhost:8080", "http://127.0.0.1:8090", "http://[::1]:8080",
                       "https://studio.example.com:10443"):
            with self.subTest(origin=origin):
                metadata.render(self.site, origin)
                self.assertIn(origin + "/sitemap.xml", (self.site / "robots.txt").read_text())

    def test_invalid_origins_rejected_without_any_writes(self):
        before = {p.name: p.read_bytes() for p in self.site.iterdir() if p.is_file()}
        for origin in ("", "http://foreign.example.com", "https://*.example.com", "https://localhost:99999",
                       "https://user:password@example.com", "https://example.com/path", "https://example.com?x=1",
                       "https://example.com#frag", "https://example.com\nSitemap:evil", "javascript:alert(1)"):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                metadata.render(self.site, origin)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.site.iterdir() if p.is_file()})

    def test_missing_page_and_symlink_refused_before_output_writes(self):
        old = (self.site / "robots.txt").read_bytes()
        (self.site / "terms.html").unlink()
        with self.assertRaises(ValueError):
            metadata.render(self.site, "https://studio.example.com")
        self.assertEqual((self.site / "robots.txt").read_bytes(), old)
        shutil.copyfile(TEMPLATE / "terms.html", self.site / "terms.html")
        outside = self.work / "outside.xml"
        outside.write_text("keep")
        (self.site / "sitemap.xml").unlink()
        (self.site / "sitemap.xml").symlink_to(outside)
        with self.assertRaises(ValueError):
            metadata.render(self.site, "https://studio.example.com")
        self.assertEqual(outside.read_text(), "keep")
        self.assertEqual((self.site / "robots.txt").read_bytes(), old)

    def test_shell_metadata_helper_is_isolated_from_services_and_environment(self):
        empty = self.work / "empty.env"
        empty.write_text("")
        env = {key: value for key, value in os.environ.items() if not key.startswith("XUI_")}
        env.update(XUI_ENV_FILE=str(empty), XUI_SELFSTEAL_TEMPLATE="shopflow", PYTHONDONTWRITEBYTECODE="1")
        body = '''source "$1"
PUBLIC_DIR="$2"
systemctl() { echo UNEXPECTED-SERVICE >&2; return 99; }
certbot() { echo UNEXPECTED-CA >&2; return 99; }
prepare_site_metadata https://studio.example.com
'''
        result = subprocess.run(["bash", "-c", body, "test", str(ROOT / "decoy-setup.sh"), str(self.site)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("UNEXPECTED", result.stderr)
        self.assertEqual(empty.read_text(), "")
        self.assertIn("https://studio.example.com/", (self.site / "sitemap.xml").read_text())

    @unittest.skipUnless(shutil.which("node"), "requires node for an offline DOM harness")
    def test_javascript_modals_calculation_navigation_and_escape_offline(self):
        harness = r'''
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync(process.argv[1], 'utf8');
function build(hasModals, search = '') {
  const events = {}, ids = {}, buttons = {}, location = {search, origin: 'https://media.example.com', assign(v) { this.assigned = v; }};
  const doc = {activeElement: null, getElementById(id) { return ids[id] || null; },
    querySelectorAll(selector) { return buttons[selector] || []; },
    addEventListener(event, handler) { events[event] = handler; }};
  function element(id) {
    const classes = new Set();
    const el = {value: '', textContent: '', attrs: {}, handlers: {}, focus() { doc.activeElement = this; },
      classList: {add(v) { classes.add(v); }, remove(v) { classes.delete(v); }, contains(v) { return classes.has(v); }},
      setAttribute(k,v) { this.attrs[k] = v; }, addEventListener(k,v) { this.handlers[k] = v; },
      querySelector() { return this.items[0]; }, querySelectorAll() { return this.items; }, items: []};
    if (id) ids[id] = el;
    return el;
  }
  buttons['.btn-trigger-demo'] = [element()]; buttons['.btn-trigger-portal'] = [element()];
  doc.activeElement = buttons['.btn-trigger-demo'][0];
  if (hasModals) {
    for (const id of ['demoModal','portalModal','closeDemoModal','closePortalModal','demoForm','demoOrderCount','demoResult']) element(id);
    ids.demoModal.items = [ids.closeDemoModal, ids.demoOrderCount];
    ids.portalModal.items = [ids.closePortalModal];
    ids.demoOrderCount.value = '75000';
  }
  const context = {document: doc, window: {location}, URLSearchParams,
    fetch() { throw Error('network forbidden'); }, setTimeout() { throw Error('timer forbidden'); }};
  vm.createContext(context); vm.runInContext(source, context); context.initModals();
  return {events, ids, buttons, location, doc};
}
const main = build(true);
const click = () => ({preventDefault() {}});
main.buttons['.btn-trigger-demo'][0].handlers.click(click());
assert(main.ids.demoModal.classList.contains('active'));
main.ids.demoForm.handlers.submit(click());
assert(main.ids.demoResult.textContent.includes('заявка не отправлена'));
assert(main.ids.demoResult.textContent.replace(/[^0-9]/g,'').includes('315000'));
main.ids.demoOrderCount.value = '0'; main.ids.demoForm.handlers.submit(click());
assert(main.ids.demoResult.textContent.includes('Введите целое'));
main.events.keydown({key: 'Escape'}); assert(!main.ids.demoModal.classList.contains('active'));
assert.strictEqual(main.doc.activeElement, main.buttons['.btn-trigger-demo'][0]);
main.buttons['.btn-trigger-portal'][0].handlers.click(click()); assert(main.ids.portalModal.classList.contains('active'));
assert(build(true, '?view=demo').ids.demoModal.classList.contains('active'));
const secondary = build(false); secondary.buttons['.btn-trigger-demo'][0].handlers.click(click());
assert.strictEqual(secondary.location.assigned, '/?view=demo');
secondary.buttons['.btn-trigger-portal'][0].handlers.click(click());
assert.strictEqual(secondary.location.assigned, '/?view=portal');
assert.strictEqual(build(false, '?view=https://evil.example').location.assigned, undefined);
'''
        result = subprocess.run(["node", "-e", harness, str(TEMPLATE / "js/app.js")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
