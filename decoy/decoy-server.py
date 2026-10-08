#!/usr/bin/env python3
"""
Lightweight fallback HTTPS server for Decoy Site (SelfSteal).
Serves static files over TLS when nginx is not installed.
"""

import sys
import os
import ssl
from http.server import HTTPServer, SimpleHTTPRequestHandler

class DecoyHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, directory=None, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def do_GET(self):
        # Serve index.html for 404 or missing paths
        path = self.translate_path(self.path)
        if not os.path.exists(path):
            self.path = "/index.html"
        return super().do_GET()

    def log_message(self, format, *args):
        # Silent or minimal logging
        pass

def main():
    port = int(os.environ.get("XUI_SELFSTEAL_PORT", "10444"))
    host = os.environ.get("XUI_SELFSTEAL_HOST", "127.0.0.1")
    doc_root = os.environ.get("XUI_SELFSTEAL_DIR", "/usr/local/x-ui/decoy/public")
    cert_file = os.environ.get("XUI_SELFSTEAL_CERT", "/etc/x-ui/fallback-inbound.crt")
    key_file = os.environ.get("XUI_SELFSTEAL_KEY", "/etc/x-ui/fallback-inbound.key")

    if not os.path.isdir(doc_root):
        fallback_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public")
        if os.path.isdir(fallback_dir):
            doc_root = fallback_dir

    if not (os.path.isfile(cert_file) and os.path.isfile(key_file)):
        sys.stderr.write(f"[DECOY-ERROR] Missing certificate files: {cert_file}, {key_file}\n")
        sys.exit(1)

    handler = lambda *args, **kwargs: DecoyHandler(*args, directory=doc_root, **kwargs)
    httpd = HTTPServer((host, port), handler)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert_file, keyfile=key_file)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    print(f"[DECOY-PY] Serving Decoy Site on https://{host}:{port} from {doc_root}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

if __name__ == "__main__":
    main()
