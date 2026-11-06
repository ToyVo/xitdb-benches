#!/usr/bin/env bash
set -euo pipefail
exec java -jar "$(dirname "$0")/target/server.jar"
