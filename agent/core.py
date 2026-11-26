# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Forgetful research sprite — public question in, notes on the Sprite, forget on request."""

from __future__ import annotations

from typing import Any

from gateway import GatewayClient, GatewayError
from paths import ensure_parent, on_disk
from pii import assert_public_text, pii_reasons
from receipts import deletion_receipt, file_receipt, inventory, leftover_state_hash, receipt_contains_forbidden, wipe_logical_dir
from secrets_scan import assert_clean_env, forbidden_env_names
from timeutil import now_iso

AGENT_NAME = "Forgetful research sprite"
NOTES = "/notes/brief.md"
SCRATCH = "/notes/scratch.md"
NOTES_DIR = "/notes"
PUBLIC_QUESTION = "What did Fly announce for Sprites?"


def _bullets_from_tavily(payload: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    for item in payload.get("results") or []:
        title = (item.get("title") or "source").strip()
        url = (item.get("url") or "").strip()
        content = (item.get("content") or "").strip()
        bit = f"{title}"
        if url:
            bit += f" — {url}"
        lines.append(bit)
        if content:
            # keep a single short bullet, not a paragraph
            snippet = content.split(".")[0].strip()
            if snippet:
                lines.append(snippet + ".")
    return lines


def _bullets_from_firecrawl(payload: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    for item in payload.get("data") or []:
        title = (item.get("title") or "source").strip()
        url = (item.get("url") or "").strip()
        desc = (item.get("description") or "").strip()
        bit = title + (f" — {url}" if url else "")
        lines.append(bit)
        if desc:
            lines.append(desc)
    return lines


def render_brief(question: str, provider: str, payload: dict[str, Any]) -> str:
    if provider == "tavily":
        facts = _bullets_from_tavily(payload)
    else:
        facts = _bullets_from_firecrawl(payload)
    lines = [
        f"# Research brief",
        "",
        f"- Question: {question}",
        f"- Looked up through the {provider} Sprites connector",
        f"- Written at {now_iso()} (Asia/Hong_Kong)",
        f"- This file lives at {NOTES} on the Sprite only",
        f"- No KYC. No retained PII. Say “Forget this.” to destroy these notes.",
        "",
        "## Findings",
        "",
    ]
    if facts:
        lines.extend(f"- {item}" for item in facts)
    else:
        lines.append("- No results returned.")
    lines.append("")
    return "\n".join(lines)


def lookup(question: str, client: GatewayClient | None = None) -> tuple[str, dict[str, Any]]:
    client = client or GatewayClient()
    try:
        payload = client.call("POST", "tavily", "search", json_body={"query": question})
        return "tavily", payload
    except GatewayError as exc:
        # fall back to Firecrawl if Tavily is not granted
        try:
            payload = client.call(
                "POST", "firecrawl", "v1/search", json_body={"query": question}
            )
            return "firecrawl", payload
        except GatewayError as exc2:
            raise GatewayError(
                status=exc2.status,
                body=f"Tavily failed ({exc}); Firecrawl failed ({exc2})",
                url="",
            ) from exc2


def ask(question: str, client: GatewayClient | None = None) -> dict[str, Any]:
    assert_clean_env()
    question = question.strip()
    if not question:
        raise ValueError("a public question is required")
    assert_public_text(question, what="question")
    provider, payload = lookup(question, client)
    brief = render_brief(question, provider, payload)
    assert_public_text(brief, what="brief")
    path = ensure_parent(NOTES)
    path.write_text(brief, encoding="utf-8")
    scratch = ensure_parent(SCRATCH)
    scratch.write_text(
        f"- scratch pointer only\n- brief: {NOTES}\n- provider: {provider}\n",
        encoding="utf-8",
    )
    return {
        "ok": True,
        "question": question,
        "provider": provider,
        "brief_path": NOTES,
        "scratch_path": SCRATCH,
        "brief": brief,
        "env_secrets": forbidden_env_names(),
    }


def notes_state() -> dict[str, Any]:
    items = []
    for logical in inventory(NOTES_DIR):
        text = on_disk(logical).read_text(encoding="utf-8")
        items.append(
            {
                "path": logical,
                "bytes": len(text.encode("utf-8")),
                "pii_reasons": pii_reasons(text),
            }
        )
    return {
        "notes_dir": NOTES_DIR,
        "files": items,
        "empty": not items,
        "leftover_hash": leftover_state_hash([NOTES_DIR]),
    }


def forget(client: GatewayClient | None = None) -> dict[str, Any]:
    assert_clean_env()
    client = client or GatewayClient()
    present = inventory(NOTES_DIR)
    # Capture fragments so we can prove the receipt does not contain the notes.
    fragments = []
    for logical in present:
        body = on_disk(logical).read_text(encoding="utf-8")
        # a distinctive mid-length line from the brief, if present
        for line in body.splitlines():
            if line.startswith("- Question:") or line.startswith("- Looked up"):
                fragments.append(line)
                break
    removed = wipe_logical_dir(NOTES_DIR)
    receipt = deletion_receipt(
        agent=AGENT_NAME,
        present=present,
        removed=removed,
        leftover_dirs=[NOTES_DIR],
        claim="Notes destroyed on request. Receipt only; the notes themselves were not filed.",
    )
    leaks = receipt_contains_forbidden(receipt, fragments)
    if leaks:
        raise RuntimeError("deletion receipt would have included note text; refusing to file it")
    stored = file_receipt(client, receipt, stem=f"deletion/forgetful-{receipt['timestamp'].replace(':', '')}")
    state = notes_state()
    return {
        "ok": True,
        "present": present,
        "removed": removed,
        "receipt": receipt,
        "stored": {"backend": stored["backend"], "store_response": stored["store_response"]},
        "notes": state,
        "env_secrets": forbidden_env_names(),
    }


def env_report() -> dict[str, Any]:
    names = forbidden_env_names()
    return {
        "ok": not names,
        "secret_names_present": names,
        "note": "Values are never printed. An empty list is the passing demo.",
    }
