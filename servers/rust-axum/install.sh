#!/usr/bin/env bash
# Installs the pinned Rust toolchain + git (runs once as root on Ubuntu 24.04).
set -euo pipefail
RUST_VERSION="1.85.0"
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
if [ -x /opt/cargo/bin/cargo ] && /opt/cargo/bin/cargo --version | grep -q "$RUST_VERSION"; then
  echo "cargo $RUST_VERSION already installed"
else
  apt-get update && apt-get install -y build-essential curl git
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain "$RUST_VERSION" --profile minimal --no-modify-path
fi
# Symlink the toolchain binaries directly (not the rustup proxies), so
# cargo/rustc work with no RUSTUP_HOME/CARGO_HOME in the environment.
TC="/opt/rustup/toolchains/$RUST_VERSION-x86_64-unknown-linux-gnu/bin"
ln -sf /opt/cargo/bin/rustup /usr/local/bin/rustup
ln -sf "$TC/cargo" /usr/local/bin/cargo
ln -sf "$TC/rustc" /usr/local/bin/rustc
cargo --version
rustc --version
