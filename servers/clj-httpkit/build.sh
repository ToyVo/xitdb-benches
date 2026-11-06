#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")" && clojure -P -M:uberjar
