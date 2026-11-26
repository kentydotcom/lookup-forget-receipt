# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Map logical Sprite paths (e.g. /notes/brief.md) onto a configurable root."""

from __future__ import annotations

import os
from pathlib import Path


def sprite_root() -> Path:
    raw = os.environ.get("SPRITE_ROOT", "").strip()
    if raw:
        return Path(raw).resolve()
    # On a real Sprite we want /notes and /job at the filesystem root.
    # Local e2e always sets SPRITE_ROOT; default to ./var/sprite-root so we
    # never write into the host's real /.
    return (Path.cwd() / "var" / "sprite-root").resolve()


def logical(path: str) -> str:
    p = path.replace("\\", "/")
    if not p.startswith("/"):
        p = "/" + p
    return p


def on_disk(path: str) -> Path:
    rel = logical(path).lstrip("/")
    return sprite_root() / rel


def ensure_parent(path: str) -> Path:
    dest = on_disk(path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    return dest
