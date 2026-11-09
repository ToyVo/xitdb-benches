#!/usr/bin/env bash
set -euo pipefail
# Scoring holds thousands of keep-alive conns; default soft limit (1024) is too low.
ulimit -n 65536 || true
exec java -Xmx1g -jar "$(dirname "$0")/target/server.jar"
