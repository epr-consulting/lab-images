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
# The learner's shell history: each finished command after its time, never
# its output, not a command typed after a space, "!" kept literal, and the
# file under 64 KiB.
history=/tmp/.mylabskills_history
rm -f "$history"
printf '%s\n' 'echo smoke-command' ' echo smoke-hidden' 'printf "%s-%s\n" smoke output' 'echo "bang!"' |
  bash -i >/dev/null 2>&1
grep -qxF 'echo smoke-command' "$history"
grep -qxF 'printf "%s-%s\n" smoke output' "$history"
grep -qxF 'echo "bang!"' "$history"
grep -qx '#[0-9]*' "$history"
if grep -q -e smoke-hidden -e smoke-output "$history"; then
  echo 'Shell history holds a space-prefixed command or command output' >&2
  exit 1
fi
seq -f "echo %0300g" 1 500 | bash -i >/dev/null 2>&1
(( $(stat -c %s "$history") <= 65536 ))
grep -qx 'echo 0*500' "$history"
# Workspace files (backend #226): the platform writes them with install from
# stdin and reads them back with a bounded head -c, never through a shell, in
# the student's home.
[[ $HOME == /tmp/student ]]
printf 'smoke-file\n' | install -D -T -m 0640 /dev/stdin "$HOME/workspace/a/b.txt"
[[ $(stat -c %a "$HOME/workspace/a/b.txt") == 640 ]]
[[ $(head -c 65537 "$HOME/workspace/a/b.txt") == smoke-file ]]
rm -rf "$HOME/workspace"
case "${1:?tier required}" in
  k8s)
    kubectl version --client
    helm version --short
    k9s version
    helm create "$HOME/chart" >/dev/null
    helm template example "$HOME/chart" >/dev/null
    ;;
  agent)
    kubectl version --client
    helm version --short
    k9s version
    helm create "$HOME/chart" >/dev/null
    helm template example "$HOME/chart" >/dev/null
    kubectl-ai version
    k8sgpt version
    kubernetes-mcp-server --version
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
