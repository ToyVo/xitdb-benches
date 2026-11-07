#!/usr/bin/env bash
set -euo pipefail
exec java -Xmx1g -jar "$(dirname "$0")/target/server.jar"
