#!/usr/bin/env python3
"""
Локальный мульти-сервер предпросмотра сайтов-заглушек (Decoy Previewer)
Позволяет интерактивно просматривать и переключать все 4 русскоязычных шаблона:
  1. shopflow   — Платформа облачной коммерции и диспетчеризации
  2. converter  — OmniConvert: веб-инструменты разработчика
  3. tech       — Vortex Cloud: облачный хостинг и серверы
  4. corporate  — Apex Global Advisory: IT-консалтинг и аудит

Запуск:
  python3 decoy/preview_server.py [порт, по умолчанию 8080]
"""

import http.server
import socketserver
import os
import sys
import mimetypes
import shutil
import json
import urllib.parse
from http import cookies

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATES_DIR = os.path.join(BASE_DIR, "decoy", "templates")
PUBLIC_DIR = os.path.join(BASE_DIR, "decoy", "public")
ENV_FILE = os.path.join(BASE_DIR, ".env")

TEMPLATES_META = {
    "shopflow": {
        "title": "ShopFlow",
        "icon": "🛍️",
        "desc": "Облачная коммерция и логистика",
        "badge": "E-Commerce / B2B"
    },
    "converter": {
        "title": "OmniConvert",
        "icon": "🛠️",
        "desc": "Веб-инструменты и конвертер файлов",
        "badge": "DevTools / Web App"
    },
    "tech": {
        "title": "Vortex Cloud",
        "icon": "⚡",
        "desc": "Облачный NVMe хостинг и серверы",
        "badge": "Cloud / Hosting"
    },
    "corporate": {
        "title": "Apex Advisory",
        "icon": "🏛️",
        "desc": "IT-консалтинг и цифровая трансформация",
        "badge": "Corporate / Advisory"
    }
}

def get_current_active():
    if os.path.isfile(ENV_FILE):
        try:
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("XUI_SELFSTEAL_TEMPLATE="):
                        val = line.strip().split("=", 1)[1].strip("'\"")
                        if val in TEMPLATES_META:
                            return val
        except Exception:
            pass
    return "shopflow"

def activate_template(tpl_name):
    if tpl_name not in TEMPLATES_META:
        return False, "Неизвестный шаблон"
    src_dir = os.path.join(TEMPLATES_DIR, tpl_name)
    if not os.path.isdir(src_dir):
        return False, "Директория шаблона не найдена"

    os.makedirs(PUBLIC_DIR, exist_ok=True)
    for item in os.listdir(PUBLIC_DIR):
        if item == ".gitkeep":
            continue
        p = os.path.join(PUBLIC_DIR, item)
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        else:
            try:
                os.remove(p)
            except Exception:
                pass

    for item in os.listdir(src_dir):
        s = os.path.join(src_dir, item)
        d = os.path.join(PUBLIC_DIR, item)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)

    if os.path.isfile(ENV_FILE):
        try:
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                lines = f.readlines()
            updated = False
            for i, line in enumerate(lines):
                if line.startswith("XUI_SELFSTEAL_TEMPLATE="):
                    lines[i] = f"XUI_SELFSTEAL_TEMPLATE={tpl_name}\n"
                    updated = True
                    break
            if not updated:
                lines.append(f"\nXUI_SELFSTEAL_TEMPLATE={tpl_name}\n")
            with open(ENV_FILE, "w", encoding="utf-8") as f:
                f.writelines(lines)
        except Exception:
            pass

    return True, f"Шаблон {tpl_name} успешно активирован в decoy/public"

