#!/usr/bin/env bash
# Installs pinned Temurin JDK 21 + Maven (runs once as root on Ubuntu 24.04).
set -euo pipefail
JDK_VERSION="21.0.13+9"
MAVEN_VERSION="3.10.0"
if command -v java >/dev/null && java -version 2>&1 | grep -q "21\.0"; then
  echo "java 21 already installed"
else
  apt-get update && apt-get install -y curl
  JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION}/OpenJDK21U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz"
  curl -fsSL "$JDK_URL" | tar -C /opt -xz
  ln -sfn "/opt/jdk-${JDK_VERSION}" /opt/jdk-21
  ln -sf /opt/jdk-21/bin/java /usr/local/bin/java
fi
if command -v mvn >/dev/null; then
  echo "maven already installed"
else
  curl -fsSL "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    | tar -C /opt -xz
  ln -sf "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn
fi
export JAVA_HOME=/opt/jdk-21
java -version 2>&1 | head -1
mvn -version 2>&1 | head -1
