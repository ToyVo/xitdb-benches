#!/usr/bin/env bash
# Builds a server, starts it on a FRESH feed.xitdb and runs the suite.
# Port of upstream test/run.sh — what CI runs on every pull request.
#
#   bash harness/run.sh servers/rust-axum             # small seed (default)
#   SIZE=full bash harness/run.sh servers/rust-axum   # full 50k/500k seed
#   PORT=3001 bash harness/run.sh servers/rust-axum
#
# Needs: bun (seed gen), curl, jq, openssl, and the server's own toolchain.
set -euo pipefail
DIR="$(cd "${1:?usage: harness/run.sh servers/<name>}" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIZE="${SIZE:-small}"
for f in build.sh start.sh; do [ -f "$DIR/$f" ] || { echo "missing $DIR/$f"; exit 1; }; done

export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT="${PORT:-3000}"
export GOLDEN_DIR="$ROOT/harness/golden-$SIZE"
[ -d "$GOLDEN_DIR" ] || { echo "no $GOLDEN_DIR — run: bash harness/gen-golden.sh $SIZE"; exit 1; }

SEED_DIR="$(mktemp -d)"
echo "== seed --$SIZE ($SEED_DIR)"
(cd "$ROOT/seed" && bun ./generate-xitdb.ts "--$SIZE" "$SEED_DIR")
export XITDB_PATH="$SEED_DIR/feed.xitdb"

echo "== build"; bash "$DIR/build.sh"
echo "== start ($XITDB_PATH)"
bash "$DIR/start.sh" > "$SEED_DIR/server.log" 2>&1 &
PID=$!
cleanup() { pkill -P $PID 2>/dev/null || true; kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -rf "$SEED_DIR"; }
trap cleanup EXIT
for _ in $(seq 60); do curl -sf "http://$HOST:$PORT/health" >/dev/null && break; sleep 1; done
curl -sf "http://$HOST:$PORT/health" >/dev/null || { echo "no healthy /health after 60 s"; cat "$SEED_DIR/server.log"; exit 1; }

echo "== test"
rc=0; bash "$ROOT/harness/test-xitdb.sh" "http://$HOST:$PORT" "$GOLDEN_DIR" || rc=$?
[ $rc = 0 ] || { echo "== server log (last 30 lines)"; tail -30 "$SEED_DIR/server.log"; }
trap - EXIT; cleanup
exit $rc
