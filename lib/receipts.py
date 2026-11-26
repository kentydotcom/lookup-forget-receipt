# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Build checkable receipts. Store the receipt only — never the notes or payload."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

from keccak import keccak256_hex
from paths import logical, on_disk, sprite_root
from timeutil import now_iso


def leftover_state_hash(logical_dirs: Iterable[str]) -> str:
    """Hash the leftover files under each logical directory (empty-dir → EMPTY)."""
    parts: list[bytes] = []
    for logical_dir in logical_dirs:
        root = on_disk(logical_dir)
        label = logical(logical_dir).encode("utf-8")
        if not root.exists():
            parts.append(label + b"\0ABSENT")
            continue
        files = sorted(p for p in root.rglob("*") if p.is_file())
        if not files:
            parts.append(label + b"\0EMPTY")
            continue
        for path in files:
            rel = path.relative_to(root).as_posix().encode("utf-8")
            parts.append(label + b"/" + rel + b"\0" + path.read_bytes())
    payload = b"\n".join(parts) if parts else b"EMPTY"
    return keccak256_hex(payload)


def inventory(logical_dir: str) -> list[str]:
    root = on_disk(logical_dir)
    if not root.exists():
        return []
    out = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        out.append(logical(logical_dir + "/" + path.relative_to(root).as_posix()).replace("//", "/"))
    return out


def wipe_logical_dir(logical_dir: str) -> list[str]:
    """Delete files under a logical directory. Returns the paths that were removed."""
    removed = inventory(logical_dir)
    root = on_disk(logical_dir)
    if root.exists():
        for path in sorted(root.rglob("*"), reverse=True):
            if path.is_file() or path.is_symlink():
                path.unlink()
            elif path.is_dir():
                try:
                    path.rmdir()
                except OSError:
                    pass
        # keep the directory itself (empty), so leftover hash is EMPTY not ABSENT
        root.mkdir(parents=True, exist_ok=True)
    return removed


def deletion_receipt(
    *,
    agent: str,
    present: list[str],
    removed: list[str],
    leftover_dirs: Iterable[str],
    claim: str,
) -> dict[str, Any]:
    receipt = {
        "type": "deletion_receipt",
        "agent": agent,
        "present": present,
        "removed": removed,
        "leftover_hash": leftover_state_hash(leftover_dirs),
        "timestamp": now_iso(),
        "timezone": "Asia/Hong_Kong",
        "claim": claim,
        "notes": "Receipt only. The destroyed notes or job files are not stored here.",
    }
    return receipt


def event_receipt(*, agent: str, payload: bytes, claim: str) -> dict[str, Any]:
    return {
        "type": "event_receipt",
        "agent": agent,
        "payload_hash": keccak256_hex(payload),
        "timestamp": now_iso(),
        "timezone": "Asia/Hong_Kong",
        "claim": claim,
        "notes": "Receipt only. The raw event payload is not stored here.",
    }


def canonical_bytes(obj: dict[str, Any]) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def store_via_github(client, path: str, receipt: dict[str, Any], message: str) -> dict[str, Any]:
    """File a receipt through the GitHub connector (contents API)."""
    import base64
    import os

    owner = os.environ.get("RECEIPT_GITHUB_OWNER", "demo-org")
    repo = os.environ.get("RECEIPT_GITHUB_REPO", "receipts")
    body = {
        "message": message,
        "content": base64.b64encode(
            json.dumps(receipt, indent=2).encode("utf-8")
        ).decode("ascii"),
    }
    return client.call(
        "PUT",
        "github",
        f"repos/{owner}/{repo}/contents/{path.lstrip('/')}",
        json_body=body,
    )


def store_via_s3(client, key: str, receipt: dict[str, Any]) -> dict[str, Any]:
    import os

    bucket = os.environ.get("RECEIPT_S3_BUCKET", "receipts")
    return client.call(
        "PUT",
        "s3",
        f"{bucket}/{key.lstrip('/')}",
        raw_body=json.dumps(receipt, indent=2).encode("utf-8"),
        content_type="application/json",
    )


def file_receipt(client, receipt: dict[str, Any], stem: str) -> dict[str, Any]:
    """Store only the receipt, via GitHub (default) or S3 (RECEIPT_STORE=s3)."""
    import os

    backend = os.environ.get("RECEIPT_STORE", "github").strip().lower()
    name = stem if stem.endswith(".json") else stem + ".json"
    if backend == "s3":
        stored = store_via_s3(client, name, receipt)
    else:
        stored = store_via_github(
            client, name, receipt, message=f"file receipt {name}"
        )
    return {"backend": backend, "store_response": stored, "receipt": receipt}


def receipt_contains_forbidden(receipt: dict[str, Any], fragments: Iterable[str]) -> list[str]:
    blob = json.dumps(receipt)
    hits = []
    for frag in fragments:
        if frag and frag in blob:
            hits.append(frag)
    return hits
