# lab-control

These are the images for the learner's terminal pod (the "control pod") in a
MyLabSkills lab session. Five Dockerfile targets ship preinstalled tools:

| Target | Tools |
| --- | --- |
| `k8s` | kubectl 1.35.8, Helm 3.22.0, k9s 0.51.0, vim |
| `agent` | everything in `k8s`, plus kubectl-ai 0.0.31, k8sgpt 0.4.41, kubernetes-mcp-server 0.0.67 |
| `docker` | Docker CLI 29, bundled Compose and Buildx plugins |
| `linux` | bash, systemd tools, iproute2, DNS/network utilities |
| `dev` | code-server 4.137.0, Go 1.27, Python 3.13, Node 24, Rust 1.98.1 |

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

## Shell history

Every tier configures interactive bash (`history.bash`, sourced by
`/etc/bash.bashrc`) to append each finished command to
`/tmp/.mylabskills_history`, after a `#<epoch seconds>` line. Only the
commands are written, never their output. A command typed after a space is not
recorded, history expansion is off (a `!` means what it means under
`/bin/sh`), and the file is cut to its last 32 KiB once it passes 64 KiB. It
lives in the pod's `/tmp`, so it ends with the session.

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
