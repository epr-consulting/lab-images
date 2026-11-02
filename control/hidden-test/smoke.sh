#!/bin/bash
# Smoke test of the hidden-test runner (epr-consulting/backend#486), run inside
# an image under the control pod's security contract (UID 1000, all
# capabilities dropped, read-only root, /tmp writable) by control-smoke and
# project-smoke. It checks what the platform relies on: the verdict is the
# runner's exit status, a test that is not the stored one never runs, the
# runner and the bash it starts are closed to another process of the user, the
# time limit is the runner's, and what a test started does not outlive it.
#
# The node must restrict ptrace (kernel.yama.ptrace_scope >= 1): the runner
# refuses to run otherwise, and so does this smoke test after checking that.
set -euo pipefail
runner=/usr/local/bin/mls-hidden-test
test_bash=/usr/local/libexec/mls-bash
scope_file=/proc/sys/kernel/yama/ptrace_scope
workspace=/tmp/student/workspace
scratch=$(mktemp -d /tmp/hidden-test-smoke.XXXXXX)
# The runner makes the workspace when it is missing; the image holds none.
trap 'rm -rf "$scratch" "$workspace"' EXIT

# Both are root's and run by everyone but read by no one: a process that cannot
# read the file it runs is not dumpable, so nothing of the learner's reads its
# descriptors or memory. Static: the runner needs no library of the image.
for file in "$runner" "$test_bash"; do
  [[ -x $file && ! -r $file && $(stat -c '%a %U' "$file") == '711 root' ]]
done
if touch /usr/local/bin/should-be-readonly 2>/dev/null; then
  echo 'The runner can be replaced: the root filesystem is writable' >&2
  exit 1
fi

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# The runner's exit status for the test $1 stored under the digest of $2, with
# the time limit $3 (60 seconds by default).
status() {
  local status=0
  printf '%s' "$1" | "$runner" "$(sha "$2")" "$workspace" "${3:-60}" 2>/dev/null || status=$?
  echo "$status"
}
# Waits until the process $1 is gone.
gone() {
  local state
  for _ in $(seq 50); do
    state=$(sed 's/^.*) //; s/ .*//' "/proc/$1/stat" 2>/dev/null || true)
    [[ -z $state || $state == Z ]] && return 0
    sleep 0.1
  done
  return 1
}

# It runs only where a process cannot trace its ancestors.
if [[ ! -r $scope_file || $(< "$scope_file") == 0 ]]; then
  [[ $(status $'exit 0\n' $'exit 0\n') == 126 ]]
  echo 'The node does not restrict ptrace: the runner refuses, as it must.' >&2
  echo 'Run this smoke test on a node with kernel.yama.ptrace_scope >= 1.' >&2
  exit 1
fi

# Only a test that exits 0 passes, and one that is the stored one. A test
# cannot choose the codes the platform reads: any other end is 1.
[[ $(status $'exit 0\n' $'exit 0\n') == 0 ]]
[[ $(status $'exit 3\n' $'exit 3\n') == 1 ]]
[[ $(status $'if then\n' $'if then\n') == 1 ]]
for code in 124 125 126 137 143; do
  [[ $(status "exit $code"$'\n' "exit $code"$'\n') == 1 ]]
done
[[ $(status $'exit 0\n' $'exit 1\n') == 125 ]]
[[ $(status $'exit 1\nexit 0\n' $'exit 1\n') == 125 ]]
rc=0
printf 'exit 0\n\0x' | "$runner" "$(sha $'exit 0\n')" "$workspace" 60 2>/dev/null || rc=$?
[[ $rc == 125 ]]
big=$(head -c 102401 /dev/zero | tr '\0' '#')
[[ $(status "$big" "$big") == 125 ]]
[[ $(status $'exit 0\n' $'exit 0\n') == 0 && -d $workspace ]]
# Misuse is never a pass.
for args in "" "$(sha $'exit 0\n') $workspace" "$(sha $'exit 0\n') $workspace 0" "$(sha $'exit 0\n') $workspace x" \
  "not-a-digest $workspace 60" "$(sha $'exit 0\n') relative 60"; do
  rc=0
  # shellcheck disable=SC2086
  printf 'exit 0\n' | "$runner" $args 2>/dev/null || rc=$?
  [[ $rc == 125 ]]
