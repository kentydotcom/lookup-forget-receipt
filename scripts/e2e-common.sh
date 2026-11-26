# Shared e2e helpers. Sourced by each agent's scripts/e2e.sh.
# Copyright (c) 2026 Kent G Lau, PhD. No KYC. No retained PII.

cd "$ROOT"

export PYTHONPATH="${ROOT}/lib:${ROOT}${PYTHONPATH:+:${PYTHONPATH}}"
export SPRITE_ROOT="${SPRITE_ROOT:-${ROOT}/var/sprite-root}"
export HOLDER_DIR="${HOLDER_DIR:-${ROOT}/var/holder}"
export GATEWAY_BASE="${GATEWAY_BASE:-http://127.0.0.1:${GW_PORT}}"
export CONNECTOR_TAVILY_ID="${CONNECTOR_TAVILY_ID:-conn_tavily_mock}"
export CONNECTOR_FIRECRAWL_ID="${CONNECTOR_FIRECRAWL_ID:-conn_firecrawl_mock}"
export CONNECTOR_GITHUB_ID="${CONNECTOR_GITHUB_ID:-conn_github_mock}"
export CONNECTOR_S3_ID="${CONNECTOR_S3_ID:-conn_s3_mock}"
export CONNECTOR_STRIPE_ID="${CONNECTOR_STRIPE_ID:-conn_stripe_mock}"
export RECEIPT_STORE="${RECEIPT_STORE:-github}"
export RECEIPT_GITHUB_OWNER="${RECEIPT_GITHUB_OWNER:-demo-org}"
export RECEIPT_GITHUB_REPO="${RECEIPT_GITHUB_REPO:-receipts}"
export RECEIPT_S3_BUCKET="${RECEIPT_S3_BUCKET:-receipts}"

GW_PIDFILE="${ROOT}/var/gateway.pid"
GW_STORE="${ROOT}/var/mock-store"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${ROOT}/logs/e2e-${STAMP}"
mkdir -p "$LOG_DIR" "$SPRITE_ROOT" "$HOLDER_DIR" "$GW_STORE" "${ROOT}/var"

FAILURES=0
declare -a SUMMARY=()

now_s() {
  python3 -c 'import time; print(f"{time.time():.6f}")'
}

run_stage() {
  local id="$1"
  local title="$2"
  local fn="$3"
  local log="${LOG_DIR}/${id}.log"
  local start end elapsed code
  start="$(now_s)"
  (
    set -euo pipefail
    "$fn"
  ) >"$log" 2>&1
  code=$?
  end="$(now_s)"
  elapsed="$(python3 -c "print(f'{${end} - ${start}:.2f}')")"
  local result="PASS"
  if [[ "$code" -ne 0 ]]; then
    result="FAIL"
    FAILURES=$((FAILURES + 1))
  fi
  SUMMARY+=("$(printf '%-10s  %-8s  %7ss  %s' "$id" "$result" "$elapsed" "$title")")
  if [[ "$result" == "PASS" ]]; then
    printf 'PASS  %-10s  %7ss  %s\n' "$id" "$elapsed" "$title"
  else
    printf 'FAIL  %-10s  %7ss  %s\n' "$id" "$elapsed" "$title"
    echo "      log: ${log}"
    echo "      --- tail ---"
    tail -n 25 "$log" | sed 's/^/      /'
    echo "      --- end ---"
  fi
}

_port_in_use() {
  python3 - "$1" <<'PORTCHECK'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.3)
try:
    r = s.connect_ex(("127.0.0.1", port))
finally:
    s.close()
sys.exit(0 if r == 0 else 1)
PORTCHECK
}

_wait_http() {
  local url="$1"
  local i
  for i in $(seq 1 20); do
    if python3 - "$url" <<'WAIT'; then
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=0.5)
except Exception:
    sys.exit(1)
sys.exit(0)
WAIT
      return 0
    fi
    sleep 0.15
  done
  echo "timed out waiting for ${url}"
  return 1
}

ensure_gateway() {
  mkdir -p "$(dirname "$GW_PIDFILE")" "$GW_STORE"
  if _port_in_use "$GW_PORT"; then
    echo "gateway already listening on 127.0.0.1:${GW_PORT}"
    _wait_http "http://127.0.0.1:${GW_PORT}/health"
    return 0
  fi
  python3 "${ROOT}/scripts/mock_gateway.py" --host 127.0.0.1 --port "$GW_PORT" --store "$GW_STORE" &
  echo $! >"$GW_PIDFILE"
  echo "started mock gateway pid $(cat "$GW_PIDFILE") on :${GW_PORT}"
  _wait_http "http://127.0.0.1:${GW_PORT}/health"
}

