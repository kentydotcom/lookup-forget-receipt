# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Tiny JSON + static HTTP helper (stdlib only)."""

from __future__ import annotations

import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import unquote, urlparse

Handler = Callable[[BaseHTTPRequestHandler, bytes], tuple[int, Any]]


def make_handler(
    *,
    routes: dict[tuple[str, str], Handler],
    static_dir: Path | None = None,
    static_prefix: str = "/diagrams/",
    index_html: Path | None = None,
) -> type[BaseHTTPRequestHandler]:
    class App(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            print("[agent] " + (fmt % args), flush=True)

        def _body(self) -> bytes:
            length = int(self.headers.get("Content-Length", "0") or "0")
            return self.rfile.read(length) if length else b""

        def _send(self, status: int, payload: Any, content_type: str | None = None) -> None:
            if isinstance(payload, (dict, list)):
                body = json.dumps(payload, indent=2).encode("utf-8")
                content_type = "application/json; charset=utf-8"
            elif isinstance(payload, bytes):
                body = payload
                content_type = content_type or "application/octet-stream"
            else:
                body = str(payload).encode("utf-8")
                content_type = content_type or "text/plain; charset=utf-8"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _dispatch(self, method: str) -> None:
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            if method == "GET" and path in ("/", "/index.html") and index_html and index_html.is_file():
                self._send(200, index_html.read_bytes(), "text/html; charset=utf-8")
                return
            if method == "GET" and static_dir and path.startswith(static_prefix):
                rel = path[len(static_prefix) :].lstrip("/")
                dest = (static_dir / rel).resolve()
                if not str(dest).startswith(str(static_dir.resolve())) or not dest.is_file():
                    self._send(404, {"error": "not found"})
                    return
                ctype = mimetypes.guess_type(dest.name)[0] or "application/octet-stream"
                self._send(200, dest.read_bytes(), ctype)
                return
            key = (method, path)
            handler = routes.get(key)
            if handler is None:
                self._send(404, {"error": "not found", "path": path})
                return
            try:
                status, payload = handler(self, self._body())
            except ValueError as exc:
                self._send(400, {"error": str(exc)})
                return
            except Exception as exc:
                self._send(500, {"error": type(exc).__name__, "detail": str(exc)})
                return
            self._send(status, payload)

        def do_GET(self) -> None:  # noqa: N802
            self._dispatch("GET")

        def do_POST(self) -> None:  # noqa: N802
            self._dispatch("POST")

        def do_PUT(self) -> None:  # noqa: N802
            self._dispatch("PUT")

    return App


def serve(host: str, port: int, handler_cls: type[BaseHTTPRequestHandler]) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((host, port), handler_cls)
    return httpd
