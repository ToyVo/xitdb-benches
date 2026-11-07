#!/usr/bin/env bash
# Installs the pinned Odin compiler (runs once as root on Ubuntu 24.04).
set -euo pipefail
ODIN_VERSION="dev-2026-10"
if command -v odin >/dev/null && odin version | grep -q "$ODIN_VERSION"; then
  echo "odin $ODIN_VERSION already installed"
  exit 0
fi
apt-get update && apt-get install -y curl
curl -fsSL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz" \
  | tar -C /opt -xz
# The tarball's top dir carries a nightly date suffix; match it loosely.
ln -sfn /opt/odin-linux-amd64-*/odin /usr/local/bin/odin
odin version
