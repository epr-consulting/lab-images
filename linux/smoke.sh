#!/bin/bash
# Smoke test of the lab-linux image, run inside it as the learner's machine runs:
#   linux-smoke
# The learner is root in a user namespace, with Docker's default capabilities
# (never SYS_ADMIN) and no network beyond the Pod. CI runs this test twice,
# under those defaults and under the five capabilities useradd, su, sudo and cron
# need, with `--network none` each time. The tests use generic sample data only:
# no lab content.
set -euo pipefail

scratch=
trap '[[ -z $scratch ]] || rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
random() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# Succeeds when a capability (by number) is in the bounding set.
has_capability() { (( (0x$(awk '/^CapBnd:/ {print $2}' /proc/self/status) >> $1) & 1 )); }

# --- The contract -----------------------------------------------------------
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || fail 'The base is not Ubuntu 24.04'
[[ $(id -u) == 0 && $(id -g) == 0 ]] || fail 'The learner is not root'
[[ $HOME == /root && $PWD == /root && $LANG == C.UTF-8 ]] || fail "Unexpected HOME, directory or LANG: $HOME $PWD $LANG"
# The image starts under tini, as the Pod's command does ("tini -- sleep infinity").
[[ $(cat /proc/1/comm) == tini ]] || fail "PID 1 is $(cat /proc/1/comm), not tini"
# The Pod never gets SYS_ADMIN (capability 21).
if has_capability 21; then
  fail 'CAP_SYS_ADMIN is in the bounding set'
fi
# The machine starts with no lab content and no human users: the places a lab's
# files would go are empty, and only the shell's own dotfiles are in root's home.
for dir in /home /srv /opt /mnt /media /workspace /tmp /var/tmp; do
  [[ ! -e $dir || -z $(ls -A "$dir") ]] || fail "$dir is not empty"
done
[[ $(ls -A /root | tr '\n' ' ') == '.bashrc .profile ' ]] || fail "/root holds $(ls -A /root | tr '\n' ' ')"
[[ -z $(awk -F: '$3 >= 1000 && $3 < 65534' /etc/passwd) ]] || fail 'The image has a human user'
# No systemd, no build toolchain: a lab that needs them has its own image.
for absent in systemctl systemd gcc cc make; do
  if command -v "$absent" >/dev/null; then
    fail "$absent is installed"
  fi
done
scratch=$(mktemp -d "${TMPDIR:-/tmp}/linux-smoke.XXXXXX")
# tini reaps what its children leave behind.
bash -c '(sleep 0.2 &)'
sleep 0.6
if ps -eo stat= | grep -q '^Z'; then
  fail 'A zombie process was not reaped'
fi

# --- The tools ---------------------------------------------------------------
for tool in tini bash ls cat install find xargs grep sed awk gawk less vim vi nano \
  tar gzip xz zip unzip ps top pgrep pkill free killall fuser pstree ip ss ping dig nslookup host \
  useradd usermod userdel groupadd chpasswd chage passwd su sudo visudo \
  getfacl setfacl getfattr setfattr file man cron crontab logrotate rsync ssh scp ssh-keygen \
  jq curl update-ca-certificates locale-gen mount lsblk; do
  command -v "$tool" >/dev/null || fail "$tool is missing"
done
bash --version >/dev/null
vim --version >/dev/null
nano --version >/dev/null
# Without a network, sudo cannot resolve the host name and says so on stderr.
sudo --version >/dev/null 2>&1
ssh -V 2>/dev/null
dig -v 2>/dev/null
[[ $(readlink -f "$(command -v awk)") == */gawk ]]

