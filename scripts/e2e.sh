#!/usr/bin/env bash
# Tour driver for Forgetful research sprite.
#
# Stages:
#   1  toolchain    Python, Keccak-256 vectors, PII and secret scans
#   2  env-check    environment holds no provider secret
#   3  reject-pii   a personal-data question is refused; no notes written
#   4  lookup       public question via the Tavily connector; write /notes/brief.md
#   5  notes        brief stays on the Sprite, no PII, not archived off-box
#   6  forget       "Forget this." wipes /notes
#   7  receipt      deletion receipt filed via GitHub connector (not the notes)
#   8  teardown     last step: stop the mock gateway, wipe work dirs, keep logs
#
# Copyright (c) 2026 Kent G Lau, PhD. No KYC. No retained PII.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_NAME="Forgetful research sprite"
GW_PORT="${GATEWAY_PORT:-18111}"
# shellcheck source=e2e-common.sh
source "${ROOT}/scripts/e2e-common.sh"

stage_reject_pii() {
  ensure_gateway
  mkdir -p "$SPRITE_ROOT"
  rm -rf "${SPRITE_ROOT}/notes"
  if cli ask "Please email the brief to ada@example.com about Sprites"; then
    echo "PII question was accepted — fail"
    return 1
  fi
  echo "PII question correctly refused"
  python3 - <<'CHECK'
from pathlib import Path
import os
root = Path(os.environ["SPRITE_ROOT"])
notes = root / "notes"
if notes.exists():
    files = list(notes.rglob("*"))
    assert not any(p.is_file() for p in files), f"notes were written after a PII refusal: {files}"
print("no notes written after PII refusal")
CHECK
}

stage_lookup() {
  ensure_gateway
  mkdir -p "$SPRITE_ROOT"
  rm -rf "${SPRITE_ROOT}/notes"
  cli ask "What did Fly announce for Sprites?" | tee "${ROOT}/var/last-ask.json"
  python3 - <<'CHECK'
import json, os
from pathlib import Path
out = json.loads(Path("var/last-ask.json").read_text())
assert out["ok"]
brief = Path(os.environ["SPRITE_ROOT"]) / "notes" / "brief.md"
assert brief.is_file(), "missing /notes/brief.md"
text = brief.read_text()
assert "What did Fly announce for Sprites?" in text
assert "Sprites connector" in text
print("brief written:", brief, "bytes", brief.stat().st_size)
print(text)
CHECK
}

stage_notes() {
  python3 - <<'CHECK'
import os
from pathlib import Path
import sys
sys.path.insert(0, "lib")
from pii import pii_reasons
root = Path(os.environ["SPRITE_ROOT"])
brief = root / "notes" / "brief.md"
scratch = root / "notes" / "scratch.md"
assert brief.is_file()
assert scratch.is_file()
text = brief.read_text()
reasons = pii_reasons(text)
assert not reasons, reasons
store = Path("var/mock-store")
blob = ""
if store.exists():
    for p in store.rglob("*"):
        if p.is_file():
            blob += p.read_text(errors="replace")
assert "What did Fly announce for Sprites?" not in blob
print("notes on the Sprite only; no PII; not archived off-box")
CHECK
}

stage_forget() {
  ensure_gateway
  cli forget | tee "${ROOT}/var/last-forget.json"
  python3 - <<'CHECK'
import json, os
from pathlib import Path
out = json.loads(Path("var/last-forget.json").read_text())
assert out["ok"]
assert out["removed"]
root = Path(os.environ["SPRITE_ROOT"]) / "notes"
files = [p for p in root.rglob("*") if p.is_file()] if root.exists() else []
assert not files, files
print("notes directory empty after forget")
print("removed", out["removed"])
print("leftover_hash", out["receipt"]["leftover_hash"])
CHECK
}

stage_receipt() {
  python3 - <<'CHECK'
import json
from pathlib import Path
out = json.loads(Path("var/last-forget.json").read_text())
receipt = out["receipt"]
for key in ("removed", "leftover_hash", "timestamp", "claim"):
    assert receipt.get(key), f"missing {key}"
assert receipt["type"] == "deletion_receipt"
assert "/notes/brief.md" in receipt["removed"]
blob = json.dumps(receipt)
assert "Looked up through the tavily" not in blob
assert "Idle compute is free" not in blob
store = Path("var/mock-store/github")
files = list(store.rglob("*.json")) if store.exists() else []
assert files, "no receipt filed in the mock GitHub store"
found = False
for p in files:
    data = json.loads(p.read_text())
    if data.get("type") == "deletion_receipt":
        found = True
        body = p.read_text()
        assert "Idle compute is free" not in body
        print("filed", p)
print("deletion receipt ok; notes not stored")
assert found
CHECK
}

run_all() {
  reset_results
  echo "${AGENT_NAME}  repo ${ROOT}"
  echo "logs                ${LOG_DIR}"
  echo "SPRITE_ROOT         ${SPRITE_ROOT}"
  echo "GATEWAY_BASE        ${GATEWAY_BASE}"
  echo
  run_stage toolchain "Python, Keccak-256, PII and secret scans" stage_toolchain
  run_stage env "environment holds no provider secret" stage_env
  run_stage pii "refuse a personal-data question" stage_reject_pii
  run_stage lookup "public question via the Tavily connector" stage_lookup
  run_stage notes "brief stays on the Sprite only" stage_notes
  run_stage forget "wipe /notes on request" stage_forget
  run_stage receipt "file a deletion receipt, not the notes" stage_receipt
  run_stage teardown "stop mock gateway; keep logs" stage_teardown
  print_summary
}

run_one() {
  reset_results
  case "$1" in
    1) run_stage toolchain "Python, Keccak-256, PII and secret scans" stage_toolchain ;;
    2) run_stage env "environment holds no provider secret" stage_env ;;
    3) run_stage pii "refuse a personal-data question" stage_reject_pii ;;
    4) run_stage lookup "public question via the Tavily connector" stage_lookup ;;
    5) run_stage notes "brief stays on the Sprite only" stage_notes ;;
    6) run_stage forget "wipe /notes on request" stage_forget ;;
    7) run_stage receipt "file a deletion receipt, not the notes" stage_receipt ;;
    8) run_stage teardown "stop mock gateway; keep logs" stage_teardown ;;
    *) echo "unknown stage: $1" >&2; return 2 ;;
  esac
  print_summary
}

menu() {
  while true; do
    cat <<'EOF'

Forgetful research sprite
  1  toolchain check
  2  env check (no secrets)
  3  reject a PII question
  4  look up a public question
  5  confirm notes stay on the Sprite
  6  forget the notes
  7  inspect the deletion receipt
  8  teardown (stop gateway, keep logs)
  9  run all
  q  quit
EOF
    printf 'choice> '
    local choice
    if ! read -r choice; then
      echo
      return 0
    fi
    case "$choice" in
      1|2|3|4|5|6|7|8) run_one "$choice" ;;
      9|a|all) run_all ;;
      q|Q) return 0 ;;
      *) echo "enter 1-9 or q" ;;
    esac
  done
}

e2e_dispatch "${1:-}" "${2:-}"
exit $?
