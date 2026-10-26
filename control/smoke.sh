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
# Editors (epr-consulting/lab-images#12): full vim with syntax and the YAML
# indent rules, vi as the same vim, and nano with its YAML highlighting.
[[ $(vim --version) == *+syntax* ]]
vi --version >/dev/null
printf 'a:\n\tb: 1\n' > "$HOME/smoke.yaml"
vim --not-a-term -n -c "redir! > $HOME/vim.out" \
  -c 'echo &filetype &syntax &shiftwidth &softtabstop &expandtab' -c 'redir END' -c 'qa!' \
  "$HOME/smoke.yaml" </dev/null >/dev/null 2>&1
[[ $(tr -d '\n' < "$HOME/vim.out") == 'yaml yaml 2 2 1' ]]
rm -f "$HOME/smoke.yaml" "$HOME/vim.out"
nano --version >/dev/null
test -s /usr/share/nano/yaml.nanorc
grep -qx 'include "/usr/share/nano/\*.nanorc"' /etc/nanorc
# The learner's shell is bash -i started in /tmp. It starts in ~ (made if
# missing, only from /tmp), with colours, readline settings and the prompt.
cd /tmp
[[ $(bash -ic pwd 2>/dev/null) == "$HOME" ]]
[[ $(HOME=/tmp/smoke-home bash -ic pwd 2>/dev/null) == /tmp/smoke-home ]]
rmdir /tmp/smoke-home
[[ $(cd /usr && bash -ic pwd 2>/dev/null) == /usr ]]
aliases=$(bash -ic alias 2>/dev/null)
[[ $aliases == *"alias ls='ls --color=auto'"* && $aliases == *"alias grep='grep --color=auto'"* ]]
[[ $(bash -ic 'echo "$LESS $LANG $COLORTERM ${LS_COLORS:+ls-colors}"' 2>/dev/null) == '-R C.UTF-8 truecolor ls-colors' ]]
[[ $(bash -ic 'echo "$PS1"' 2>/dev/null) == *'\[\e[1;32m\]'* ]]
readline=$(bash -ic 'bind -v' 2>/dev/null)
for setting in show-all-if-ambiguous completion-ignore-case colored-stats \
  colored-completion-prefix mark-symlinked-directories; do
  [[ $readline == *"set $setting on"* ]]
done
# bash-completion loads each command's completion the way it does on the first
# Tab: git's comes with its package, the others are generated at build time.
completes() {
  bash -ic 'for command; do _comp_load "$command" && complete -p "$command" || exit 1; done' _ "$@" >/dev/null 2>&1
}
completes git
# kubectl, k and kubecolor (k8s and agent tiers). The Secret behind
# $KUBECONFIG is read-only and may fill in late, so the shell works on a copy.
kubernetes_shell() {
  completes kubectl helm k9s
  bash -ic 'complete -p kubectl k kubecolor' >/dev/null 2>&1
  # k completes the way kubectl does, without a cluster.
  [[ $(bash -ic 'COMP_WORDS=(k conf); COMP_CWORD=1; COMP_LINE="k conf"; COMP_POINT=${#COMP_LINE}; __start_kubectl; echo "${COMPREPLY[*]}"' 2>/dev/null) == config ]]
  # kubectl stays plain; kubecolor colours when asked to.
  kubecolor --kubecolor-version >/dev/null
  local ro=$HOME/ro-kube late=$HOME/late-kube
  mkdir -p "$ro"
  cat > "$ro/config" <<'KUBECONFIG_EOF'
apiVersion: v1
kind: Config
clusters:
- name: smoke
  cluster:
    server: https://127.0.0.1:6443
contexts:
- name: smoke
  context:
    cluster: smoke
    user: smoke
current-context: smoke
users:
- name: smoke
  user:
    token: smoke
KUBECONFIG_EOF
  chmod 444 "$ro/config"
  chmod 555 "$ro"
  [[ $(KUBECONFIG=$ro/config kubectl config view) != *$'\e['* ]]
  [[ $(KUBECOLOR_FORCE_COLORS=true KUBECONFIG=$ro/config kubecolor config view) == *$'\e['* ]]
  # The fake kubeconfig is read-only, as the Secret mount is.
  if KUBECONFIG=$ro/config kubectl config set-context --current --namespace=demo 2>/dev/null; then
    echo 'The fake kubeconfig is unexpectedly writable' >&2
    exit 1
  fi
  [[ $(KUBECONFIG=$ro/config bash -ic 'kubectl config set-context --current --namespace=demo >/dev/null && kubectl config view --minify -o jsonpath="{..namespace}"' 2>/dev/null) == demo ]]
  [[ $(stat -c %a "$HOME/.kube/config") == 600 ]]
  if grep -q namespace "$ro/config"; then
    echo 'The mounted kubeconfig was changed' >&2
    exit 1
  fi
  # A second terminal keeps the copy, with the learner's namespace.
  [[ $(KUBECONFIG=$ro/config bash -ic 'echo "$KUBECONFIG"; kubectl config view --minify -o jsonpath="{..namespace}"' 2>/dev/null) == "$HOME/.kube/config"$'\n'demo ]]
  # A Secret that fills in after the shell started is copied at a later prompt,
  # and the prompt shows the context and namespace.
  rm -rf "$HOME/.kube"
  prompts=$(printf '%s\n' "mkdir -p $late && cp $ro/config $late/config" 'echo "kubeconfig=$KUBECONFIG"' \
    'kubectl config set-context --current --namespace=late' true |
    KUBECONFIG=$late/config bash -i 2>&1)
  [[ $prompts == *"kubeconfig=$HOME/.kube/config"* ]]
  [[ $prompts == *'(smoke:late)'* ]]
  # The prompt reads the kubeconfig again only when its mtime changes: one call
  # for the namespace change below, none for the prompts around it.
  rm -f "$HOME/kubectl-calls"
  printf '%s\n' 'kubectl() { echo call >>"$HOME/kubectl-calls"; command kubectl "$@"; }' true true \
    'kubectl config set-context --current --namespace=again' true true |
    KUBECONFIG=$late/config bash -i >/dev/null 2>&1
  [[ $(wc -l < "$HOME/kubectl-calls") == 2 ]]
  chmod -R u+w "$ro"
  rm -rf "$ro" "$late" "$HOME/.kube" "$HOME/kubectl-calls"
}
case "${1:?tier required}" in
  k8s)
    kubectl version --client
    helm version --short
    k9s version
    helm create "$HOME/chart" >/dev/null
    helm template example "$HOME/chart" >/dev/null
    kubernetes_shell
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
    kubernetes_shell
    completes kubectl-ai k8sgpt kubernetes-mcp-server
    ;;
  docker)
    docker --version
    docker compose version
    docker buildx version
    printf 'services:\n  lab:\n    image: scratch\n' > "$HOME/compose.yaml"
    docker compose -f "$HOME/compose.yaml" config --quiet
    completes docker
    ;;
  linux)
    systemctl --version
    ip -Version
    ss --version
    completes systemctl
    ;;
  dev)
    code-server --version
    go version
    python3 --version
    node --version
    rustc --version
    cargo --version
    completes rustup cargo npm
    printf 'package main\nfunc main() {}\n' > "$HOME/main.go"
    go build -o "$HOME/go-check" "$HOME/main.go"
    printf 'fn main() {}\n' > "$HOME/main.rs"
    rustc "$HOME/main.rs" -o "$HOME/rust-check"
    python3 -m venv "$HOME/venv"
    node -e 'if (1 + 1 !== 2) process.exit(1)'
    ;;
  *) exit 2 ;;
esac
