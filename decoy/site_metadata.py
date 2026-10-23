#!/usr/bin/env python3
"""Render ShopFlow crawl metadata for an explicitly configured site origin.

No DB, network, environment sourcing or service actions. Aliases share the
configured primary HTTPS origin; request Host headers never select an identity.
HTTP is permitted only for loopback preview. Shipped metadata contains an origin
marker and must be rendered by decoy-setup before serving the template.
"""

import argparse
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit
from xml.sax.saxutils import escape


PAGES = ("", "solutions.html", "pricing.html", "privacy.html", "terms.html")


def valid_origin(value):
    if not isinstance(value, str) or any(ord(c) < 33 for c in value):
        raise ValueError("invalid site origin")
    try:
        url = urlsplit(value)
        port = url.port
    except ValueError:
        raise ValueError("invalid site origin") from None
    host = url.hostname or ""
    dns = re.fullmatch(r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+"
                       r"[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", host)
    loopback = host in ("localhost", "127.0.0.1", "::1")
    if (url.username is not None or url.password is not None or url.path not in ("", "/")
            or url.query or url.fragment or len(host) > 253
            or not (dns or loopback) or (port is not None and not 1 <= port <= 65535)
            or url.scheme not in ("https", "http") or (url.scheme == "http" and not loopback)):
        raise ValueError("expected a configured HTTPS origin or loopback preview URL")
    host = "[::1]" if host == "::1" else host.lower()
    return url.scheme + "://" + host + (":" + str(port) if port is not None else "")


def render(directory, origin):
    origin = valid_origin(origin)
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("site directory missing/unsafe")
    # Validate all prerequisites before touching either output file.
    for page in ("index.html",) + PAGES[1:]:
        path = directory / page
        if path.is_symlink() or not path.is_file():
            raise ValueError("required ShopFlow page missing/unsafe")
    robots = ("User-agent: *\nAllow: /\nDisallow: /api/private/\n"
              "Disallow: /portal/auth/\nDisallow: /admin/\n\n"
              "Sitemap: " + origin + "/sitemap.xml\n")
    sitemap = ('<?xml version="1.0" encoding="UTF-8"?>\n'
               '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
               "".join("  <url><loc>" + escape(origin + "/" + page) + "</loc></url>\n"
                       for page in PAGES) + "</urlset>\n")
    outputs = {"robots.txt": robots, "sitemap.xml": sitemap}
    for name in outputs:
        if (directory / name).is_symlink():
            raise ValueError("metadata symlinks are not supported")
    changed = []
    for name, content in outputs.items():
        path = directory / name
        if path.is_file() and path.read_text(encoding="utf-8") == content:
            continue
        fd, temporary = tempfile.mkstemp(prefix=".metadata-", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o644)
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        changed.append(name)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--origin", required=True)
    args = parser.parse_args()
    try:
        render(args.root, args.origin)
    except (ValueError, OSError):
        parser.exit(1, "[SITE-ERROR] Cannot render site metadata; check origin/root/pages\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
