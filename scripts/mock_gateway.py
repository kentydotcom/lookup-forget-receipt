#!/usr/bin/env python3
# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Local Sprites-gateway shim. Fixture data only — no provider keys.

Speaks the same URL shapes as https://api.sprites.dev so the agent code is
identical in mock and live modes:

    GET  /v1/gateway/list
    *    /v1/gateway/{provider}/{connection_id}/{path}

The store directory holds "GitHub contents" and "S3 objects" filed by the
agents (receipts only). Nothing in this process is a real API token.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

# Make lib importable when launched as a script.
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from timeutil import now_iso  # noqa: E402

CONNECTORS = {
    "tavily": "conn_tavily_mock",
    "firecrawl": "conn_firecrawl_mock",
    "github": "conn_github_mock",
    "s3": "conn_s3_mock",
    "stripe": "conn_stripe_mock",
}

TAVILY_FIXTURE = {
    "query": "What did Fly announce for Sprites?",
    "results": [
        {
            "title": "Sprites: Linux computers for agents",
            "url": "https://fly.io/sprites/",
            "content": (
                "Sprites are persistent, hardware-isolated Linux environments on Fly.io. "
                "The filesystem persists. Idle compute is free. Each Sprite has a unique URL."
            ),
        },
        {
            "title": "Sprites Connectors",
            "url": "https://fly.io/connectors/",
            "content": (
                "Connectors let a Sprite call GitHub, Tavily, Firecrawl, Stripe, S3, or a "
                "custom HTTP API through the Fly gateway. The raw token stays in the control plane."
            ),
        },
        {
            "title": "Hacksgiving 2026",
            "url": "https://fly.io/hacksgiving/",
            "content": (
                "Hacksgiving 2026 runs 23–29 November 2026. Build a personal agent on a "
                "Sprite that uses at least one Sprites connector."
            ),
        },
    ],
}

FIRECRAWL_FIXTURE = {
    "success": True,
    "data": [
        {
            "url": "https://fly.io/docs/sprites/",
            "title": "Sprites Overview",
            "description": "Persistent, hardware-isolated Linux VMs, billed by the second and free when idle.",
        }
    ],
}

GITHUB_RELEASES = [
    {
        "id": 20261124,
        "tag_name": "v0.1.0-public-fixture",
        "name": "Public fixture release",
        "draft": False,
        "prerelease": False,
        "published_at": "2026-11-24T00:00:00Z",
        "html_url": "https://github.com/example/public-repo/releases/tag/v0.1.0-public-fixture",
        "body": "A public GitHub release used only as a hashable event fixture. No personal data.",
    }
]

STRIPE_EVENTS = {
    "object": "list",
    "data": [
        {
            "id": "evt_mock_hs26_1",
            "object": "event",
            "type": "charge.succeeded",
            "created": 1732406400,
            "livemode": False,
            "data": {
                "object": {
                    "id": "ch_mock_hs26_1",
                    "object": "charge",
                    "amount": 2500,
                    "currency": "usd",
                    "description": "Fixture event for the no-keys receipt clerk demo",
                    "status": "succeeded",
                }
            },
        }
    ],
}

GITHUB_STATUS = {
    "sha": "1de08f4cbf95d11012b138b8519513c9f1e5231f",
    "state": "success",
    "total_count": 1,
    "statuses": [
        {
            "state": "success",
            "context": "fixture / public-status",
            "description": "Public status check fixture. No personal data.",
        }
    ],
}


