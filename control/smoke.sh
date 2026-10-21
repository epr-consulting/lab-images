#!/bin/bash
set -euo pipefail
[[ $(id -u) == 1000 ]]
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
test -w "$HOME"
if touch /usr/local/should-be-readonly 2>/dev/null; then
  echo 'Root filesystem unexpectedly writable' >&2
  exit 1
fi
bash --version >/dev/null
vim --version >/dev/null
case "${1:?tier required}" in
  k8s)
    kubectl version --client
    helm version --short
    k9s version
    helm create "$HOME/chart" >/dev/null
    helm template example "$HOME/chart" >/dev/null
    ;;
  docker)
    docker --version
    docker compose version
    docker buildx version
    printf 'services:\n  lab:\n    image: scratch\n' > "$HOME/compose.yaml"
    docker compose -f "$HOME/compose.yaml" config --quiet
    ;;
  linux)
    systemctl --version
    ip -Version
    ss --version
    ;;
  dev)
    code-server --version
    go version
    python3 --version
    node --version
    rustc --version
    cargo --version
    printf 'package main\nfunc main() {}\n' > "$HOME/main.go"
    go build -o "$HOME/go-check" "$HOME/main.go"
    printf 'fn main() {}\n' > "$HOME/main.rs"
    rustc "$HOME/main.rs" -o "$HOME/rust-check"
    python3 -m venv "$HOME/venv"
    node -e 'if (1 + 1 !== 2) process.exit(1)'
    ;;
  *) exit 2 ;;
esac
