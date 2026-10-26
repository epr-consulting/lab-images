# lab-control

These are the images for the learner's terminal pod (the "control pod") in a
MyLabSkills lab session. Five Dockerfile targets ship preinstalled tools:

| Target | Tools |
| --- | --- |
| `k8s` | kubectl 1.35.8, Helm 3.22.0, k9s 0.51.0, kubecolor 0.8.0 (opt-in, see [Shell](#shell)) |
| `agent` | everything in `k8s`, plus kubectl-ai 0.0.31, k8sgpt 0.4.41, kubernetes-mcp-server 0.0.67 |
| `docker` | Docker CLI 29, bundled Compose and Buildx plugins |
| `linux` | bash, systemd tools, iproute2, DNS/network utilities |
| `dev` | code-server 4.137.0, Go 1.27, Python 3.13, Node 24, Rust 1.98.1 |

Every tier also has bash-completion, vim and nano, and the shell setup below.

## Pins

Base and toolchain images are pinned by multi-architecture digest. Downloaded
binaries are pinned by per-architecture checksum. Debian packages take the
current security updates at build time, and the published image digest fixes
the resulting contents. When you upgrade a pin, upgrade both architectures'
smoke tests with it. Dependabot proposes the image updates weekly, once a
release is 7 days old; a new Node LTS line is moved by hand.

## CI and publishing

CI builds and smoke-tests each target on native AMD64 and ARM64 runners. Pull
requests build without publishing. A push to `main` publishes
`ghcr.io/epr-consulting/lab-control:<tier>-<full-commit-sha>` as a
multi-platform image. Deployments use the manifest digest, never a tag. To run
a tier on the local MyLabSkills stack before it is published, see [testing an
unpublished image locally](../README.md#testing-an-unpublished-image-locally).

## Security contract

The control pod runs as UID/GID 1000 with all capabilities dropped and a
read-only root filesystem. Only `/tmp` is writable; tool state lives under
`/tmp/student`. Every image must pass `control-smoke <tier>` under that
contract:

```sh
docker build --target k8s -t control-test:k8s control
docker run --rm --read-only --user 1000:1000 --cap-drop ALL \
  --security-opt no-new-privileges --network none \
  --tmpfs /tmp:rw,nosuid,nodev,size=512m,mode=1777 \
  control-test:k8s control-smoke k8s
```

The `k8s` smoke test is also the tool contract for labs, and the `agent` tier
repeats it. The control image
is session tooling, so changing it never re-qualifies published labs. A new
image must therefore still provide every tool the smoke test checks.

## Shell

The learner's terminal is `bash -i`, not a login shell, started in `/tmp` with
`HOME=/tmp/student`. In every tier `/etc/bash.bashrc` loads bash-completion and
the files in `/etc/mylabskills/`, so a learner finds this:

- The shell starts in `~`. It creates `~` if the empty `/tmp` has no `student`
  directory yet, and moves only when it started in `/tmp`.
- The prompt reads `student@lab:~`, since the pod's hostname is a session id.
  The prompt, `ls` and `grep` are coloured, and `LESS=-R`. The image sets
  `LANG=C.UTF-8` and `COLORTERM=truecolor`.
- One Tab lists the matches. Completion ignores case and colours the listing.
  The settings are in `/etc/mylabskills/inputrc`, which the image's `INPUTRC`
  points to; a learner's own `~/.inputrc` still applies last.
- Completion works for git and systemctl (their packages ship it) and for the
  tools that write their own, generated at build time with no network:
  kubectl, helm and k9s in `k8s`, those and the agent tools in `agent`, docker
  in `docker`, and rustup, cargo and npm in `dev`.
- vim has syntax highlighting for a dark background, filetype indent and
  2-space YAML (`/etc/vim/vimrc.local`). `vi` is the same vim. nano highlights YAML.

Where kubectl is installed (`k8s` and `agent`):

- `k` is `kubectl`, with kubectl's completion, as in the CKA and CKAD
  environment.
- `KUBECONFIG` points at a read-only Secret mount that can be empty or missing
  when the shell starts. Once it has content, the shell copies it to
  `~/.kube/config` (mode 600) and points `KUBECONFIG` at the copy, so
  `kubectl config set-context --current --namespace=x` works. Each prompt tries
  again until the Secret has content. Another terminal uses the copy that is
  there, with the learner's changes. The mounted file is never changed.
- The prompt shows `(context:namespace)`. It reads them with one kubectl call,
  and only when the kubeconfig's mtime has changed.
- kubecolor is installed and off, so `kubectl` behaves as in the exam. To
  colour a session, run `alias kubectl=kubecolor`; `k` follows it.

Nothing else is added: no fzf, kubectx, kubens or ble.sh, which the exam
environment does not have either.

## Shell history

Every tier configures interactive bash (`history.bash`, sourced by
`/etc/bash.bashrc`) to append each finished command to
`/tmp/.mylabskills_history`, after a `#<epoch seconds>` line. Only the
commands are written, never their output. A command typed after a space is not
recorded, history expansion is off (a `!` means what it means under
`/bin/sh`), and the file is cut to its last 32 KiB once it passes 64 KiB. It
lives in the pod's `/tmp`, so it ends with the session.

In `k8s` and `agent`, the kubectl prompt hook is chained after the history
hook in `PROMPT_COMMAND`. The history is still written first, in the same
format.

The backend starts the learner's terminal as `bash -i` and reads the end of
this file only when the learner shares their recent commands with an AI hint
(epr-consulting/backend#370); the path is part of that contract. The smoke
test checks the hook in every tier.

## Agent tier

The `agent` tier adds AI-assisted Kubernetes tools. They are tools only: no
model, API key or endpoint is built in. The environment supplies the model
endpoint and credentials at run time, through the environment variables and
flags each tool documents (kubectl-ai `--llm-provider` and provider variables,
k8sgpt `auth add --baseurl --model --password`). Nothing in the image
contacts a model unless a learner or lab starts one of these tools.

## What these images do not do

They are client and tool images only:
- The `docker` tier starts no daemon and mounts no host socket.
- The `linux` tier ships systemd tools but does not run systemd as PID 1.
- code-server is installed, but no unauthenticated listener starts.

The `dev` smoke test compiles sample programs in 512 MiB of temporary
storage, so a real dev workspace needs more persistent space than the
terminal's current limit allows.
