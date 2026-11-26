# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Call a Sprites connector through the Fly gateway — never with a raw token.

Live (on a Sprite):
    GATEWAY_BASE=https://api.sprites.dev
    GET  {base}/v1/gateway/list
    ANY  {base}/v1/gateway/{provider}/{connection_id}/{path}

The gateway authenticates the calling Sprite by platform identity. This client
refuses to attach Authorization, API keys, or token query parameters.

Local e2e / demo:
    GATEWAY_BASE=http://127.0.0.1:<port>
    The mock gateway in scripts/mock_gateway.py speaks the same shapes and
    holds only fixtures — no provider keys.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

FORBIDDEN_HEADERS = {
    "authorization",
    "proxy-authorization",
    "x-api-key",
    "x-auth-token",
    "x-access-token",
    "api-key",
    "apikey",
    "stripe-secret",
}

FORBIDDEN_QUERY = {"api_key", "apikey", "access_token", "token", "secret", "key"}


@dataclass
class GatewayError(Exception):
    status: int
    body: str
    url: str

    def __str__(self) -> str:
        return f"gateway {self.status} for {self.url}: {self.body[:300]}"


def gateway_base() -> str:
    return os.environ.get("GATEWAY_BASE", "https://api.sprites.dev").rstrip("/")


def connector_id(provider: str) -> str:
    env_name = f"CONNECTOR_{provider.upper().replace('-', '_')}_ID"
    return os.environ.get(env_name, "").strip()


class GatewayClient:
    def __init__(self, base: str | None = None, timeout: float = 20.0) -> None:
        self.base = (base or gateway_base()).rstrip("/")
        self.timeout = timeout

    def list_connectors(self) -> dict[str, Any]:
        return self._request("GET", "/v1/gateway/list")

    def call(
        self,
        method: str,
        provider: str,
        path: str,
        *,
        conn_id: str | None = None,
        json_body: Any = None,
        raw_body: bytes | None = None,
        content_type: str | None = None,
    ) -> Any:
        cid = conn_id or connector_id(provider)
        if not cid:
            raise GatewayError(
                status=0,
                body=(
                    f"no connector id for {provider}. Set CONNECTOR_{provider.upper()}_ID "
                    "or run against the mock gateway (e2e does this for you)."
                ),
                url="",
            )
        suffix = path.lstrip("/")
        url_path = f"/v1/gateway/{provider}/{cid}/{suffix}"
        return self._request(
            method,
            url_path,
            json_body=json_body,
            raw_body=raw_body,
            content_type=content_type,
        )

    def _request(
        self,
        method: str,
        url_path: str,
        *,
        json_body: Any = None,
        raw_body: bytes | None = None,
        content_type: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> Any:
        if "?" in url_path:
            _, _, query = url_path.partition("?")
            for part in query.split("&"):
                key = part.split("=", 1)[0].lower()
                if key in FORBIDDEN_QUERY:
                    raise RuntimeError(
                        f"refusing to send a token-shaped query parameter '{key}' "
                        "to the gateway"
                    )
        hdrs = {"Accept": "application/json", "User-Agent": "hacksgiving-2026-agent/1.0"}
        if headers:
            for k, v in headers.items():
                if k.lower() in FORBIDDEN_HEADERS:
                    raise RuntimeError(
                        f"refusing to attach header '{k}'; tokens stay in the control plane"
                    )
                hdrs[k] = v
        data = raw_body
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            hdrs["Content-Type"] = "application/json"
        elif data is not None:
            hdrs["Content-Type"] = content_type or "application/octet-stream"
        url = self.base + (url_path if url_path.startswith("/") else "/" + url_path)
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method.upper())
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read()
                ctype = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", "replace")
            raise GatewayError(status=exc.code, body=err, url=url) from exc
        except urllib.error.URLError as exc:
            raise GatewayError(status=0, body=str(exc.reason), url=url) from exc
        if not body:
            return None
        if "json" in ctype or body[:1] in (b"{", b"["):
            return json.loads(body.decode("utf-8"))
        return body

    def describe(self) -> dict[str, Any]:
        info: dict[str, Any] = {"gateway_base": self.base, "mode": "live"}
        if "127.0.0.1" in self.base or "localhost" in self.base:
            info["mode"] = "mock"
        try:
            listed = self.list_connectors()
            info["list"] = listed
        except GatewayError as exc:
            info["list_error"] = str(exc)
        return info
