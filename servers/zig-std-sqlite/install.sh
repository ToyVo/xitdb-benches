#!/usr/bin/env bash
# Installs the pinned Zig toolchain (runs once as root on Ubuntu 24.04).
set -euo pipefail
ZIG_VERSION="0.17.0"
if ! (command -v zig >/dev/null && zig version | grep -q "^${ZIG_VERSION}$"); then
  apt-get update && apt-get install -y curl xz-utils unzip
fi
if ! (command -v zig >/dev/null && zig version | grep -q "^${ZIG_VERSION}$"); then
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -C /opt -xJ
  ln -sf /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
fi
zig version
# SQLite amalgamation (hermetic: compiled into the binary, no system dep).
SQLITE_VERSION="3540100"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SCRIPT_DIR/vendor/sqlite/sqlite3.c" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://sqlite.org/2026/sqlite-amalgamation-${SQLITE_VERSION}.zip" -o "$tmp/sqlite.zip"
  unzip -q -o "$tmp/sqlite.zip" -d "$tmp"
  mkdir -p "$SCRIPT_DIR/vendor/sqlite"
  cp "$tmp/sqlite-amalgamation-${SQLITE_VERSION}/sqlite3.c" "$tmp/sqlite-amalgamation-${SQLITE_VERSION}/sqlite3.h" "$SCRIPT_DIR/vendor/sqlite/"
  rm -rf "$tmp"
fi
ls "$SCRIPT_DIR/vendor/sqlite/sqlite3.c"
