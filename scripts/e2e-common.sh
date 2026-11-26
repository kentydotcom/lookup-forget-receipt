# Shared e2e helpers. Sourced by scripts/e2e.sh.
# Each stage is launched as its own process (--worker); this file is the harness.
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
export GW_PORT GW_PIDFILE

# Log directory is created on a real run, not for --help.
LOG_DIR=""
E2E_READY=""

FAILURES=0
declare -a SUMMARY=()

init_run_dirs() {
  if [[ -z "${E2E_READY:-}" ]]; then
    if [[ -n "${E2E_LOG_DIR:-}" ]]; then
      LOG_DIR="${E2E_LOG_DIR}"
    else
      local stamp
      stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
      LOG_DIR="${ROOT}/logs/e2e-${stamp}"
    fi
    E2E_READY=1
  fi
  mkdir -p "$LOG_DIR" "$SPRITE_ROOT" "$HOLDER_DIR" "$GW_STORE" "${ROOT}/var"
}

now_s() {
  python3 -c 'import time; print(f"{time.time():.6f}")'
}

run_stage() {
  local id="$1"
  local title="$2"
  local fn="$3"
  local log start end elapsed code
  init_run_dirs
  log="${LOG_DIR}/${id}.log"
  start="$(now_s)"
  # Fresh interpreter. The worker does not share shell state with the runner
  # or with any other stage. stdout/stderr of that process is this stage's log.
  {
    echo "runner pid $$"
    echo "stage ${id}: ${title}"
    E2E_LOG_DIR="$LOG_DIR" bash "${ROOT}/scripts/e2e.sh" --worker "$fn"
  } >"$log" 2>&1
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
assert "phone number" in pii_reasons("call 415-555-0134 about Sprites")
assert "SSN-shaped number" in pii_reasons("number 900-00-0000")
assert "KYC / identity phrasing" in pii_reasons("attach my passport scan")
assert "card-shaped number" in pii_reasons("card 4242424242424242")
assert not pii_reasons("What did Fly announce for Sprites?")
print("pii checks ok")
from secrets_scan import forbidden_env_names
assert "STRIPE_API_KEY" in forbidden_env_names({"STRIPE_API_KEY": "x"})
assert not forbidden_env_names({
    "SPRITE_ROOT": "/",
    "GATEWAY_BASE": "https://api.sprites.dev",
    "CONNECTOR_TAVILY_ID": "conn_tavily_mock",
    "CONNECTOR_GITHUB_ID": "conn_github_mock",
})
print("secrets_scan ok")
from gateway import GatewayClient
client = GatewayClient(base="http://127.0.0.1:9")
refused = False
try:
    client._request("GET", "/health", headers={"Authorization": "Bearer placeholder"})
except RuntimeError as exc:
    refused = "refusing" in str(exc).lower()
assert refused, "gateway client must refuse an Authorization header"
refused = False
try:
    client._request("GET", "/health?token=placeholder")
except RuntimeError as exc:
    refused = "query" in str(exc).lower()
assert refused, "gateway client must refuse a token query parameter"
print("gateway client refuses token headers and query params")
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

# Stop only our mock gateway. A foreign listener on the port is left alone.
_stop_mock_gateway() {
  python3 - <<'PY'
import os, signal, time, pathlib, sys

port = int(os.environ.get("GW_PORT", "18111"))
pidfile = os.environ.get("GW_PIDFILE", "")

def listen_inodes(port):
    found = set()
    for name in ("tcp", "tcp6"):
        path = pathlib.Path("/proc/net") / name
        if not path.exists():
            continue
        for line in path.read_text().splitlines()[1:]:
            parts = line.split()
            if len(parts) < 10:
                continue
            local, state, inode = parts[1], parts[3], parts[9]
            try:
                if int(local.rsplit(":", 1)[-1], 16) != port or state != "0A":
                    continue
            except ValueError:
                continue
            found.add(inode)
    return found

def pids_for_inodes(inodes):
    hits = []
    if not inodes:
        return hits
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        matched = False
        try:
            fds = list((entry / "fd").iterdir())
        except (PermissionError, FileNotFoundError):
            continue
        for fd in fds:
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith("socket:[") and target[8:-1] in inodes:
                matched = True
                break
        if not matched:
            continue
        try:
            cmd = (entry / "cmdline").read_bytes().replace(b"\x00", b" ").decode(errors="replace")
        except OSError:
            cmd = ""
        hits.append((int(entry.name), cmd))
    return hits

def cmdline(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\x00", b" ").decode(errors="replace")
    except OSError:
        return ""

candidates = []
if pidfile and os.path.isfile(pidfile):
    raw = open(pidfile).read().strip()
    if raw.isdigit():
        cmd = cmdline(int(raw))
        if "mock_gateway.py" in cmd:
            candidates.append((int(raw), cmd))
        elif cmd:
            print(f"pidfile {raw} is not the mock gateway; leaving it")

seen = {pid for pid, _ in candidates}
for pid, cmd in pids_for_inodes(listen_inodes(port)):
    if pid in seen:
        continue
    if "mock_gateway.py" not in cmd:
        print(f"port {port} held by pid {pid}, not the mock gateway; leaving it")
        continue
    candidates.append((pid, cmd))

for pid, _cmd in candidates:
    print(f"stopping mock gateway pid {pid}")
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

time.sleep(0.25)
for pid, cmd in pids_for_inodes(listen_inodes(port)):
    if "mock_gateway.py" not in cmd:
        continue
    print(f"escalating to SIGKILL on {pid}")
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
time.sleep(0.1)
left = [pid for pid, cmd in pids_for_inodes(listen_inodes(port)) if "mock_gateway.py" in cmd]
if left:
    print("mock gateway still listening:", left)
    sys.exit(1)
print("mock gateway is not listening")
PY
}

stage_teardown() {
  echo "teardown: logs for this run stay in ${LOG_DIR} (not deleted)"
  _stop_mock_gateway
  rm -f "$GW_PIDFILE"
  rm -f "${ROOT}/var/last-ask.json" "${ROOT}/var/last-forget.json" "${ROOT}/var/last-forget-s3.json"
  rm -rf "${SPRITE_ROOT}" "${ROOT}/var/sprite-root" "${GW_STORE}" "${HOLDER_DIR}"
  mkdir -p "${ROOT}/var"
  echo "cleared sprite root, mock store, holder dir, and stage scratch files"
  if _port_in_use "$GW_PORT"; then
    echo "NOTE: 127.0.0.1:${GW_PORT} still in use (not this mock gateway)"
  else
    echo "port ${GW_PORT} is free"
  fi
  if [[ ! -d "$LOG_DIR" ]]; then
    echo "FAIL: current log dir ${LOG_DIR} is missing"
    return 1
  fi
  echo "log files kept:"
  find "$LOG_DIR" -type f | sort
  echo "teardown clean"
}

print_summary() {
  local code=0 line status_line
  if [[ "$FAILURES" -eq 0 ]]; then
    if [[ "${#SUMMARY[@]}" -eq 1 ]]; then
      status_line="PASS  1 stage, 0 failed"
    else
      status_line="PASS  ${#SUMMARY[@]} stages, 0 failed"
    fi
    code=0
  else
    status_line="FAIL  ${FAILURES} stage(s) failed"
    code=1
  fi
  {
    echo
    echo "${AGENT_NAME} summary  (logs in ${LOG_DIR})"
    echo "ID          RESULT      TIME  TITLE"
    for line in "${SUMMARY[@]}"; do
      echo "$line"
    done
    echo
    echo "$status_line"
  } | tee "${LOG_DIR}/summary.log"
  return "$code"
}

reset_results() {
  FAILURES=0
  SUMMARY=()
}

e2e_usage() {
  cat <<EOF
Usage: ./scripts/e2e.sh [--ci | --all | --stage N | --help]

  (no args, terminal)   interactive menu
  (no args, no tty)     run every stage
  --ci, --all           run every stage, teardown last
  --stage N             run stage N only (1..8)

Each stage runs in its own process, with its own pass/fail, timing, and log.
A stage can run alone. Logs are saved under logs/e2e-<stamp>-<pid>/.
Teardown is the last step and does not delete those logs.

Exit 0 only when every requested stage passes.
EOF
}

e2e_dispatch() {
  case "${1:-}" in
    --help|-h) e2e_usage; return 0 ;;
    --worker)
      init_run_dirs
      echo "worker pid $$ function ${2:-}"
      set -euo pipefail
      case "${2:-}" in
        stage_toolchain) stage_toolchain ;;
        stage_env) stage_env ;;
        stage_reject_pii) stage_reject_pii ;;
        stage_lookup) stage_lookup ;;
        stage_notes) stage_notes ;;
        stage_forget) stage_forget ;;
        stage_receipt) stage_receipt ;;
        stage_teardown) stage_teardown ;;
        *)
          echo "unknown worker: ${2:-}" >&2
          return 2
          ;;
      esac
      ;;
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