class MockGateway(BaseHTTPRequestHandler):
    store: Path
    server_version = "MockSpritesGateway/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[mock-gateway] " + (fmt % args) + "\n")

    def _send(self, status: int, payload, content_type: str = "application/json") -> None:
        if isinstance(payload, (dict, list)):
            body = json.dumps(payload, indent=2).encode("utf-8")
            content_type = "application/json"
        elif isinstance(payload, bytes):
            body = payload
        else:
            body = str(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}, raw
        try:
            return json.loads(raw.decode("utf-8")), raw
        except json.JSONDecodeError:
            return None, raw

    def _forbidden_if_token_header(self) -> bool:
        for name in self.headers:
            lower = name.lower()
            if lower in {
                "authorization",
                "x-api-key",
                "api-key",
                "x-auth-token",
            }:
                self._send(
                    400,
                    {
                        "error": "this gateway must not be sent a raw token header",
                        "header": name,
                    },
                )
                return True
        return False

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch("PUT")

    def do_HEAD(self) -> None:  # noqa: N802
        if self.path in ("/health", "/"):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._dispatch("GET")

    def _dispatch(self, method: str) -> None:
        if self._forbidden_if_token_header():
            return
        path = unquote(self.path.split("?", 1)[0])
        if path in ("/health", "/"):
            self._send(200, {"ok": True, "service": "mock-sprites-gateway", "when": now_iso()})
            return
        if path == "/v1/gateway/list":
            self._send(200, self._list_payload())
            return
        prefix = "/v1/gateway/"
        if not path.startswith(prefix):
            self._send(404, {"error": "not a gateway path", "path": path})
            return
        rest = path[len(prefix) :].strip("/")
        parts = rest.split("/", 2)
        if len(parts) < 2:
            self._send(400, {"error": "expected /v1/gateway/{provider}/{id}/..."})
            return
        provider, conn_id = parts[0], parts[1]
        sub = parts[2] if len(parts) > 2 else ""
        expected = CONNECTORS.get(provider)
        if expected is None:
            self._send(404, {"error": f"unknown provider {provider}"})
            return
        if conn_id != expected:
            self._send(403, {"error": "unknown connector id", "provider": provider})
            return
        try:
            self._route(method, provider, sub)
        except Exception as exc:  # pragma: no cover - surfaced to the client
            self._send(500, {"error": type(exc).__name__, "detail": str(exc)})

    def _list_payload(self) -> dict:
        host = self.headers.get("Host", "127.0.0.1")
        scheme = "http"
        items = []
        for provider, cid in CONNECTORS.items():
            base = f"{scheme}://{host}/v1/gateway/{provider}/{cid}"
            items.append(
                {
                    "provider": provider,
                    "id": cid,
                    "gateway_base_url": base,
                    "usage_snippet": f"curl {base}/",
                    "scopes": "mock-fixtures-only",
                }
            )
        return {
            "connectors": items,
            "available": [],
            "mode": "mock",
            "note": "Fixture gateway. No provider tokens are stored here.",
        }

    def _route(self, method: str, provider: str, sub: str) -> None:
        if provider == "tavily" and method == "POST" and sub in {"search", "search/"}:
            body, _ = self._read_json()
            query = (body or {}).get("query", TAVILY_FIXTURE["query"])
            payload = dict(TAVILY_FIXTURE)
            payload["query"] = query
            self._send(200, payload)
            return
        if provider == "firecrawl" and method == "POST" and sub in {
            "v1/search",
            "search",
        }:
            self._send(200, FIRECRAWL_FIXTURE)
            return
        if provider == "github":
            self._github(method, sub)
            return
        if provider == "s3":
            self._s3(method, sub)
            return
        if provider == "stripe" and method == "GET" and sub in {"v1/events", "events"}:
            self._send(200, STRIPE_EVENTS)
            return
        self._send(404, {"error": f"no mock route for {provider} {method} {sub}"})

    def _github(self, method: str, sub: str) -> None:
        # releases
        if method == "GET" and "/releases/latest" in sub:
            self._send(200, GITHUB_RELEASES[0])
            return
        if method == "GET" and (sub.endswith("/releases") or sub.endswith("/releases/")):
            self._send(200, GITHUB_RELEASES)
            return
        if method == "GET" and "/commits/" in sub and sub.endswith("/status"):
            self._send(200, GITHUB_STATUS)
            return
        if "/contents/" in sub:
            rel = sub.split("/contents/", 1)[1]
            dest = self.store / "github" / rel
            if method == "GET":
                if not dest.is_file():
                    self._send(404, {"message": "Not Found"})
                    return
                data = dest.read_bytes()
                self._send(
                    200,
                    {
                        "path": rel,
                        "sha": "mock",
                        "encoding": "base64",
                        "content": base64.b64encode(data).decode("ascii"),
                    },
                )
                return
            if method == "PUT":
                body, _ = self._read_json()
                content_b64 = (body or {}).get("content", "")
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(base64.b64decode(content_b64))
                self._send(
                    201,
                    {
                        "content": {"path": rel, "sha": "mock"},
                        "commit": {"message": (body or {}).get("message", "")},
                    },
                )
                return
        self._send(404, {"error": f"no github mock for {method} {sub}"})

    def _s3(self, method: str, sub: str) -> None:
        dest = self.store / "s3" / sub
        if method == "PUT":
            length = int(self.headers.get("Content-Length", "0") or "0")
            data = self.rfile.read(length) if length else b""
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            self._send(200, {"ok": True, "key": sub, "bytes": len(data)})
            return
        if method == "GET":
            if not dest.is_file():
                self._send(404, {"error": "not found", "key": sub})
                return
            self._send(200, dest.read_bytes(), content_type="application/octet-stream")
            return
        self._send(404, {"error": f"no s3 mock for {method} {sub}"})


def main() -> int:
    parser = argparse.ArgumentParser(description="Mock Sprites connector gateway")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18011)
    parser.add_argument(
        "--store",
        default=str(ROOT / "var" / "mock-store"),
        help="directory for mocked GitHub/S3 receipts",
    )
    args = parser.parse_args()
    store = Path(args.store).resolve()
    store.mkdir(parents=True, exist_ok=True)
    MockGateway.store = store
    httpd = ThreadingHTTPServer((args.host, args.port), MockGateway)
    print(f"mock-gateway listening on http://{args.host}:{args.port}", flush=True)
    print(f"mock-gateway store {store}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("mock-gateway stopping", flush=True)
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