PREVIEW_TOOLBAR_CSS = """
<style id="decoy-preview-style">
  #decoy-toolbar {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 999999;
    background: rgba(15, 23, 42, 0.94);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border-bottom: 1px solid rgba(255, 255, 255, 0.12);
    color: #f8fafc;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    font-size: 13px;
    box-shadow: 0 4px 20px rgba(0,0,0,0.35);
    transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1);
  }
  #decoy-toolbar.collapsed {
    transform: translateY(-100%);
  }
  .decoy-bar-inner {
    max-width: 1300px;
    margin: 0 auto;
    padding: 8px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
  }
  .decoy-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 700;
    color: #38bdf8;
    text-decoration: none;
    letter-spacing: -0.01em;
  }
  .decoy-title span {
    color: #94a3b8;
    font-weight: 400;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .decoy-tabs {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .decoy-tab {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: 6px;
    background: rgba(255, 255, 255, 0.06);
    color: #cbd5e1;
    text-decoration: none;
    font-size: 12px;
    font-weight: 500;
    border: 1px solid rgba(255, 255, 255, 0.08);
    transition: all 0.2s ease;
  }
  .decoy-tab:hover {
    background: rgba(255, 255, 255, 0.15);
    color: #ffffff;
    border-color: rgba(255, 255, 255, 0.2);
  }
  .decoy-tab.active {
    background: #0284c7;
    color: #ffffff;
    border-color: #38bdf8;
    box-shadow: 0 0 12px rgba(56, 189, 248, 0.4);
  }
  .decoy-tab .badge {
    font-size: 9px;
    padding: 2px 5px;
    background: rgba(0,0,0,0.3);
    border-radius: 4px;
    color: #94a3b8;
  }
  .decoy-tab.active .badge {
    background: rgba(255,255,255,0.25);
    color: #ffffff;
  }
  .decoy-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .decoy-btn-activate {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    background: #10b981;
    color: #ffffff;
    border: none;
    padding: 6px 12px;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.2s;
  }
  .decoy-btn-activate:hover {
    background: #059669;
  }
  .decoy-btn-toggle {
    background: transparent;
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: #94a3b8;
    padding: 6px 10px;
    border-radius: 6px;
    font-size: 12px;
    cursor: pointer;
  }
  .decoy-btn-toggle:hover {
    color: #ffffff;
    background: rgba(255, 255, 255, 0.08);
  }
  #decoy-trigger-tab {
    position: fixed;
    top: 0;
    right: 20px;
    z-index: 999998;
    background: #0f172a;
    color: #38bdf8;
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-top: none;
    padding: 4px 12px;
    border-bottom-left-radius: 6px;
    border-bottom-right-radius: 6px;
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    display: none;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  }
  #decoy-toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    z-index: 1000000;
    background: #0f172a;
    border: 1px solid #10b981;
    color: #f8fafc;
    padding: 12px 18px;
    border-radius: 8px;
    box-shadow: 0 10px 25px rgba(0,0,0,0.4);
    font-size: 13px;
    display: none;
    align-items: center;
    gap: 8px;
  }
  body {
    padding-top: 52px !important;
  }
  body.decoy-collapsed {
    padding-top: 0 !important;
  }
</style>
"""

PREVIEW_TOOLBAR_JS = """
<script id="decoy-preview-script">
  function toggleDecoyBar(show) {
    const bar = document.getElementById('decoy-toolbar');
    const trigger = document.getElementById('decoy-trigger-tab');
    if (show) {
      bar.classList.remove('collapsed');
      document.body.classList.remove('decoy-collapsed');
      trigger.style.display = 'none';
      localStorage.setItem('decoy_bar_open', '1');
    } else {
      bar.classList.add('collapsed');
      document.body.classList.add('decoy-collapsed');
      trigger.style.display = 'block';
      localStorage.setItem('decoy_bar_open', '0');
    }
  }

  function activateOnVps(templateName) {
    const btn = document.getElementById('btnActivate');
    const oldText = btn.innerHTML;
    btn.innerHTML = '⏳ Сохранение...';
    btn.disabled = true;

    fetch('/api/activate?template=' + encodeURIComponent(templateName))
      .then(res => res.json())
      .then(data => {
        showToast('✓ Шаблон \"' + templateName + '\" успешно установлен в decoy/public для VPS!');
        btn.innerHTML = '✓ Активен на VPS';
        setTimeout(() => {
          btn.innerHTML = oldText;
          btn.disabled = false;
        }, 3000);
      })
      .catch(err => {
        showToast('Ошибка при активации: ' + err);
        btn.innerHTML = oldText;
        btn.disabled = false;
      });
  }

  function showToast(msg) {
    const toast = document.getElementById('decoy-toast');
    toast.textContent = msg;
    toast.style.display = 'flex';
    setTimeout(() => {
      toast.style.display = 'none';
    }, 4000);
  }

  document.addEventListener('DOMContentLoaded', () => {
    if (localStorage.getItem('decoy_bar_open') === '0') {
      toggleDecoyBar(false);
    }
  });
</script>
"""

