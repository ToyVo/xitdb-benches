#!/usr/bin/env bash
# Installs pinned Temurin JDK 21 + Clojure CLI (runs once as root on Ubuntu 24.04).
set -euo pipefail
JDK_VERSION="21.0.13+9"
CLJ_VERSION="1.12.6.1673"
if command -v java >/dev/null && java -version 2>&1 | grep -q "21\.0"; then
  echo "java 21 already installed"
else
  apt-get update && apt-get install -y curl ruby ruby
  JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION}/OpenJDK21U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz"
  curl -fsSL "$JDK_URL" | tar -C /opt -xz
  ln -sfn "/opt/jdk-${JDK_VERSION}" /opt/jdk-21
  ln -sf /opt/jdk-21/bin/java /usr/local/bin/java
fi
# Existence is not enough: an earlier revision of this script installed a
# broken wrapper (literal PREFIX). Reinstall when unhealthy.
if command -v clojure >/dev/null && ! grep -q "PREFIX" "$(command -v clojure)"; then
  echo "clojure already installed"
else
  # Upstream's installer wants an existing prefix dir and ruby under the
  # HOMEBREW_RUBY_PATH name (both Homebrew-isms that work fine on Ubuntu).
  tmp="$(mktemp -d)"
  curl -fsSL "https://download.clojure.org/install/clojure-tools-${CLJ_VERSION}.tar.gz" \
    | tar -C "$tmp" -xz
  mkdir -p /usr/local
  (cd "$tmp/clojure-tools" && HOMEBREW_RUBY_PATH=ruby bash ./install.sh /usr/local)
  rm -rf "$tmp"
fi
java -version 2>&1 | head -1
clojure --version
