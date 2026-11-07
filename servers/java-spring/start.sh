#!/usr/bin/env bash
set -euo pipefail
jars=( "$(dirname "$0")"/target/*.jar )
if [ "${#jars[@]}" != 1 ]; then echo "expected exactly one jar in target/, found ${#jars[@]}" >&2; exit 1; fi
exec java -Xmx1g -jar "${jars[0]}"