class DecoyHandler(http.server.BaseHTTPRequestHandler):
    def get_cookie(self, name):
        if "Cookie" in self.headers:
            c = cookies.SimpleCookie(self.headers["Cookie"])
            if name in c:
                return c[name].value
        return None

    def get_active_template(self):
        cookie_val = self.get_cookie("decoy_template")
        if cookie_val in TEMPLATES_META:
            return cookie_val
        return get_current_active()

    def do_HEAD(self):
        self.handle_request(is_head=True)

    def do_GET(self):
        self.handle_request(is_head=False)

    def handle_request(self, is_head=False):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        # 1. API: Активация шаблона для VPS
        if path == "/api/activate":
            tpl = query.get("template", [None])[0]
            ok, msg = activate_template(tpl)
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            if not is_head:
                self.wfile.write(json.dumps({"ok": ok, "message": msg, "template": tpl}).encode("utf-8"))
            return

        # 2. API: Health check
        if path == "/api/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            if not is_head:
                self.wfile.write(b'{"status":"ok","engine":"Decoy-Previewer"}')
            return

        # 3. Переключение шаблона через ?template=NAME
        tpl_param = query.get("template", [None])[0]
        if tpl_param in TEMPLATES_META:
            # Устанавливаем cookie и делаем 302 редирект на чистый путь
            self.send_response(302)
            self.send_header("Set-Cookie", f"decoy_template={tpl_param}; Path=/; Max-Age=86400")
            clean_url = path if path else "/"
            self.send_header("Location", clean_url)
            self.end_headers()
            return

        # 4. Определение шаблона
        current_tpl = self.get_active_template()
        tpl_dir = os.path.join(TEMPLATES_DIR, current_tpl)

        # Нормализация пути к файлу
        rel_path = path.lstrip("/")
        if not rel_path or rel_path == "":
            rel_path = "index.html"

        file_path = os.path.join(tpl_dir, rel_path)

        # Поддержка try_files $uri $uri.html
        if not os.path.isfile(file_path) and os.path.isfile(file_path + ".html"):
            file_path = file_path + ".html"

        # Fallback к decoy/public если не найдено в шаблоне
        if not os.path.isfile(file_path):
            fallback_path = os.path.join(PUBLIC_DIR, rel_path)
            if os.path.isfile(fallback_path):
                file_path = fallback_path
            elif os.path.isfile(fallback_path + ".html"):
                file_path = fallback_path + ".html"

        if not os.path.isfile(file_path):
            self.send_response(404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            if not is_head:
                self.wfile.write(b"<h1>404 Not Found</h1><p><a href='/'>&larr; Return to main page</a></p>")
            return

        # Определение типа контента
        content_type, _ = mimetypes.guess_type(file_path)
        if not content_type:
            if file_path.endswith(".svg"):
                content_type = "image/svg+xml"
            elif file_path.endswith(".ico"):
                content_type = "image/x-icon"
            elif file_path.endswith(".webmanifest"):
                content_type = "application/manifest+json"
            else:
                content_type = "application/octet-stream"

        try:
            with open(file_path, "rb") as f:
                content = f.read()
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            return

        # Если это HTML, внедряем панель переключения шаблонов
        if "text/html" in content_type:
            html_text = content.decode("utf-8", errors="replace")

            # Генерация панели
            tabs_html = []
            for k, meta in TEMPLATES_META.items():
                is_active = (k == current_tpl)
                active_cls = "active" if is_active else ""
                tabs_html.append(
                    f'<a href="/?template={k}" class="decoy-tab {active_cls}">'
                    f'<span>{meta["icon"]}</span> <strong>{meta["title"]}</strong> '
                    f'<span class="badge">{meta["badge"]}</span></a>'
                )

            toolbar_html = f"""
            {PREVIEW_TOOLBAR_CSS}
            <div id="decoy-toolbar">
              <div class="decoy-bar-inner">
                <a href="/" class="decoy-title">
                  🎭 Decoy Previewer
                  <span>| 4 заглушки</span>
                </a>
                <div class="decoy-tabs">
                  {''.join(tabs_html)}
                </div>
                <div class="decoy-actions">
                  <button id="btnActivate" class="decoy-btn-activate" onclick="activateOnVps('{current_tpl}')" title="Сделать этот шаблон активным для Nginx/VPS">
                    ✓ Сделать активным на VPS
                  </button>
                  <button class="decoy-btn-toggle" onclick="toggleDecoyBar(false)" title="Скрыть панель предпросмотра">
                    ✕ Скрыть
                  </button>
                </div>
              </div>
            </div>
            <button id="decoy-trigger-tab" onclick="toggleDecoyBar(true)">
              🎭 Выбрать шаблон ({TEMPLATES_META[current_tpl]['title']})
            </button>
            <div id="decoy-toast"></div>
            {PREVIEW_TOOLBAR_JS}
            """

            if "</body>" in html_text:
                html_text = html_text.replace("</body>", f"{toolbar_html}</body>", 1)
            else:
                html_text += toolbar_html

            content = html_text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            if not is_head:
                self.wfile.write(content)
            return

        # Статические файлы
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        if not is_head:
            self.wfile.write(content)

    def log_message(self, format, *args):
        # Лаконичные логи без мусора
        sys.stderr.write(f"[DecoyPreview] {self.address_string()} - {format % args}\n")

def run(port=8080):
    handler = DecoyHandler
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", port), handler) as httpd:
        print(f"=====================================================")
        print(f"🚀 Decoy Multi-Template Previewer запущен на порту {port}")
        print(f"👉 Откройте в браузере: http://localhost:{port}")
        print(f"=====================================================")
        print(f"Доступные шаблоны:")
        for k, m in TEMPLATES_META.items():
            print(f"  - {m['icon']} {m['title']:<15} http://localhost:{port}/?template={k}")
        print(f"=====================================================")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nОстановка сервера...")
            httpd.server_close()

if __name__ == "__main__":
    p = 8080
    if len(sys.argv) > 1:
        try:
            p = int(sys.argv[1])
        except ValueError:
            pass
    run(p)
