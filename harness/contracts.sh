#!/usr/bin/env bash
# Contracts gate for xitdb-benches skeleton (Task 1).
# Asserts every server honors the droplet contract files.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; pass=0
ok() { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

declare -A WANT=(
  [rust-axum]="Axum"
  [go-std]="net/http"
  [ts-bun]="Bun.serve"
  [zig-std]="Zig"
  [java-spring]="Spring Boot"
  [clj-httpkit]="http-kit"
  [odin-std]="Odin"
  [rust-axum-sqlite]="rusqlite"
  [go-std-sqlite]="mattn"
  [ts-bun-sqlite]="bun:sqlite"
  [zig-std-sqlite]="amalgamation"
  [java-spring-sqlite]="xerial"
  [clj-httpkit-sqlite]="xerial"
  [odin-std-sqlite]="sqlite3"
)
for name in rust-axum go-std ts-bun zig-std java-spring clj-httpkit odin-std rust-axum-sqlite go-std-sqlite ts-bun-sqlite zig-std-sqlite java-spring-sqlite clj-httpkit-sqlite odin-std-sqlite; do
  d="$ROOT/servers/$name"
  for f in install.sh build.sh start.sh README.md; do
    if [ -f "$d/$f" ]; then ok "$name/$f exists"; else bad "$name/$f exists"; fi
  done
  for f in install.sh build.sh start.sh; do
    if [ -x "$d/$f" ]; then ok "$name/$f executable"; else bad "$name/$f executable"; fi
  done
  if grep -q "${WANT[$name]}" "$d/README.md" 2>/dev/null; then ok "$name/README mentions ${WANT[$name]}"
  else bad "$name/README mentions ${WANT[$name]}"; fi
done

for needle in "XITDB_PATH" "feed_key" "twelve-dollar-challenge" "id,body,created_at,author,like_count"; do
  if grep -q "$needle" "$ROOT/SPEC-XITDB.md" 2>/dev/null; then ok "SPEC-XITDB.md has $needle"
  else bad "SPEC-XITDB.md has $needle"; fi
done
for k in users posts feed likes meta; do
  if grep -q "$k" "$ROOT/schema-xitdb.md" 2>/dev/null; then ok "schema-xitdb.md has $k"
  else bad "schema-xitdb.md has $k"; fi
done
for p in 3001 3002 3003 3004 3005 3006 3007 3008 3009 3010 3011 3012 3013 3014; do
  if grep -q "$p" "$ROOT/docker-compose.yml" 2>/dev/null; then ok "compose has $p"
  else bad "compose has $p"; fi
done
for f in harness/bench/load.js harness/bench/nginx.conf README.md .gitignore LEADERBOARD-XITDB.md; do
  if [ -f "$ROOT/$f" ]; then ok "$f exists"; else bad "$f exists"; fi
done

echo "contracts: pass=$pass fail=$fail"
[ "$fail" = 0 ]
