# lab-project

The toolchains of MyLabSkills project labs (epr-consulting/workspace#73): a
learner builds one project over several sessions, and each track has its own
tools. Five Dockerfile targets ship preinstalled tools, published as
`ghcr.io/epr-consulting/lab-project:<tier>-<full-commit-sha>`:

| Target | Track | Tools |
| --- | --- | --- |
| `cicd` | CI/CD | Gitea 28.2.0 with its container registry, Gitea runner 5.1.1, rootless BuildKit 0.34.0 with RootlessKit 3.3.0, Argo CD client 3.5.5 |
| `iac` | Infrastructure as code | OpenTofu 1.13.1, Ansible 14.5.0 (ansible-core 2.21.5) with its collections, Moto 5.2.4 as a local AWS API, boto3 and pytest |
| `mlops` | MLOps | Python 3.13 with MLflow 3.17.1, DVC 3.67.1, NumPy 2.5.4, pandas 3.0.6, SciPy 1.18.1, scikit-learn 1.9.1 and pytest, CPU only |
| `web` | Web app | Node.js 26.12.0 with npm 11.20.0, Playwright 1.64.1 with a pinned headless Chromium 156, code-server 4.141.0 |
| `mobile` | Mobile app | everything in `web`, plus Expo 58.0.14 (CLI 58.1.11), create-expo-app 5.0.0 and expo-doctor 1.21.5 |

Every tier is Debian 13 with bash and bash-completion, git (new repositories
start on `main`), curl, jq, make, OpenSSH client, vim and nano, and the
learner's shell of [lab-control](../control/README.md#shell): the prompt,
colours, completion and the bounded command history the backend reads
(epr-consulting/backend#370). Those four files are taken from `control/`, so
they stay in one place; build with `--build-context shell=control`.

Every tier also has `/usr/local/bin/mls-hidden-test`, the runner of hidden
tests, and the execute-only `/usr/local/libexec/mls-bash` it runs them with.
The runner is built from [`control/hidden-test/`](../control/hidden-test/) and
described in the [lab-control README](../control/README.md#hidden-test-runner)
(epr-consulting/backend#486). `project-smoke` runs its smoke test.

## Tools, never content

These images contain tools only. A project's starter code, tests, hidden tests,
expected answers and grading logic are delivered by the platform at run time,
never built in. The smoke test fails when an image holds files in the places a
lab's content would go, and no tier starts a server by itself.

## Licences

Every tool was checked against its upstream licence file or package metadata on
2 November 2026. None is source-available or restricted to non-commercial use
(the change that cost us the CK-X labs). Installed tools keep their own licences;
the build files of this repository are Apache-2.0.

| Tool | Licence |
| --- | --- |
| Gitea, Gitea runner | MIT |
| BuildKit, RootlessKit, Argo CD | Apache-2.0 |
| OpenTofu | MPL-2.0 |
| Ansible, ansible-core | GPL-3.0-or-later |
| Ansible collections (ansible.posix, community.general, community.docker, kubernetes.core, amazon.aws and the others the `ansible` package bundles) | GPL-3.0-or-later; community.docker also has Apache-2.0 parts |
| Moto, boto3, kubernetes (Python client), DVC, pyarrow | Apache-2.0 |
| MLflow | Apache-2.0 |
| NumPy, pandas, SciPy, scikit-learn, joblib | BSD-3-Clause (NumPy also bundles 0BSD, MIT, Zlib and CC0-1.0 parts) |
| pytest, pip, jmespath | MIT |
| Node.js, code-server, Expo, expo-doctor | MIT |
| npm | Artistic-2.0 |
| create-expo-app | BSD-3-Clause |
| Playwright | Apache-2.0 |
| Chrome headless shell (Chrome for Testing) | BSD-3-Clause, with the third-party licences in its `LICENSE.headless_shell` |
| Debian packages (git, bash, vim, nano, make, curl, jq, OpenSSH, uidmap and the browser's libraries) | their own free-software licences |

The tools that carry a copyleft licence (Ansible, git, bash, make, nano) are
installed as separate programs and not modified or linked into anything.

The smoke test also scans every installed Python distribution and npm package
for source-available, non-commercial and network-copyleft terms (AGPL, SSPL,
BUSL, Commons Clause, Elastic, PolyForm and the like), so a dependency that
changes its licence fails the build instead of reaching a lab.

## Pins

- The base is `debian:trixie-slim` pinned by multi-architecture digest (the
  `trixie-20261005` build). Dependabot proposes updates weekly.
- Downloaded binaries are pinned by per-architecture SHA-256 in `download.py`,
  taken from the upstream release's own checksum file or asset digest. Each
  version is an upstream release at least 14 days old when it was pinned.
- Python packages are installed with `--require-hashes` from the locks in
  `locks/`. npm packages are installed with `npm ci`, which checks the
  integrity hashes of `package-lock.json`. Every package in a lock was
  published at least 14 days before the lock's cutoff, so even transitive
  dependencies are not fresh. Install scripts do not run (`--ignore-scripts`).
- Debian packages take the current security updates at build time, and the
  published image digest fixes the resulting contents.

To move a pin, change the version and checksums in `download.py` for both
CPUs, or the version in a `locks/*.in` or `package.json`, regenerate the lock,
and update the matching checks in `smoke.sh`:

```sh
cd project/locks
CUT=<14 days ago>T00:00:00Z
for t in build ansible moto mlops; do
  uv pip compile $t.in --universal --python-version 3.13 --generate-hashes \
    --exclude-newer $CUT -o $t.txt
done
(cd web && npm install --package-lock-only --ignore-scripts --omit=peer --before=$CUT)
(cd mobile && npm install --package-lock-only --ignore-scripts --omit=peer --before=$CUT)
```

A version whose files were uploaded partly after the cutoff leaves only its
source distribution in the lock (`moto.in` pins `lazy-object-proxy<1.13` for
this reason); an image needs wheels on both CPUs, so check that the build still
installs from wheels.

## Security contract

The images run under the control pod's contract: UID/GID 1000, all capabilities
dropped, a read-only root filesystem and `no-new-privileges`. Only `/tmp` is
writable, so tool state lives under `HOME=/tmp/student`. Telemetry and update
checks are off (`DO_NOT_TRACK`, `MLFLOW_DISABLE_TELEMETRY`, `DVC_NO_ANALYTICS`,
`EXPO_NO_TELEMETRY`, `npm_config_update_notifier=false`, code-server's config),
since a session reaches no outside host.

One setting differs from lab-control's smoke test: `/tmp` allows executing files.
Project code runs from it (git hooks, npm scripts, test runners, programs the
learner builds), and the pod's `/tmp` is an `emptyDir`, which allows it. Docker's
own `--tmpfs` is `noexec` unless told otherwise.

```sh
docker buildx build --build-context shell=control --target iac -t project-test:iac project
docker run --rm --read-only --user 1000:1000 --cap-drop ALL \
  --security-opt no-new-privileges --network none \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777 \
  project-test:iac project-smoke iac
```

## What each tier needs at run time

Nothing starts by itself: the image's command is `sleep infinity`, and the lab
chooses what runs.

### `cicd`

- **Gitea** (`gitea web --config <app.ini> --work-path <absolute dir>`) needs a
  writable `app.ini` (it writes the secrets it generates) and a work path under
  `/tmp`; `GITEA_WORK_DIR` defaults to `/tmp/student/gitea`. Enable `[actions]`.
  Its packages registry is the session's container registry, at `/v2/`.
- **The runner** (`gitea-runner register --no-interactive ...`, then `daemon`)
  runs jobs in host mode: register it with the label `host:host` and put
  `runs-on: host` in the workflow. There is no Docker daemon. A session reaches
  no GitHub, so workflows use `run:` steps, not `uses: actions/...`. Set
  `runner.file` to a writable path and `cache.enabled: false` when the pod has no
  outbound address.
- **Rootless BuildKit** (`rootlesskit buildkitd`, then `buildctl build`) maps
  ids with `newuidmap` and `newgidmap`, which hold file capabilities, as in
  BuildKit's own rootless image. That needs more than the control pod's contract,
  and `project-smoke cicd-build` checks it: `allowPrivilegeEscalation` not set
  to false, the `SETUID` and `SETGID` capabilities, an unconfined seccomp
  profile and AppArmor profile, and `--oci-worker-no-process-sandbox` where the
  pod cannot unmask `/proc`. `$XDG_RUNTIME_DIR` (`/tmp/student/run`) must exist
  with mode 0700. BuildKit's default overlayfs snapshotter needs kernel 5.11 or
  later and a filesystem with user extended attributes; the smoke test uses the
  portable `native` snapshotter. To pull through the mirror, set its registry in
  a `buildkitd.toml`.
- **Argo CD**: `argocd` is the client only. Its server is deployed by the lab.

### `iac`

`python3` is Ansible's own Python, with boto3, kubernetes, jmespath and pytest.
`moto_server -H 0.0.0.0 -p 5000` starts the AWS API; Moto runs in its own venv
so its dependencies never constrain Ansible's. OpenTofu has no providers built
in, so a lab installs them through the mirror below. Real AWS is not reachable.

### `mlops`

`python3` is the venv's Python (`/opt/venv`), with `pip install --user` working
into the learner's home. `mlflow server` and `mlflow models serve
--env-manager local` run as they do anywhere; FastAPI, Flask and gunicorn
arrive with MLflow. There is no GPU stack, and a notebook server is not part of
this image (epr-consulting/backend#444).

### `web` and `mobile`

Playwright's browser lives in `/opt/playwright`, and `NODE_PATH` lets a test
`require('@playwright/test')` without an install. A project that installs its
own Playwright must pin the same version (1.64.1), because Playwright looks for
the browser revision that belongs to its version. Chromium runs without its
sandbox, as Playwright launches it. code-server is installed with telemetry and
update checks off and no listener; the lab starts it and chooses the address and
authentication. `mobile` has no Android emulator and no iOS build: KVM and macOS
are not available (epr-consulting/workspace#73). `EXPO_OFFLINE=1` turns off the
Expo CLI's network requests.

## Package mirror

A session reaches only the lab mirror (epr-consulting/infra#127, which is
extended to npm, PyPI and OpenTofu provider packages). The images carry no
mirror address, since it belongs to the execution cluster, and use the tools'
own settings. The lab sets these in the environment, and the mirror's private CA
is mounted as a file:

| Tool | Setting |
| --- | --- |
| npm | `NPM_CONFIG_REGISTRY=https://<mirror>/npm/`, and `NODE_EXTRA_CA_CERTS=<ca file>` |
| pip | `PIP_INDEX_URL=https://<mirror>/pypi/index/`, and `PIP_CERT=<ca file>` |
| OpenTofu | `TF_CLI_CONFIG_FILE=<file>` holding `provider_installation { network_mirror { url = "https://<mirror>/terraform/" } }`, and `SSL_CERT_FILE=<ca file>` |
| git, curl | `GIT_SSL_CAINFO=<ca file>`, `CURL_CA_BUNDLE=<ca file>` |
| BuildKit | `buildkitd.toml` with `[registry."docker.io"] mirrors = ["<mirror>"]` |

The paths are those of the mirror's prototype (infra#127). The tools read these
settings as documented; checked by hand against a local HTTPS server with a
private CA, with an IP-literal address and a name: npm 11 asks for
`/npm/<package>`, pip 26 for `/pypi/index/<package>/` and OpenTofu for
`/terraform/registry.opentofu.org/<namespace>/<type>/index.json`, and each
refuses the server without its CA setting. pip is locked at 26.2.1 because the
pip bundled with Debian's python3-venv (25.1.1) cannot connect to an https
index addressed by IP on Python 3.13.

Installing a package through the real mirror cannot be tested until it exists.

## CI and publishing

CI builds and smoke-tests each target on native AMD64 and ARM64 runners, and
runs the rootless build smoke test for `cicd`. Pull requests build without
publishing. A push to `main` publishes
`ghcr.io/epr-consulting/lab-project:<tier>-<full-commit-sha>` as a
multi-platform image. Deployments pin the manifest digest, never a tag.

## What these images do not do

- No tier starts a daemon: Gitea, the runner, BuildKit, Moto, MLflow and
  code-server are started by the lab.
- `cicd` has no Docker daemon and no way to run containers in a workflow.
- There are no lab files, sample projects or cached packages. A project's
  dependencies arrive through the mirror.
