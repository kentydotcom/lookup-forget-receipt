#!/usr/bin/env bash
# Start the mock gateway and the demo UI for local comparison.
# Copyright (c) 2026 Kent G Lau, PhD. No KYC. No retained PII.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONPATH="${ROOT}/lib:${ROOT}"
export SPRITE_ROOT="${SPRITE_ROOT:-${ROOT}/var/sprite-root}"
export HOLDER_DIR="${HOLDER_DIR:-${ROOT}/var/holder}"
export GATEWAY_BASE="${GATEWAY_BASE:-http://127.0.0.1:18111}"
export CONNECTOR_TAVILY_ID="${CONNECTOR_TAVILY_ID:-conn_tavily_mock}"
export CONNECTOR_FIRECRAWL_ID="${CONNECTOR_FIRECRAWL_ID:-conn_firecrawl_mock}"
export CONNECTOR_GITHUB_ID="${CONNECTOR_GITHUB_ID:-conn_github_mock}"
export CONNECTOR_S3_ID="${CONNECTOR_S3_ID:-conn_s3_mock}"
export CONNECTOR_STRIPE_ID="${CONNECTOR_STRIPE_ID:-conn_stripe_mock}"
export RECEIPT_STORE="${RECEIPT_STORE:-github}"
export RECEIPT_GITHUB_OWNER="${RECEIPT_GITHUB_OWNER:-demo-org}"
export RECEIPT_GITHUB_REPO="${RECEIPT_GITHUB_REPO:-receipts}"
mkdir -p "$SPRITE_ROOT" "$HOLDER_DIR" "$ROOT/var/mock-store"
cleanup() {
  if [[ -n "${GW_PID:-}" ]] && kill -0 "$GW_PID" 2>/dev/null; then
    kill "$GW_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
python3 "$ROOT/scripts/mock_gateway.py" --host 127.0.0.1 --port 18111 --store "$ROOT/var/mock-store" &
GW_PID=$!
echo "mock gateway pid $GW_PID on :18111"
# wait briefly for health
python3 - <<'WAIT'
import time, urllib.request, sys
url = "http://127.0.0.1:18111/health"
for _ in range(30):
    try:
        urllib.request.urlopen(url, timeout=0.3)
        sys.exit(0)
    except Exception:
        time.sleep(0.1)
sys.exit(1)
WAIT
echo "demo UI at http://127.0.0.1:18021/"
exec python3 -m agent serve --host 127.0.0.1 --port 18021
