#!/usr/bin/env bash
set -euo pipefail
# Scoring holds thousands of keep-alive conns; default soft limit (1024) is too low.
ulimit -n 65536 || true
HOST="${HOST:-127.0.0.1}"; PORT="${PORT:-3000}"; exec "$(dirname "$0")/target/release/xitdb-bench-rust-sqlite"
