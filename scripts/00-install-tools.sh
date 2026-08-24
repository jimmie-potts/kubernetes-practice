#!/usr/bin/env bash
# Installs kind, kubectl, and helm into ~/.local/bin. Safe to re-run: each run
# fetches the latest stable version and overwrites the previous binary.
set -euo pipefail

[ "$(uname -s)" = Linux ] || { echo "This script only supports Linux (got $(uname -s))" >&2; exit 1; }

BIN="$HOME/.local/bin"
mkdir -p "$BIN"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

echo "Installing kubectl..."
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo "$BIN/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
chmod +x "$BIN/kubectl"

echo "Installing kind..."
# Fetch the release JSON into a variable, then grep WITHOUT -m1: an early
# grep exit closes the pipe mid-write, and pipefail turns that SIGPIPE into
# silent death (curl error 23 / exit 141). "tag_name" appears exactly once.
KIND_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest)
KIND_VERSION=$(printf '%s' "$KIND_RELEASE_JSON" | grep '"tag_name"' | cut -d'"' -f4)
[ -n "$KIND_VERSION" ] || { echo "Could not determine latest kind version" >&2; exit 1; }
curl -fsSLo "$BIN/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x "$BIN/kind"

echo "Installing helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$BIN" USE_SUDO=false PATH="$BIN:$PATH" bash

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "NOTE: $BIN is not on your PATH. Add this to ~/.bashrc:"; echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo
echo "Installed versions:"
"$BIN/kind" version
"$BIN/kubectl" version --client
"$BIN/helm" version --short
