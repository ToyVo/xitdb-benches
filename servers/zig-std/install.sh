#!/usr/bin/env bash
# Installs the pinned Zig toolchain (runs once as root on Ubuntu 24.04).
set -euo pipefail
ZIG_VERSION="0.17.0"
if command -v zig >/dev/null && zig version | grep -q "^${ZIG_VERSION}$"; then
  echo "zig $ZIG_VERSION already installed"
  exit 0
fi
apt-get update && apt-get install -y curl xz-utils
curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
  | tar -C /opt -xJ
ln -sf "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig
zig version
