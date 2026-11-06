#!/usr/bin/env bash
# Regenerates harness/golden-{small,full} from the deterministic generator.
# Goldens are stable across runs (fixed PRNG + fixed fileId); regenerate
# only when the seed logic or response bytes intentionally change.
#
#   bash harness/gen-golden.sh small   # needs seed/ deps (bun install)
#   bash harness/gen-golden.sh full
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIZE="${1:?usage: harness/gen-golden.sh small|full}"
case "$SIZE" in
  small) POSTS="1 5000 10000" ;;
  full) POSTS="1 250000 500000" ;;
  *) echo "size must be small|full"; exit 1 ;;
esac

SEED_DIR="$(mktemp -d)"; trap 'rm -rf "$SEED_DIR"' EXIT
echo "== generate --$SIZE"
(cd "$ROOT/seed" && bun ./generate-xitdb.ts "--$SIZE" "$SEED_DIR" >/dev/null)

echo "== build rust server"
bash "$ROOT/servers/rust-axum/build.sh" >/dev/null

GOLDEN="$ROOT/harness/golden-$SIZE"
rm -rf "$GOLDEN"; mkdir -p "$GOLDEN"
export XITDB_PATH="$SEED_DIR/feed.xitdb" JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3099
"$ROOT/servers/rust-axum/target/release/xitdb-bench-rust" >"$SEED_DIR/server.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -rf "$SEED_DIR"' EXIT
for _ in $(seq 60); do curl -sf http://127.0.0.1:3099/health >/dev/null && break; sleep 1; done

echo "== capture goldens -> $GOLDEN"
curl -sf http://127.0.0.1:3099/feed -o "$GOLDEN/feed.json"
for id in $POSTS; do curl -sf "http://127.0.0.1:3099/posts/$id" -o "$GOLDEN/post-$id.json"; done
ls -la "$GOLDEN"
kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true
trap - EXIT; rm -rf "$SEED_DIR"
echo "goldens written; verify determinism by re-running and diffing."
