# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Refuse to run if a provider token is present in the process environment.

The whole point of Sprites connectors is that the raw token stays in the Fly
control plane. This scan is the demo's "show the env has no secret" step.
Variable *names* may be reported; values are never printed or logged.
"""

from __future__ import annotations

import os
import re

FORBIDDEN_NAMES = {
    "TAVILY_API_KEY",
    "TAVILY_KEY",
    "TAVILY_APIKEY",
    "FIRECRAWL_API_KEY",
    "FIRECRAWL_KEY",
    "FIRECRAWL_APIKEY",
    "STRIPE_API_KEY",
    "STRIPE_SECRET_KEY",
    "STRIPE_RESTRICTED_KEY",
    "STRIPE_WEBHOOK_SECRET",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITHUB_PAT",
    "GH_PAT",
    "WEBHOOK_SECRET",
    "WEBHOOK_TOKEN",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_SESSION_TOKEN",
    "S3_SECRET_ACCESS_KEY",
    "S3_ACCESS_KEY_ID",
    "OPENROUTER_API_KEY",
}

# Value shapes that must never appear in the Sprite env. We only report the
# *name* of the variable that held a match.
_VALUE_PATTERNS = (
    re.compile(r"^sk_live_[A-Za-z0-9]+"),
    re.compile(r"^sk_test_[A-Za-z0-9]+"),
    re.compile(r"^rk_live_[A-Za-z0-9]+"),
    re.compile(r"^whsec_[A-Za-z0-9]+"),
    re.compile(r"^ghp_[A-Za-z0-9]+"),
    re.compile(r"^gho_[A-Za-z0-9]+"),
    re.compile(r"^github_pat_[A-Za-z0-9_]+"),
    re.compile(r"^tvly-[A-Za-z0-9]+"),
    re.compile(r"^fc-[A-Za-z0-9]+"),
)

# Names we never treat as provider secrets (connectors ids, modes, paths).
_SAFE_PREFIXES = (
    "SPRITE_",
    "GATEWAY_",
    "CONNECTOR_",
    "PYTHON",
    "PATH",
    "HOME",
    "PWD",
    "LANG",
    "LC_",
    "TERM",
    "USER",
    "LOGNAME",
    "SHELL",
    "SHLVL",
    "OLDPWD",
    "XDG_",
    "DISPLAY",
    "DBUS_",
    "SSH_",
    "COLOR",
    "LS_COLORS",
    "EDITOR",
    "VISUAL",
)


def forbidden_env_names(env: dict[str, str] | None = None) -> list[str]:
    env = os.environ if env is None else env
    found: list[str] = []
    for name, value in env.items():
        upper = name.upper()
        if upper in FORBIDDEN_NAMES:
            found.append(name)
            continue
        if any(upper.startswith(p) for p in _SAFE_PREFIXES):
            continue
        if not value:
            continue
        for pat in _VALUE_PATTERNS:
            if pat.search(value.strip()):
                found.append(name)
                break
    return sorted(set(found))


def assert_clean_env(env: dict[str, str] | None = None) -> list[str]:
    found = forbidden_env_names(env)
    if found:
        raise SystemExit(
            "refusing to run: provider secret names present in the environment: "
            + ", ".join(found)
            + " (values not shown). Move tokens into a Sprites connector."
        )
    return found
