#!/bin/bash
# Smoke test of a lab-project image, run inside it under its security contract:
#   project-smoke <cicd|cicd-build|iac|mlops|web|mobile>
# Every tier is checked for the contract and for what its track needs. The
# tests start the real servers on the loopback interface and use generic
# sample data only: no lab content.
set -euo pipefail

# Licences a project image must never carry: source-available and non-commercial
# terms that change what a public lab may do (epr-consulting/lab-images#17).
LICENCE_DENY='AGPL|SSPL|Server Side Public|BUSL|Business Source|Commons Clause|Elastic License|Elastic-2|PolyForm|Source[ -]Available|Confluent Community|Redis Source|RSAL|Functional Source|NonCommercial|Non-Commercial|CC-BY-NC'
export LICENCE_DENY

tier=${1:?tier required}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/project-smoke.XXXXXX")
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    [[ -n $pid ]] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  chmod -R u+w "$scratch" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
# Starts a background server and remembers it for cleanup.
start() { "$@" & pids+=("$!"); }
# Waits up to $1 seconds for the rest of the arguments to succeed.
wait_for() {
  local seconds=$1 i
  shift
  for ((i = 0; i < seconds * 2; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
random() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# Succeeds when a command's output contains a text. Capturing the output first
# keeps a pipeline from failing on SIGPIPE under pipefail.
has() {
  local text=$1 output
  shift
  output=$("$@" 2>&1) || return 1
  [[ $output == *"$text"* ]]
}

# --- What every tier shares -------------------------------------------------
[[ $(id -u) == 1000 ]]
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
test -w "$HOME"
if touch /usr/local/should-be-readonly 2>/dev/null; then
  fail 'Root filesystem unexpectedly writable'
fi
bash --version >/dev/null
vim --version >/dev/null
nano --version >/dev/null
git --version
curl --version >/dev/null
jq --version
make --version >/dev/null
# The platform writes workspace files with install from stdin and reads them
# back with a bounded head -c, never through a shell, in the student's home.
[[ $HOME == /tmp/student ]]
printf 'smoke-file\n' | install -D -T -m 0640 /dev/stdin "$HOME/workspace/a/b.txt"
[[ $(stat -c %a "$HOME/workspace/a/b.txt") == 640 ]]
[[ $(head -c 65537 "$HOME/workspace/a/b.txt") == smoke-file ]]
rm -rf "$HOME/workspace"
# Git starts new repositories on main, as Gitea does.
[[ $(git config --system init.defaultBranch) == main ]]
# The shell of lab-control: the history contract the backend reads, and the prompt.
history=/tmp/.mylabskills_history
rm -f "$history"
printf '%s\n' 'echo smoke-command' ' echo smoke-hidden' 'echo "bang!"' | bash -i >/dev/null 2>&1
grep -qxF 'echo smoke-command' "$history"
grep -qxF 'echo "bang!"' "$history"
grep -qx '#[0-9]*' "$history"
if grep -q smoke-hidden "$history"; then
  fail 'Shell history holds a space-prefixed command'
fi
[[ $(bash -ic 'echo "$PS1"' 2>/dev/null) == *'\[\e[1;32m\]\u@lab'* ]]
cd /tmp
[[ $(bash -ic pwd 2>/dev/null) == "$HOME" ]]
# bash-completion loads each command's completion the way it does on the first Tab.
completes() {
  bash -ic 'for command; do _comp_load "$command" && complete -p "$command" || exit 1; done' _ "$@" >/dev/null 2>&1
}
completes git
# No lab content: a lab's files arrive at run time, never in an image.
for path in /workspace /lab /labs /exercises /solutions /answers /home/student "$HOME"/*; do
  [[ -e $path ]] && fail "Unexpected content at $path"
done

# --- Licence guards ---------------------------------------------------------
# Every Python distribution of a venv: its licence expression, or its trove
# classifiers, must not name a licence from LICENCE_DENY.
python_licences() {
  "$1" -I - <<'PY'
import importlib.metadata as metadata, os, re, sys
deny = re.compile(os.environ["LICENCE_DENY"], re.I)
bad, count = [], 0
for dist in metadata.distributions():
    meta = dist.metadata
    fields = [meta.get("License-Expression") or ""]
    fields += [c for c in meta.get_all("Classifier") or [] if c.startswith("License ::")]
    fields.append((meta.get("License") or "")[:100])
    text = " ".join(fields)
    count += 1
    if deny.search(text):
        bad.append(f"{meta['Name']} {meta['Version']}: {text[:120]}")
if bad or not count:
    sys.exit("denied or missing licences:\n" + "\n".join(bad))
print(f"python licences ok: {count} distributions")
PY
}
# Every package of a node_modules tree, the same way.
node_licences() {
  node - "$@" <<'JS'
const fs = require('fs'), path = require('path');
const deny = new RegExp(process.env.LICENCE_DENY, 'i');
const bad = []; let count = 0;
function walk(modules) {
  for (const entry of fs.readdirSync(modules, { withFileTypes: true })) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    const dir = path.join(modules, entry.name);
    if (entry.name.startsWith('@')) { walk(dir); continue; }
    if (entry.name === '.bin') continue;
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
      const lic = JSON.stringify(pkg.license ?? pkg.licenses ?? '');
      count++;
      if (deny.test(lic)) bad.push(`${pkg.name}@${pkg.version}: ${lic}`);
    } catch {}
    const nested = path.join(dir, 'node_modules');
    if (fs.existsSync(nested)) walk(nested);
  }
}
for (const root of process.argv.slice(2)) walk(root);
if (bad.length || !count) { console.error('denied or missing licences:\n' + bad.join('\n')); process.exit(1); }
console.log(`node licences ok: ${count} packages`);
JS
}

# --- Test reports -----------------------------------------------------------
# Hidden tests are graded from a JUnit XML report (epr-consulting/backend#486):
# check that the fixed runner of a tier can write a well-formed one.
junit_ok() {
  [[ $(jq -n --rawfile xml "$1" '$xml | contains("<testsuite") and contains("<testcase")') == true ]]
}

# ----------------------------------------------------------------------------
cicd() {
  has 'gitea version 28.2.0 ' gitea --version
  [[ $(gitea-runner --version) == 'gitea-runner version v5.1.1' ]]
  [[ $(argocd version --client --short) == 'argocd: v3.5.5+'* ]]
  has ' v0.34.0 ' buildctl --version
  has ' v0.34.0 ' buildkitd --version
  buildkit-runc --version >/dev/null
  has '3.3.0' rootlesskit --version
  # Rootless BuildKit maps ids with newuidmap and newgidmap, which hold file
  # capabilities rather than the setuid bit, over the student's id range.
  has 'cap_setuid=ep' getcap "$(command -v newuidmap)"
  has 'cap_setgid=ep' getcap "$(command -v newgidmap)"
  [[ ! -u $(command -v newuidmap) && ! -u $(command -v newgidmap) ]]
  grep -qx 'student:100000:65536' /etc/subuid
  grep -qx 'student:100000:65536' /etc/subgid
  completes argocd gitea-runner

  # Gitea, its container registry and a runner in host mode: a push starts a
  # workflow and the runner finishes it. Nothing leaves the loopback interface.
  local dir=$scratch/gitea password port=3000 base=http://127.0.0.1:3000
  local api=$base/api/v1 token
  password=$(random)
  mkdir -p "$dir/work" "$dir/repos" "$dir/hostwork"
  cat >"$dir/app.ini" <<EOF
APP_NAME = smoke
RUN_USER = $(id -un)
RUN_MODE = prod
WORK_PATH = $dir/work

[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = $port
ROOT_URL = $base/
DISABLE_SSH = true
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = $dir/gitea.db

[repository]
ROOT = $dir/repos

[security]
INSTALL_LOCK = true

[service]
DISABLE_REGISTRATION = true

[actions]
ENABLED = true

[log]
MODE = console
LEVEL = warn
EOF
  start gitea web --config "$dir/app.ini" --work-path "$dir/work" >"$dir/gitea.log" 2>&1
  wait_for 90 curl -fs "$base/api/healthz" || { cat "$dir/gitea.log" >&2; fail 'Gitea did not become healthy'; }
  gitea admin user create --config "$dir/app.ini" --work-path "$dir/work" --username smoke \
    --password "$password" --email smoke@example.invalid --admin --must-change-password=false >/dev/null
  curl -fsS -u "smoke:$password" -H 'Content-Type: application/json' \
    -d '{"name":"smoke","auto_init":true,"default_branch":"main"}' "$api/user/repos" >/dev/null
  # The packages registry speaks the OCI distribution API.
  [[ $(curl -s -o /dev/null -w '%{http_code}' "$base/v2/") == 401 ]]
  [[ $(curl -s -o /dev/null -w '%{http_code}' -u "smoke:$password" "$base/v2/") == 200 ]]

  token=$(gitea actions generate-runner-token --config "$dir/app.ini" --work-path "$dir/work")
  cat >"$dir/runner.yaml" <<EOF
runner:
  file: $dir/.runner
  capacity: 1
  labels: ["host:host"]
cache:
  enabled: false
host:
  workdir_parent: $dir/hostwork
EOF
  gitea-runner register --no-interactive -c "$dir/runner.yaml" --instance "$base" --token "$token" \
    --name smoke-runner >"$dir/register.log" 2>&1 || { cat "$dir/register.log" >&2; fail 'The runner did not register'; }
  start gitea-runner daemon -c "$dir/runner.yaml" >"$dir/runner.log" 2>&1

  git clone -q "http://smoke:$password@127.0.0.1:$port/smoke/smoke.git" "$dir/clone"
  mkdir -p "$dir/clone/.gitea/workflows"
  cat >"$dir/clone/.gitea/workflows/smoke.yaml" <<'EOF'
name: smoke
on: [push]
jobs:
  check:
    runs-on: host
    steps:
      - run: echo "runner-says-$((6 * 7))"
EOF
  git -C "$dir/clone" add -A
  git -C "$dir/clone" -c user.name=smoke -c user.email=smoke@example.invalid commit -q -m 'Add a workflow'
  git -C "$dir/clone" push -q origin main
  local i status=''
  for ((i = 0; i < 120; i++)); do
    status=$(curl -fsS -u "smoke:$password" "$api/repos/smoke/smoke/actions/runs" |
      jq -r '.workflow_runs[0] | "\(.status // "none") \(.conclusion // "")"')
    [[ $status == completed* ]] && break
    sleep 1
  done
  if [[ $status != 'completed success' ]]; then
    echo "workflow status: ${status:-none}" >&2
    tail -n 60 "$dir/runner.log" >&2 || true
    fail 'The workflow did not succeed'
  fi
  # Nothing of the smoke repository may outlive the test.
  kill "${pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
  pids=()
}

# A real rootless build, which needs more than the contract allows: the file
# capabilities of the id mapping (so no no-new-privileges, and the SETUID and
# SETGID capabilities in the bounding set) and the unconfined seccomp, AppArmor
# and /proc settings BuildKit documents for containers. The platform's pod must
# grant the same; see the README.
cicd_build() {
  local ctx=$scratch/ctx out=$scratch/out.tar
  mkdir -p "$XDG_RUNTIME_DIR" "$ctx"
  chmod 0700 "$XDG_RUNTIME_DIR"
  # A static binary of the image is the base-less image's only content, so the
  # RUN step executes without a base image to pull.
  cp "$(command -v rootlessctl)" "$ctx/tool"
  printf 'smoke-content\n' >"$ctx/data.txt"
  cat >"$ctx/Dockerfile" <<'EOF'
FROM scratch
COPY tool data.txt /
RUN ["/tool", "--help"]
EOF
  start rootlesskit buildkitd --oci-worker-snapshotter=native --oci-worker-no-process-sandbox \
    --root "$HOME/buildkit" >"$scratch/buildkitd.log" 2>&1
  wait_for 60 buildctl debug workers || { cat "$scratch/buildkitd.log" >&2; fail 'BuildKit did not start'; }
  buildctl build --frontend dockerfile.v0 --local context="$ctx" --local dockerfile="$ctx" \
    --output "type=oci,dest=$out" >"$scratch/build.log" 2>&1 || { cat "$scratch/build.log" >&2; fail 'The rootless build failed'; }
  tar -tf "$out" >"$scratch/layout" && grep -qx index.json "$scratch/layout"
  [[ $(tar -xOf "$out" index.json | jq '.manifests | length') == 1 ]]
  # The RUN step really executes: one that exits non-zero fails the build.
  printf 'FROM scratch\nCOPY tool /\nRUN ["/tool", "--no-such-flag"]\n' >"$ctx/failing.Dockerfile"
  if buildctl build --frontend dockerfile.v0 --local context="$ctx" --local dockerfile="$ctx" \
    --opt filename=failing.Dockerfile --output "type=oci,dest=$scratch/failing.tar" >/dev/null 2>&1; then
    fail 'A failing RUN step did not fail the build'
  fi
}

# ----------------------------------------------------------------------------
iac() {
  [[ $(tofu version | sed -n 1p) == 'OpenTofu v1.13.1' ]]
  has 'ansible [core 2.21.5]' ansible --version
  [[ $(python3 -c 'import sys; print(sys.prefix)') == /opt/ansible ]]
  has 'pip 26.2.1 ' pip --version
  python3 -c 'import boto3, botocore, kubernetes, jmespath, pytest'
  moto_server --help >/dev/null
  completes tofu
  local collections
  collections=$(ansible-galaxy collection list 2>/dev/null)
  for collection in ansible.posix community.general community.docker kubernetes.core amazon.aws; do
    grep -q "^$collection " <<<"$collections" || fail "Ansible collection $collection missing"
  done
  python_licences /opt/ansible/bin/python3
  python_licences /opt/moto/bin/python3

  # OpenTofu with its built-in provider only: no registry is reachable.
  local tf=$scratch/tofu
  mkdir -p "$tf"
  cat >"$tf/main.tf" <<'EOF'
variable "name" {
  type    = string
  default = "smoke"
}

resource "terraform_data" "greeting" {
  input = "hello-${var.name}"
}

output "greeting" {
  value = terraform_data.greeting.output
}
EOF
  cat >"$tf/main.tftest.hcl" <<'EOF'
run "greets" {
  command = apply
  assert {
    condition     = output.greeting == "hello-smoke"
    error_message = "unexpected greeting"
  }
}
EOF
  (
    cd "$tf"
    tofu fmt -check >/dev/null
    tofu init -input=false >/dev/null
    tofu validate >/dev/null
    tofu apply -auto-approve -input=false >/dev/null
    [[ $(tofu output -raw greeting) == hello-smoke ]]
    tofu test >/dev/null
  )

  # Ansible runs a playbook on localhost, and a second run changes nothing.
  local play=$scratch/ansible
  mkdir -p "$play"
  cat >"$play/site.yml" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.copy:
        content: "configured\n"
        dest: $play/result.txt
        mode: "0640"
EOF
  (cd "$play" && ansible-playbook site.yml >"$scratch/recap.txt") && grep -q 'changed=1' "$scratch/recap.txt"
  (cd "$play" && ansible-playbook site.yml >"$scratch/recap.txt") && grep -q 'changed=0' "$scratch/recap.txt"
  [[ $(<"$play/result.txt") == configured ]]

  # Moto answers the AWS API on the loopback interface, to boto3 and to the
  # amazon.aws collection: a bucket made by one is seen by the other.
  local endpoint=http://127.0.0.1:5000
  # Moto does not check credentials: these dummy values are not real keys.
  export AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing AWS_DEFAULT_REGION=eu-west-3
  start moto_server -H 127.0.0.1 -p 5000 >"$scratch/moto.log" 2>&1
  wait_for 60 curl -fs "$endpoint/moto-api/" || { cat "$scratch/moto.log" >&2; fail 'Moto did not start'; }
  python3 - "$endpoint" <<'PY'
import sys, boto3
s3 = boto3.client("s3", endpoint_url=sys.argv[1])
s3.create_bucket(Bucket="smoke-bucket", CreateBucketConfiguration={"LocationConstraint": "eu-west-3"})
assert "smoke-bucket" in [b["Name"] for b in s3.list_buckets()["Buckets"]]
PY
  cat >"$play/aws.yml" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - amazon.aws.s3_bucket:
        name: smoke-bucket-two
        endpoint_url: $endpoint
        region: eu-west-3
    - amazon.aws.s3_object_info:
        bucket_name: smoke-bucket
        endpoint_url: $endpoint
        region: eu-west-3
EOF
  (cd "$play" && ansible-playbook aws.yml >"$scratch/recap.txt") && grep -q 'failed=0' "$scratch/recap.txt"
  python3 - "$endpoint" <<'PY'
import sys, boto3
s3 = boto3.client("s3", endpoint_url=sys.argv[1])
assert "smoke-bucket-two" in [b["Name"] for b in s3.list_buckets()["Buckets"]]
PY

  # The fixed runner for hidden tests: pytest writes the JUnit XML report.
  printf 'def test_sum():\n    assert 1 + 1 == 2\n' >"$scratch/test_sample.py"
  (cd "$scratch" && pytest -q -p no:cacheprovider --junitxml="$scratch/junit.xml" test_sample.py >/dev/null)
  junit_ok "$scratch/junit.xml"
}

# ----------------------------------------------------------------------------
mlops() {
  [[ $(python3 -c 'import sys; print(sys.prefix)') == /opt/venv ]]
  has 'pip 26.2.1 ' pip --version
  has 'Python 3.13' python3 --version
  has 'version 3.17.1' mlflow --version
  has '3.67.1' dvc --version
  python3 -c 'import numpy, pandas, scipy, sklearn, joblib, mlflow, pytest'
  python_licences /opt/venv/bin/python3
  # A session reaches no outside host: no telemetry, and DVC's cache is writable.
  [[ $MLFLOW_DISABLE_TELEMETRY == true && $DVC_NO_ANALYTICS == 1 && $DO_NOT_TRACK == 1 ]]
  # No GPU stack: nothing of CUDA is installed.
  if python3 -c 'import importlib.util as u, sys; sys.exit(0 if u.find_spec("nvidia") or u.find_spec("torch") else 1)'; then
    fail 'A GPU library is installed'
  fi
  local work=$scratch/mlops
  mkdir -p "$work"
  cd "$work"

  # Train a small model on CPU, track it on an MLflow server with a SQLite store,
  # and serve the logged model over HTTP.
  local server=http://127.0.0.1:5000 serve=http://127.0.0.1:5001
  start mlflow server --host 127.0.0.1 --port 5000 --backend-store-uri "sqlite:///$work/mlflow.db" \
    --default-artifact-root "$work/artifacts" >"$work/server.log" 2>&1
  wait_for 90 curl -fs "$server/health" || { cat "$work/server.log" >&2; fail 'The MLflow server did not start'; }
  MLFLOW_TRACKING_URI=$server python3 - "$work/model-uri" >/dev/null <<'PY'
import sys
import mlflow, mlflow.sklearn
from sklearn.datasets import load_iris
from sklearn.linear_model import LogisticRegression
X, y = load_iris(return_X_y=True)
mlflow.set_experiment("smoke")
with mlflow.start_run() as run:
    model = LogisticRegression(max_iter=200).fit(X, y)
    mlflow.log_metric("accuracy", model.score(X, y))
    info = mlflow.sklearn.log_model(model, name="model", input_example=X[:2])
with open(sys.argv[1], "w") as destination:
    destination.write(info.model_uri)
PY
  local uri
  uri=$(<"$work/model-uri")
  [[ $uri == models:/* ]]
  start env MLFLOW_TRACKING_URI=$server mlflow models serve -m "$uri" --env-manager local --host 127.0.0.1 --port 5001 \
    >"$work/serve.log" 2>&1
  wait_for 90 curl -fs "$serve/ping" || { cat "$work/serve.log" >&2; fail 'The model server did not start'; }
  [[ $(curl -fsS -H 'Content-Type: application/json' \
    -d '{"inputs": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.0, 5.2, 2.3]]}' "$serve/invocations" | jq -c '.predictions') == '[0,2]' ]]
  kill "${pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
  pids=()

  # Data versioning: DVC tracks a file and reruns a stage only when it changed.
  git init -q
  dvc init -q
  printf 'a,b\n1,2\n' >data.csv
  dvc add -q data.csv
  grep -q '^outs:' data.csv.dvc
  dvc stage add -q -n count -d data.csv -o count.txt 'wc -l < data.csv > count.txt'
  dvc repro >/dev/null
  [[ $(tr -d ' ' <count.txt) == 2 ]]
  [[ $(dvc status) == *'Data and pipelines are up to date.'* ]]

  printf 'def test_sum():\n    assert 1 + 1 == 2\n' >test_sample.py
  pytest -q -p no:cacheprovider --junitxml="$work/junit.xml" test_sample.py >/dev/null
  junit_ok "$work/junit.xml"
}

# ----------------------------------------------------------------------------
web() {
  [[ $(node --version) == v26.12.0 ]]
  npm --version
  [[ $(code-server --version | sed -n 1p) == 4.141.0* ]]
  [[ $(playwright --version) == 'Version 1.64.1' ]]
  completes npm
  node_licences /opt/web-tools/node_modules
  [[ $PLAYWRIGHT_BROWSERS_PATH == /opt/playwright ]]
  local work=$scratch/web base=http://127.0.0.1:5173
  mkdir -p "$work"
  cd "$work"

  # A page served from the loopback interface, tested in a real browser by the
  # fixed runner for hidden tests, which writes a JUnit XML report.
  cat >server.js <<'EOF'
const http = require('http');
http.createServer((req, res) => {
  if (req.url === '/api/greeting') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ greeting: 'hello' }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<title>smoke</title><button onclick="document.querySelector(\'h1\').textContent = \'clicked\'">Go</button><h1>ready</h1>');
}).listen(5173, '127.0.0.1');
EOF
  start node server.js
  wait_for 20 curl -fs "$base/"
  cat >playwright.config.js <<EOF
module.exports = {
  testDir: '.',
  reporter: [['junit', { outputFile: 'junit.xml' }]],
  use: { baseURL: '$base' },
};
EOF
  cat >page.spec.js <<'EOF'
const { test, expect } = require('@playwright/test');
test('the page responds to a click', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle('smoke');
  await page.getByRole('button', { name: 'Go' }).click();
  await expect(page.getByRole('heading')).toHaveText('clicked');
});
test('the API answers', async ({ request }) => {
  const response = await request.get('/api/greeting');
  expect(await response.json()).toEqual({ greeting: 'hello' });
});
EOF
  playwright test >"$work/playwright.log" 2>&1 || { cat "$work/playwright.log" >&2; fail 'Playwright tests failed'; }
  junit_ok junit.xml
  [[ $(jq -n --rawfile xml junit.xml '$xml | contains("failures=\"0\"")') == true ]]

  # Node's own runner writes JUnit XML too.
  cat >node.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert');
test('sum', () => assert.strictEqual(1 + 1, 2));
EOF
  node --test --test-reporter=junit --test-reporter-destination=node-junit.xml node.test.js >/dev/null
  junit_ok node-junit.xml

  # code-server starts on request, never by itself.
  local editor=http://127.0.0.1:18080
  start code-server --bind-addr 127.0.0.1:18080 --auth none --user-data-dir "$work/cs-data" \
    --extensions-dir "$work/cs-extensions" "$work" >"$work/code-server.log" 2>&1
  wait_for 60 curl -fs "$editor/healthz" || { cat "$work/code-server.log" >&2; fail 'code-server did not start'; }
}

mobile() {
  web
  [[ $(expo --version) == 58.* ]]
  create-expo-app --version >/dev/null
  expo-doctor --help >/dev/null
  node_licences /opt/mobile-tools/node_modules
  [[ $EXPO_NO_TELEMETRY == 1 && $EXPO_OFFLINE == 1 ]]
}

case "$tier" in
  cicd) cicd ;;
  cicd-build) cicd_build ;;
  iac) iac ;;
  mlops) mlops ;;
  web) web ;;
  mobile) mobile ;;
  *) exit 2 ;;
esac
echo "lab-project smoke passed: $tier"
