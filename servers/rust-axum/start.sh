#!/usr/bin/env bash
set -euo pipefail
HOST="${HOST:-127.0.0.1}"; PORT="${PORT:-3000}"; exec "$(dirname "$0")/target/release/xitdb-bench-rust"
