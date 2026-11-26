#!/usr/bin/env bash
# Tour driver for Forgetful research sprite.
#
# One script covers the project. Each stage is a separate process with its own
# pass/fail, timing, and log. Stages seed their own notes when they need them,
# so --stage N passes on its own. Teardown is last and keeps logs/.
#
# Stages:
#   1  toolchain    Python, Keccak-256 vectors, PII and secret scans, no token headers
#   2  env-check    environment holds no provider secret
#   3  reject-pii   a personal-data question is refused; no notes written
#   4  lookup       Tavily writes /notes/brief.md; Firecrawl is the fallback
#   5  notes        brief stays on the Sprite, no PII, not archived off-box
#   6  forget       "Forget this." wipes /notes
#   7  receipt      deletion receipt via GitHub, then the same via S3 — not the notes
#   8  teardown     last step: stop the mock gateway, wipe work dirs, keep logs
#
# Copyright (c) 2026 Kent G Lau, PhD. No KYC. No retained PII.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_NAME="Forgetful research sprite"
GW_PORT="${GATEWAY_PORT:-18111}"
# shellcheck source=e2e-common.sh
source "${ROOT}/scripts/e2e-common.sh"

PUBLIC_Q="What did Fly announce for Sprites?"

ask_public() {
  cli ask "$PUBLIC_Q" | tee "${ROOT}/var/last-ask.json"
}

notes_have_files() {
  [[ -f "${SPRITE_ROOT}/notes/brief.md" && -f "${SPRITE_ROOT}/notes/scratch.md" ]]
}

github_receipt_ready() {
  python3 - <<'PY'
import json, sys
from pathlib import Path
path = Path("var/last-forget.json")
if not path.is_file():
    sys.exit(1)
try:
    data = json.loads(path.read_text())
except json.JSONDecodeError:
    sys.exit(1)
receipt = data.get("receipt") or {}
if receipt.get("type") != "deletion_receipt":
    sys.exit(1)
if "/notes/brief.md" not in (receipt.get("removed") or []):
    sys.exit(1)
store = Path("var/mock-store/github")
files = list(store.rglob("*.json")) if store.exists() else []
sys.exit(0 if files else 1)
PY
}

assert_brief_provider() {
  local provider="$1"
  python3 - "$provider" <<'CHECK'
import os, sys
from pathlib import Path
provider = sys.argv[1]
out = __import__("json").loads(Path("var/last-ask.json").read_text())
assert out["ok"], out
assert out["provider"] == provider, out.get("provider")
brief = Path(os.environ["SPRITE_ROOT"]) / "notes" / "brief.md"
assert brief.is_file(), "missing /notes/brief.md"
text = brief.read_text()
assert "What did Fly announce for Sprites?" in text
assert f"Looked up through the {provider}" in text
if provider == "tavily":
    # The brief keeps the first sentence of each hit, not the whole fixture.
    assert "https://fly.io/sprites/" in text
    assert "hardware-isolated Linux environments" in text
if provider == "firecrawl":
    assert "Sprites Overview" in text
print(f"{provider} brief ok:", brief, "bytes", brief.stat().st_size)
CHECK
}

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
  mkdir -p "$SPRITE_ROOT" "${ROOT}/var"
  local saved="${CONNECTOR_TAVILY_ID}"

  echo "lookup via the Tavily connector"
  rm -rf "${SPRITE_ROOT}/notes"
  export CONNECTOR_TAVILY_ID="$saved"
  ask_public
  assert_brief_provider tavily

  echo "Firecrawl fallback when the Tavily connector is not granted"
  rm -rf "${SPRITE_ROOT}/notes"
  export CONNECTOR_TAVILY_ID="conn_tavily_not_granted"
  ask_public
  assert_brief_provider firecrawl

  echo "restore Tavily and leave that brief on the Sprite"
  export CONNECTOR_TAVILY_ID="$saved"
  rm -rf "${SPRITE_ROOT}/notes"
  ask_public
  assert_brief_provider tavily
}

stage_notes() {
  if ! notes_have_files; then
    echo "no notes yet; seeding a public brief in this stage"
    ensure_gateway
    mkdir -p "$SPRITE_ROOT" "${ROOT}/var"
    ask_public
  fi
  python3 - <<'CHECK'
import os, sys
from pathlib import Path
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
assert "/notes/brief.md" in scratch.read_text()
store = Path("var/mock-store")
blob = ""
if store.exists():
    for p in store.rglob("*"):
        if p.is_file():
            blob += p.read_text(errors="replace")
assert "What did Fly announce for Sprites?" not in blob
assert "hardware-isolated Linux environments" not in blob
print("notes on the Sprite only; no PII; not archived off-box")
CHECK
}

stage_forget() {
  ensure_gateway
  mkdir -p "$SPRITE_ROOT" "${ROOT}/var"
  if ! notes_have_files; then
    echo "no notes yet; seeding a public brief so forget has something to remove"
    ask_public
  fi
  cli forget | tee "${ROOT}/var/last-forget.json"
  python3 - <<'CHECK'
import json, os, sys
from pathlib import Path
sys.path.insert(0, "lib")
from receipts import leftover_state_hash
out = json.loads(Path("var/last-forget.json").read_text())
assert out["ok"]
assert out["removed"]
assert "/notes/brief.md" in out["removed"]
assert "/notes/scratch.md" in out["removed"]
root = Path(os.environ["SPRITE_ROOT"]) / "notes"
files = [p for p in root.rglob("*") if p.is_file()] if root.exists() else []
assert not files, files
assert out["receipt"]["leftover_hash"] == leftover_state_hash(["/notes"])
print("notes directory empty after forget")
print("removed", out["removed"])
print("leftover_hash", out["receipt"]["leftover_hash"])
CHECK
}

