# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Reject inputs that look like personal data. Public questions only."""

from __future__ import annotations

import re

EMAIL = re.compile(r"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b", re.I)
# International / North American phone-shaped numbers with separators.
PHONE = re.compile(r"(?<!\w)(?:\+?\d{1,3}[\s.\-]?)?(?:\(?\d{3}\)?[\s.\-]?)\d{3}[\s.\-]?\d{4}(?!\w)")
SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
# 13–19 digit runs that pass Luhn are treated as card numbers.
CARD_RUN = re.compile(r"\b(?:\d[ \-]?){13,19}\b")
KYC_HINT = re.compile(
    r"\b(passport|driver'?s license|national id|social security|date of birth|"
    r"date-of-birth|home address|residential address|my name is|full legal name|"
    r"kyc document)\b",
    re.I,
)


def _luhn_ok(digits: str) -> bool:
    s = 0
    alt = False
    for ch in digits[::-1]:
        n = ord(ch) - 48
        if alt:
            n *= 2
            if n > 9:
                n -= 9
        s += n
        alt = not alt
    return s % 10 == 0


def pii_reasons(text: str) -> list[str]:
    reasons: list[str] = []
    if EMAIL.search(text):
        reasons.append("email address")
    if PHONE.search(text):
        reasons.append("phone number")
    if SSN.search(text):
        reasons.append("SSN-shaped number")
    for m in CARD_RUN.finditer(text):
        digits = re.sub(r"\D", "", m.group(0))
        if 13 <= len(digits) <= 19 and _luhn_ok(digits):
            reasons.append("card-shaped number")
            break
    if KYC_HINT.search(text):
        reasons.append("KYC / identity phrasing")
    return reasons


def assert_public_text(text: str, *, what: str = "input") -> None:
    reasons = pii_reasons(text)
    if reasons:
        raise ValueError(
            f"{what} looks like personal data ({', '.join(reasons)}). "
            "This agent accepts public questions only and does not retain PII."
        )
