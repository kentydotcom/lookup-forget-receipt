# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""HTTP API + demo UI for the Forgetful research sprite."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT))

from agent.core import AGENT_NAME, PUBLIC_QUESTION, ask, env_report, forget, notes_state  # noqa: E402
from gateway import GatewayClient  # noqa: E402
from httpserve import make_handler, serve  # noqa: E402


def _json(body: bytes) -> dict:
    if not body:
        return {}
    return json.loads(body.decode("utf-8"))


def run(host: str, port: int) -> None:
    def health(_r, _b):
        return 200, {"ok": True, "agent": AGENT_NAME}

    def env(_r, _b):
        return 200, env_report()

    def get_notes(_r, _b):
        return 200, notes_state()

    def post_ask(_r, body):
        data = _json(body)
        question = (data.get("question") or PUBLIC_QUESTION).strip()
        return 200, ask(question)

    def post_forget(_r, _b):
        return 200, forget()

    def get_gateway(_r, _b):
        return 200, GatewayClient().describe()

    handler = make_handler(
        routes={
            ("GET", "/health"): health,
            ("GET", "/env"): env,
            ("GET", "/notes"): get_notes,
            ("GET", "/gateway"): get_gateway,
            ("POST", "/ask"): post_ask,
            ("POST", "/forget"): post_forget,
        },
        static_dir=ROOT / "docs" / "diagrams",
        static_prefix="/diagrams/",
        index_html=ROOT / "static" / "index.html",
    )
    httpd = serve(host, port, handler)
    print(f"{AGENT_NAME} listening on http://{host}:{port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("stopping", flush=True)
    finally:
        httpd.server_close()