stage_receipt() {
  ensure_gateway
  mkdir -p "$SPRITE_ROOT" "${ROOT}/var"
  if ! github_receipt_ready; then
    echo "no GitHub receipt yet; asking, then forgetting"
    if ! notes_have_files; then
      ask_public
    fi
    RECEIPT_STORE=github cli forget | tee "${ROOT}/var/last-forget.json"
  fi
  python3 - <<'CHECK'
import json, sys
from pathlib import Path
sys.path.insert(0, "lib")
from keccak import keccak256_hex
# Empty /notes is labeled "/notes\\0EMPTY" and hashed. This does not depend on
# whatever happens to be on disk if this stage is reusing an earlier receipt.
empty_notes = keccak256_hex(b"/notes\0EMPTY")
out = json.loads(Path("var/last-forget.json").read_text())
receipt = out["receipt"]
for key in ("removed", "leftover_hash", "timestamp", "claim"):
    assert receipt.get(key), f"missing {key}"
assert receipt["type"] == "deletion_receipt"
assert receipt["timezone"] == "Asia/Hong_Kong"
assert "/notes/brief.md" in receipt["removed"]
assert "/notes/scratch.md" in receipt["removed"]
assert receipt["leftover_hash"] == empty_notes, receipt["leftover_hash"]
blob = json.dumps(receipt)
for forbidden in (
    "Looked up through the tavily",
    "hardware-isolated Linux environments",
    "Idle compute is free",
    "What did Fly announce for Sprites?",
    "scratch pointer only",
):
    assert forbidden not in blob, forbidden
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
        assert "hardware-isolated Linux environments" not in body
        assert "What did Fly announce for Sprites?" not in body
        print("filed", p)
print("GitHub deletion receipt ok; notes not stored")
assert found
CHECK

  echo "file the same kind of receipt through the S3 connector"
  ask_public
  RECEIPT_STORE=s3 cli forget | tee "${ROOT}/var/last-forget-s3.json"
  python3 - <<'CHECK'
import json, sys
from pathlib import Path
sys.path.insert(0, "lib")
from receipts import leftover_state_hash
out = json.loads(Path("var/last-forget-s3.json").read_text())
assert out["ok"]
assert out["stored"]["backend"] == "s3"
receipt = out["receipt"]
assert receipt["type"] == "deletion_receipt"
assert "/notes/brief.md" in receipt["removed"]
assert receipt["leftover_hash"] == leftover_state_hash(["/notes"])
blob = json.dumps(receipt)
assert "Idle compute is free" not in blob
assert "hardware-isolated Linux environments" not in blob
assert "What did Fly announce for Sprites?" not in blob
assert "Looked up through the" not in blob
store = Path("var/mock-store/s3")
files = list(store.rglob("*.json")) if store.exists() else []
assert files, "no receipt filed in the mock S3 store"
found = False
for p in files:
    data = json.loads(p.read_text())
    if data.get("type") == "deletion_receipt":
        found = True
        body = p.read_text()
        assert "Idle compute is free" not in body
        assert "hardware-isolated Linux environments" not in body
        assert "What did Fly announce for Sprites?" not in body
        print("s3 filed", p)
assert found
print("S3 deletion receipt ok; notes not stored")
CHECK
}

run_all() {
  init_run_dirs
  reset_results
  echo "${AGENT_NAME}  repo ${ROOT}"
  echo "logs                ${LOG_DIR}"
  echo "SPRITE_ROOT         ${SPRITE_ROOT}"
  echo "GATEWAY_BASE        ${GATEWAY_BASE}"
  echo
  run_stage toolchain "Python, Keccak-256, PII and secret scans" stage_toolchain
  run_stage env "environment holds no provider secret" stage_env
  run_stage pii "refuse a personal-data question" stage_reject_pii
  run_stage lookup "Tavily lookup, Firecrawl fallback" stage_lookup
  run_stage notes "brief stays on the Sprite only" stage_notes
  run_stage forget "wipe /notes on request" stage_forget
  run_stage receipt "deletion receipt via GitHub, then S3" stage_receipt
  run_stage teardown "stop mock gateway; keep logs" stage_teardown
  print_summary
}

run_one() {
  case "$1" in
    1|2|3|4|5|6|7|8) ;;
    *) echo "unknown stage: $1" >&2; return 2 ;;
  esac
  init_run_dirs
  reset_results
  case "$1" in
    1) run_stage toolchain "Python, Keccak-256, PII and secret scans" stage_toolchain ;;
    2) run_stage env "environment holds no provider secret" stage_env ;;
    3) run_stage pii "refuse a personal-data question" stage_reject_pii ;;
    4) run_stage lookup "Tavily lookup, Firecrawl fallback" stage_lookup ;;
    5) run_stage notes "brief stays on the Sprite only" stage_notes ;;
    6) run_stage forget "wipe /notes on request" stage_forget ;;
    7) run_stage receipt "deletion receipt via GitHub, then S3" stage_receipt ;;
    8) run_stage teardown "stop mock gateway; keep logs" stage_teardown ;;
  esac
  print_summary
}

menu() {
  while true; do
    cat <<'EOF'

Forgetful research sprite
Each stage runs alone, in its own process. Teardown is last and keeps logs.
  1  toolchain check
  2  env check (no secrets)
  3  reject a PII question
  4  look up a public question (Tavily, then Firecrawl fallback)
  5  confirm notes stay on the Sprite
  6  forget the notes
  7  inspect the deletion receipt (GitHub, then S3)
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
