#!/bin/bash
# Smoke test of the hidden-test runner (epr-consulting/backend#486), run inside
# an image under the control pod's security contract (UID 1000, all
# capabilities dropped, read-only root, /tmp writable) by control-smoke and
# project-smoke. It checks what the platform relies on: the verdict is the
# runner's exit status, a test that is not the stored one never runs, the
# runner's descriptors are closed to another process of its user, and what a
# test started does not outlive it.
set -euo pipefail
runner=/usr/local/bin/mls-hidden-test
workspace=/tmp/student/workspace
scratch=$(mktemp -d /tmp/hidden-test-smoke.XXXXXX)
# The runner makes the workspace when it is missing; the image holds none.
trap 'rm -rf "$scratch" "$workspace"' EXIT

[[ -x $runner && $(stat -c %a "$runner") == 755 ]]
# Static: it needs no library of the image it runs in.
[[ $(ldd "$runner" 2>&1 || true) == *'not a dynamic executable'* ]]
if touch /usr/local/bin/should-be-readonly 2>/dev/null; then
  echo 'The runner can be replaced: the root filesystem is writable' >&2
  exit 1
fi

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# The runner's exit status for the test $1 stored under the digest of $2.
status() {
  local status=0
  printf '%s' "$1" | "$runner" "$(sha "$2")" "$workspace" || status=$?
  echo "$status"
}

# Only a test that exits 0 passes, and one that is the stored one.
[[ $(status $'exit 0\n' $'exit 0\n') == 0 ]]
[[ $(status $'exit 3\n' $'exit 3\n') == 1 ]]
[[ $(status $'if then\n' $'if then\n') == 1 ]]
[[ $(status $'exit 125\n' $'exit 125\n') == 1 ]]
[[ $(status $'exit 0\n' $'exit 1\n') == 125 ]]
[[ $(status $'exit 1\nexit 0\n' $'exit 1\n') == 125 ]]
rc=0
printf 'exit 0\n\0x' | "$runner" "$(sha $'exit 0\n')" "$workspace" || rc=$?
[[ $rc == 125 ]]
big=$(head -c 102401 /dev/zero | tr '\0' '#')
[[ $(status "$big" "$big") == 125 ]]
[[ $(status $'exit 0\n' $'exit 0\n') == 0 && -d $workspace ]]

# The test runs in the workspace with its input and output on /dev/null, and
# the file it was read from takes no write by any descriptor.
cat > "$scratch/guard.sh" <<'TEST'
#!/bin/bash
[ "$(readlink /proc/$$/fd/0)" = /dev/null ] || exit 1
[ "$(readlink /proc/$$/fd/1)" = /dev/null ] || exit 1
[ "$(pwd -P)" = /tmp/student/workspace ] || exit 1
if echo evil >> /proc/self/fd/3 2>/dev/null; then exit 1; fi
if : > /proc/self/fd/3 2>/dev/null; then exit 1; fi
if exec 4<> /proc/self/fd/3 2>/dev/null && echo evil >&4 2>/dev/null; then exit 1; fi
if truncate -s 0 /proc/self/fd/3 2>/dev/null; then exit 1; fi
exit 0
TEST
guard=$(< "$scratch/guard.sh")$'\n'
[[ $(status "$guard" "$guard") == 0 ]]

# What a test started is killed with it.
pidfile="$scratch/pid"
body="sleep 301 &
echo \$! > $pidfile
exit 0
"
[[ $(status "$body" "$body") == 0 ]]
pid=$(< "$pidfile")
for _ in $(seq 50); do
  state=$(sed 's/^.*) //; s/ .*//' "/proc/$pid/stat" 2>/dev/null || true)
  [[ -z $state || $state == Z ]] && break
  sleep 0.1
done
[[ -z $state || $state == Z ]]

# Another process of the learner's cannot open the runner's descriptors, nor its
# memory, whether the runner runs or is stopped, and what it writes into the
# runner's input is not the stored test.
failing=$'exit 1\n'
( sleep 1; printf 'exit 0\n' ) | "$runner" "$(sha "$failing")" "$workspace" &
helper=$!
closed=false
for _ in $(seq 100); do
  if ! ( : >"/proc/$helper/fd/0" ) 2>/dev/null; then closed=true; break; fi
  sleep 0.02
done
$closed
kill -STOP "$helper"
if ( : >"/proc/$helper/fd/0" ) 2>/dev/null || ( : >"/proc/$helper/mem" ) 2>/dev/null; then
  echo 'A process of the runner'"'"'s user opened its descriptors or memory' >&2
  exit 1
fi
kill -CONT "$helper"
status=0
wait "$helper" || status=$?
[[ $status == 125 ]]

# On SIGTERM it kills the test's group and exits 143.
long=$'sleep 301 &\necho $! > '"$pidfile"$'\nsleep 301\n'
rm -f "$pidfile"
printf '%s' "$long" | "$runner" "$(sha "$long")" "$workspace" &
helper=$!
for _ in $(seq 100); do [[ -s $pidfile ]] && break; sleep 0.1; done
[[ -s $pidfile ]]
kill -TERM "$helper"
status=0
wait "$helper" || status=$?
[[ $status == 143 ]]
pid=$(< "$pidfile")
for _ in $(seq 50); do
  state=$(sed 's/^.*) //; s/ .*//' "/proc/$pid/stat" 2>/dev/null || true)
  [[ -z $state || $state == Z ]] && break
  sleep 0.1
done
[[ -z $state || $state == Z ]]
