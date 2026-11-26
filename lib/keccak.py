# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Keccak-256 (original Keccak / Ethereum, not NIST SHA3-256)."""

from __future__ import annotations

_RC = (
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
)

# Rotation offsets indexed as ROT[x][y] for lane (x, y).
_ROT = (
    (0, 36, 3, 41, 18),
    (1, 44, 10, 45, 2),
    (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56),
    (27, 20, 39, 8, 14),
)

_MASK = 0xFFFFFFFFFFFFFFFF


def _rotl64(x: int, n: int) -> int:
    n %= 64
    if n == 0:
        return x & _MASK
    return ((x << n) | (x >> (64 - n))) & _MASK


def _keccak_f(st: list[int]) -> None:
    for rnd in range(24):
        c = [st[x] ^ st[x + 5] ^ st[x + 10] ^ st[x + 15] ^ st[x + 20] for x in range(5)]
        d = [c[(x + 4) % 5] ^ _rotl64(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                st[x + 5 * y] ^= d[x]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl64(st[x + 5 * y], _ROT[x][y])
        for i in range(25):
            st[i] = b[i]
        for x in range(5):
            for y in range(5):
                st[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                st[x + 5 * y] &= _MASK
        st[0] ^= _RC[rnd]


def keccak256(data: bytes) -> bytes:
    """Return the 32-byte Keccak-256 digest of *data*."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("keccak256 expects bytes")
    data = bytes(data)
    rate = 136  # 1088-bit rate for 256-bit Keccak
    st = [0] * 25
    offset = 0
    n = len(data)
    while offset + rate <= n:
        block = data[offset : offset + rate]
        for i in range(rate // 8):
            st[i] ^= int.from_bytes(block[i * 8 : (i + 1) * 8], "little")
        _keccak_f(st)
        offset += rate
    leftover = bytearray(data[offset:])
    leftover.append(0x01)
    if len(leftover) >= rate:
        # domain byte filled the block; process it, then a padded terminator block
        block = leftover[:rate]
        # if exactly rate after append, last byte must still get 0x80 — handled below only if < rate
        # When leftover was already rate-1 bytes, append(0x01) makes len == rate.
        # The 0x80 terminator must be OR'd into the last byte of this block if it is the
        # final block. For the rate-1 case, 0x01 and 0x80 share that last byte.
        if len(leftover) == rate:
            leftover[-1] |= 0x80
            for i in range(rate // 8):
                st[i] ^= int.from_bytes(leftover[i * 8 : (i + 1) * 8], "little")
            _keccak_f(st)
        else:
            # > rate should not happen (we appended one byte to a remainder < rate)
            raise RuntimeError("keccak padding overflow")
    else:
        leftover.extend(b"\x00" * (rate - len(leftover)))
        leftover[-1] |= 0x80
        for i in range(rate // 8):
            st[i] ^= int.from_bytes(leftover[i * 8 : (i + 1) * 8], "little")
        _keccak_f(st)
    out = bytearray()
    for i in range(4):
        out.extend(st[i].to_bytes(8, "little"))
    return bytes(out)


def keccak256_hex(data: bytes) -> str:
    """Return a 0x-prefixed hex Keccak-256 digest."""
    return "0x" + keccak256(data).hex()
