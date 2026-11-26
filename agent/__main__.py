# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""CLI: python3 -m agent <ask|forget|notes|env|serve>"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# lib/ is on PYTHONPATH when launched from the project root or via e2e.
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT))

from agent.core import AGENT_NAME, PUBLIC_QUESTION, ask, env_report, forget, notes_state  # noqa: E402


def _print(obj) -> None:
    print(json.dumps(obj, indent=2))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=AGENT_NAME)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_ask = sub.add_parser("ask", help="Look up a public question and write /notes/brief.md")
    p_ask.add_argument("question", nargs="?", default=PUBLIC_QUESTION)

    sub.add_parser("notes", help="Show what is on the Sprite under /notes")
    sub.add_parser("forget", help="Destroy notes and file a deletion receipt")
    sub.add_parser("env", help="Show that the environment holds no provider secret")

    p_serve = sub.add_parser("serve", help="Serve the demo UI and JSON API")
    p_serve.add_argument("--host", default="127.0.0.1")
    p_serve.add_argument("--port", type=int, default=18021)

    args = parser.parse_args(argv)
    if args.cmd == "ask":
        _print(ask(args.question))
        return 0
    if args.cmd == "notes":
        _print(notes_state())
        return 0
    if args.cmd == "forget":
        _print(forget())
        return 0
    if args.cmd == "env":
        report = env_report()
        _print(report)
        return 0 if report["ok"] else 2
    if args.cmd == "serve":
        from agent.server import run

        run(args.host, args.port)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