# --- Working with files --------------------------------------------------------
# The platform writes workspace files with install from stdin and reads them back
# with a bounded head -c, never through a shell, in the learner's home
# (epr-consulting/backend#226): for this image, the machine is the workstation.
printf 'smoke-file\n' | install -D -T -m 0640 /dev/stdin "$HOME/workspace/a/b.txt"
[[ $(stat -c %a "$HOME/workspace/a/b.txt") == 640 ]]
[[ $(head -c 65537 "$HOME/workspace/a/b.txt") == smoke-file ]]
rm -rf "$HOME/workspace"
cd "$scratch"
mkdir src
printf 'one two\nthree four\n' > src/words
[[ $(grep -c t src/words) == 2 && $(sed -n 2p src/words) == 'three four' ]]
[[ $(awk '{print $2}' src/words | tr '\n' ' ') == 'two four ' ]]
[[ $(find src -type f | wc -l) == 1 && $(find src -name 'w*' -print) == src/words ]]
tar -czf a.tgz src && gzip -t a.tgz && [[ $(tar -tzf a.tgz | tail -1) == src/words ]]
tar -cJf a.txz src && xz -t a.txz
zip -qr a.zip src && unzip -tq a.zip >/dev/null && [[ $(unzip -p a.zip src/words | head -1) == 'one two' ]]
gzip -k src/words && [[ $(zcat src/words.gz | wc -l) == 2 ]]
rsync -a src/ dst/ && diff -r src dst
[[ $(file -b --mime-type src/words) == text/plain ]]
[[ $(echo '{"a":[1,2]}' | jq -c '.a | map(. * 2)') == '[2,4]' ]]
# curl reads a file: URL without any network.
[[ $(curl -s file:///etc/os-release | head -1) == 'PRETTY_NAME="Ubuntu 24.04'* ]]
test -s /etc/ssl/certs/ca-certificates.crt
ssh-keygen -q -t ed25519 -N '' -f key && ssh-keygen -l -f key.pub >/dev/null
# Access control lists and extended attributes, on the machine's own filesystem.
touch acl-file
setfacl -m u:nobody:r acl-file && getfacl -p acl-file | grep -qx 'user:nobody:r--'
setfattr -n user.smoke -v 1 acl-file && [[ $(getfattr -n user.smoke --only-values acl-file) == 1 ]]
# logrotate rotates a log it is told about.
printf 'line\n' > app.log
printf '%s\n' "$scratch/app.log {" '  rotate 2' '  missingok' '}' > logrotate.conf
logrotate -f -s logrotate.state logrotate.conf
[[ -e app.log.1 ]]
# cron: the daemon starts and a crontab can be installed, listed and removed.
cron
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x cron >/dev/null && break
  sleep 0.2
done
pgrep -x cron >/dev/null
printf '%s\n' '* * * * * true' | crontab -
[[ $(crontab -l) == '* * * * * true' ]]
crontab -r
pkill -x cron

# --- Users, groups and sudo ----------------------------------------------------
user=smoke-user
groupadd smoke-group
useradd -m -s /bin/bash -G smoke-group "$user"
printf '%s:%s\n' "$user" "$(random)" | chpasswd
[[ $(getent passwd "$user" | cut -d: -f1) == "$user" && -d /home/$user ]]
[[ $(id -Gn "$user") == *smoke-group* ]]
usermod -aG sudo "$user"
[[ $(id -Gn "$user") == *sudo* ]]
passwd -S "$user" | grep -q "^$user P "
chage -l "$user" >/dev/null
[[ $(su -s /bin/bash "$user" -c 'id -un') == "$user" ]]
# sudo needs setuid programs to work, so a Pod that sets allowPrivilegeEscalation
# to false (no_new_privs) cannot run it as a non-root user: README.
if [[ $(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status) == 0 ]]; then
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > /etc/sudoers.d/smoke
  chmod 0440 /etc/sudoers.d/smoke
  visudo -cf /etc/sudoers.d/smoke >/dev/null
  [[ $(su -s /bin/bash "$user" -c 'sudo -n id -u' 2>/dev/null) == 0 ]]
  rm -f /etc/sudoers.d/smoke
else
  echo 'sudo skipped: no_new_privs is set'
fi
userdel -r "$user" 2>/dev/null
groupdel smoke-group
[[ -z $(getent passwd "$user") ]]

# --- Processes and the network tools ----------------------------------------------
[[ $(pgrep -x tini) == 1 ]]
free >/dev/null
pstree -p 1 >/dev/null
# The default network of `docker run --network none` has loopback only. ping's file
# capability is CAP_NET_RAW (13), so with the five-capability run it cannot start.
ip -brief link show lo | grep -q '^lo '
ss -ltn >/dev/null
if has_capability 13; then
  ping -c 1 -W 1 127.0.0.1 >/dev/null
else
  echo 'ping skipped: CAP_NET_RAW is not in the bounding set'
fi

# --- Time, language and documentation --------------------------------------------
[[ $(locale charmap) == UTF-8 ]]
[[ $(locale -a) == *C.utf8* ]]
locale-gen en_US.UTF-8 >/dev/null
[[ $(locale -a) == *en_US.utf8* ]]
[[ $(TZ=Europe/Paris date -d '2026-07-01 12:00 UTC' +%H:%Z) == 14:CEST ]]
# The Ubuntu image drops man pages and diverts man; neither applies here.
for page in ls bash tar grep sed find useradd crontab apt dpkg mount; do
  man -w "$page" >/dev/null || fail "man has no page for $page"
done
man -w 5 passwd >/dev/null
man -w 7 signal >/dev/null
[[ $(MANPAGER=cat man ls | head -1) == LS\(1\)* ]]
[[ $(man -k crontab | wc -l) -ge 2 ]]
# Full vim with syntax and the usual backspace, vi as the same vim, and nano.
[[ $(vim --version) == *+syntax* ]]
[[ $(vi --version | head -1) == 'VIM - Vi IMproved'* ]]
printf 'a:\n\tb: 1\n' > smoke.yaml
vim --not-a-term -n -i NONE -c "redir! > vim.out" \
  -c 'echo &filetype &syntax exists("g:syntax_on") &backspace' -c 'redir END' -c 'qa!' \
  smoke.yaml </dev/null >/dev/null 2>&1
[[ $(tr -d '\n' < vim.out) == 'yaml yaml 1 indent,eol,start' ]]
# bash-completion loads a command's completion the way it does on the first Tab.
# Its loader returns 124 after it loaded one, which tells readline to try again.
completes() {
  bash -ic 'for command; do _completion_loader "$command"; complete -p "$command" || exit 1; done' _ "$@" >/dev/null 2>&1
}
completes tar useradd ssh

# --- The learner's shell history ----------------------------------------------------
# Each finished command after its time, never its output, not a command typed after
# a space, "!" kept literal, the file under 64 KiB, and the same in a login shell.
# Root's ~/.bashrc sets its own history options after /etc/bash.bashrc, so the
# settings are read back from a shell that loaded both.
history=/tmp/.mylabskills_history
[[ $(bash -ic 'echo "$HISTFILE $HISTCONTROL $HISTSIZE $HISTFILESIZE $HISTTIMEFORMAT"' 2>/dev/null) == "$history ignorespace 1000 1000 %F %T " ]]
rm -f "$history"
printf '%s\n' 'echo smoke-command' ' echo smoke-hidden' 'printf "%s-%s\n" smoke output' 'echo "bang!"' \
  'echo smoke-twice' 'echo smoke-twice' | bash -i >/dev/null 2>&1
grep -qxF 'echo smoke-command' "$history"
grep -qxF 'printf "%s-%s\n" smoke output' "$history"
grep -qxF 'echo "bang!"' "$history"
[[ $(grep -cxF 'echo smoke-twice' "$history") == 2 ]]
grep -qx '#[0-9]*' "$history"
if grep -q -e smoke-hidden -e smoke-output "$history"; then
  fail 'Shell history holds a space-prefixed command or command output'
fi
printf '%s\n' 'echo smoke-login' | bash -il >/dev/null 2>&1
grep -qxF 'echo smoke-login' "$history"
seq -f "echo %0300g" 1 500 | bash -i >/dev/null 2>&1
(( $(stat -c %s "$history") <= 65536 ))
grep -qx 'echo 0*500' "$history"
rm -f "$history"

echo 'lab-linux smoke test passed'
