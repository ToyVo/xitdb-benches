#!/usr/bin/env bash
# Installs the pinned Go toolchain (runs once as root on Ubuntu 24.04).
set -euo pipefail
GO_VERSION="1.23.12"
if command -v go >/dev/null && go version | grep -q "go$GO_VERSION"; then
  echo "go $GO_VERSION already installed"
  exit 0
fi
apt-get update && apt-get install -y build-essential curl
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz
ln -sf /usr/local/go/bin/go /usr/local/bin/go
/usr/local/go/bin/go version