done

# The test runs in the workspace, with no input and no descriptor of the runner,
# and the code it starts reads neither the test nor the descriptors, nor the
# memory, of the bash that runs it or of the runner above it.
cat > "$scratch/guard.sh" <<'TEST'
#!/bin/bash
# @TOKEN@
if read -r -t 1 line; then exit 1; fi
[ "$(pwd -P)" = /tmp/student/workspace ] || exit 1
[ ! -e /proc/$$/fd/3 ] || exit 1
bash -c '
  if ls /proc/$PPID/fd >/dev/null 2>&1; then exit 12; fi
  if cat /proc/$PPID/mem >/dev/null 2>&1; then exit 13; fi
  if ls /proc/$(sed "s/^.*) [A-Za-z] //; s/ .*//" /proc/$PPID/stat)/fd >/dev/null 2>&1; then exit 14; fi
' || exit 1
if grep -a -D skip -d skip -l '@PATTERN@' /proc/[0-9]*/fd/* /proc/[0-9]*/cmdline /proc/[0-9]*/environ 2>/dev/null | grep -q .; then
  exit 1
fi
exit 0
TEST
# A word only this test has, made now so that no file of the image holds it. The
# pattern that finds it is spelled so that its own command line does not match.
token="canary-$$-$RANDOM$RANDOM"
guard=$(< "$scratch/guard.sh")
guard=${guard//@TOKEN@/$token}
guard=${guard//@PATTERN@/${token%?}[${token: -1}]}$'\n'
[[ $(status "$guard" "$guard") == 0 ]]

# What a test started is killed with it.
pidfile="$scratch/pid"
body="sleep 301 &
echo \$! > $pidfile
exit 0
"
[[ $(status "$body" "$body") == 0 ]]
gone "$(< "$pidfile")"

# The time limit is the runner's: it kills the test's group and exits 124.
body="sleep 301 &
echo \$! > $pidfile
sleep 301
"
rm -f "$pidfile"
[[ $(status "$body" "$body" 1) == 124 ]]
gone "$(< "$pidfile")"

# Another process of the learner's cannot open the runner's descriptors, nor its
# memory, whether the runner runs or is stopped, and what it writes into the
# runner's input is not the stored test.
failing=$'exit 1\n'
( sleep 1; printf 'exit 0\n' ) | "$runner" "$(sha "$failing")" "$workspace" 60 2>/dev/null &
helper=$!
# (Until the runner has started, the process is still the shell that forked it.)
closed=false
for _ in $(seq 100); do
  if ! ( : >"/proc/$helper/fd/0" ) 2>/dev/null; then closed=true; break; fi
  sleep 0.01
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
body="sleep 301 &
echo \$! > $pidfile
sleep 301
"
rm -f "$pidfile"
printf '%s' "$body" | "$runner" "$(sha "$body")" "$workspace" 60 2>/dev/null &
helper=$!
for _ in $(seq 100); do [[ -s $pidfile ]] && break; sleep 0.1; done
[[ -s $pidfile ]]
kill -TERM "$helper"
status=0
wait "$helper" || status=$?
[[ $status == 143 ]]
gone "$(< "$pidfile")"

# When the runner is killed, the bash it started goes with it.
body="echo \$\$ > $pidfile
sleep 301
"
rm -f "$pidfile"
printf '%s' "$body" | "$runner" "$(sha "$body")" "$workspace" 60 2>/dev/null &
helper=$!
for _ in $(seq 100); do [[ -s $pidfile ]] && break; sleep 0.1; done
[[ -s $pidfile ]]
kill -KILL "$helper"
wait "$helper" 2>/dev/null || true
gone "$(< "$pidfile")"