cli() {
  python3 -m agent "$@"
}

stage_toolchain() {
  command -v python3
  python3 --version
  python3 - <<'TOOLCHAIN'
import sys
sys.path.insert(0, "lib")
from keccak import keccak256
vectors = {
    b"": "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
    b"hello": "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
    b"abc": "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
}
for msg, expect in vectors.items():
    got = keccak256(msg).hex()
    assert got == expect, f"{msg!r}: {got} != {expect}"
    print(f"keccak256({msg!r}) ok")
from pii import pii_reasons
assert "email address" in pii_reasons("write to test@example.com")
assert not pii_reasons("What did Fly announce for Sprites?")
print("pii checks ok")
from secrets_scan import forbidden_env_names
assert "STRIPE_API_KEY" in forbidden_env_names({"STRIPE_API_KEY": "x"})
assert not forbidden_env_names({"SPRITE_ROOT": "/tmp", "GATEWAY_BASE": "http://127.0.0.1"})
print("secrets_scan ok")
TOOLCHAIN
}

stage_env() {
  ensure_gateway
  cli env
  python3 - <<'ENVCHECK'
import os, subprocess, sys
env = os.environ.copy()
env["STRIPE_API_KEY"] = "sk_test_PLACEHOLDER_NOT_A_REAL_KEY"
proc = subprocess.run(
    [sys.executable, "-m", "agent", "env"],
    env=env,
    capture_output=True,
    text=True,
)
print("planted-secret exit", proc.returncode)
print(proc.stdout)
print(proc.stderr)
assert proc.returncode != 0, "agent must refuse a planted provider secret"
secret = "sk_test_PLACEHOLDER_NOT_A_REAL_KEY"
assert secret not in proc.stdout
assert secret not in proc.stderr
print("planted secret was refused and not echoed")
ENVCHECK
}

stage_teardown() {
  echo "teardown: logs for this run stay in ${LOG_DIR} (not deleted)"
  if [[ -f "$GW_PIDFILE" ]]; then
    local pid
    pid="$(tr -d '[:space:]' < "$GW_PIDFILE" || true)"
    echo "found gateway pidfile, pid='${pid}'"
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      if kill -0 "$pid" 2>/dev/null; then
        echo "escalating to SIGKILL on ${pid}"
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.1
      fi
    fi
    rm -f "$GW_PIDFILE"
    echo "removed ${GW_PIDFILE}"
  else
    echo "no gateway pidfile"
  fi
  if _port_in_use "$GW_PORT"; then
    echo "NOTE: 127.0.0.1:${GW_PORT} still in use"
  else
    echo "port ${GW_PORT} is free"
  fi
  rm -rf "${SPRITE_ROOT}" "${ROOT}/var/sprite-root" "${GW_STORE}" "${HOLDER_DIR}"
  mkdir -p "${ROOT}/var"
  echo "cleared sprite root, mock store, and holder dir"
  if [[ ! -d "$LOG_DIR" ]]; then
    echo "FAIL: current log dir ${LOG_DIR} is missing"
    return 1
  fi
  echo "current run logs still in ${LOG_DIR}"
  echo "teardown clean"
}

print_summary() {
  echo
  echo "${AGENT_NAME} summary  (logs in ${LOG_DIR})"
  echo "ID          RESULT      TIME  TITLE"
  local line
  for line in "${SUMMARY[@]}"; do
    echo "$line"
  done
  echo
  if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS  ${#SUMMARY[@]} stages, 0 failed"
    return 0
  fi
  echo "FAIL  ${FAILURES} stage(s) failed"
  return 1
}

reset_results() {
  FAILURES=0
  SUMMARY=()
}

e2e_usage() {
  cat <<EOF
Usage: ./scripts/e2e.sh [--ci | --all | --stage N | --help]

  (no args, terminal)   menu
  (no args, no tty)     run every stage
  --ci, --all           run every stage, ending with teardown
  --stage N             run stage N only (1..8)

Exit 0 only when every requested stage passes.
EOF
}

e2e_dispatch() {
  case "${1:-}" in
    --help|-h) e2e_usage; return 0 ;;
    --ci|--all) run_all; return $? ;;
    --stage)
      if [[ -z "${2:-}" ]]; then
        e2e_usage
        return 2
      fi
      run_one "$2"
      return $?
      ;;
    "")
      if [[ -t 0 ]]; then
        menu
        return $?
      fi
      run_all
      return $?
      ;;
    *)
      e2e_usage
      return 2
      ;;
  esac
}
