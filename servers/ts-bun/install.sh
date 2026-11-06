#!/usr/bin/env bash
# Installs pinned Bun (runs once as root on Ubuntu 24.04).
set -euo pipefail
BUN_VERSION="bun-v1.4.4"
if command -v bun >/dev/null && bun --version | grep -q "^1\.4\.4"; then
  echo "bun 1.4.4 already installed"
  exit 0
fi
apt-get update && apt-get install -y curl unzip
curl -fsSL https://bun.sh/install | bash -s -- "$BUN_VERSION"
ln -sf /root/.bun/bin/bun /usr/local/bin/bun
bun --version
