# lab-linux

The machine of a Linux basic lab (epr-consulting/lab-images#15): the backend's
`container` driver (epr-consulting/backend#467) starts one Kubernetes Pod per
session from this image, and the learner's web terminal execs `bash` in it.
[lab-control](../control/README.md) is the terminal pod of the other labs; this
image is the environment itself, so the learner works as root on it. The
Dockerfile has one target, `basic`:

| Target | Tools |
| --- | --- |
| `basic` | bash 5.2 with bash-completion, vim 9.1 (full; `vi` is the same vim) and nano 7.2, less, man-db with the pages of these tools and `manpages`; coreutils, findutils, grep, sed, gawk, diffutils, file, jq; tar, gzip, xz, zip, unzip, rsync; ps, top and friends (procps), killall, fuser, pstree (psmisc), util-linux, e2fsprogs; useradd, usermod, groupadd, chpasswd, chage and passwd (passwd, login), adduser, sudo 1.9; getfacl, setfacl (acl), getfattr, setfattr (attr); cron 3.0, logrotate 3.21; ip, ss (iproute2), ping, dig, nslookup, host (bind9-dnsutils), curl, OpenSSH client; ca-certificates, locales (`C.UTF-8` is the default, `locale-gen` works), tzdata; tini |

It is Ubuntu 24.04 with those packages and nothing else: no systemd, no build
toolchain, no sshd and no Docker. `dnsutils` is a transitional package, so the
image installs what it installs, `bind9-dnsutils`. About 260 MB uncompressed.
Most of that is vim's runtime and Python library (about 60 MB), ICU for `dig`
(36 MB), `locales` (17 MB) and the man pages (12 MB).

## Pins

The base is `ubuntu:24.04` pinned by multi-architecture digest (the 24.04.5 build
of 2026-10-24). Nothing is downloaded, so there is no checksum to pin: every tool
is an Ubuntu package, which takes the archive's current security updates at
build time, and the published image digest fixes the resulting contents.
Dependabot proposes base image updates weekly, once a release is 7 days old, on
the 24.04 LTS line; the next LTS is moved by hand.

## CI and publishing

CI builds and smoke-tests the image on native AMD64 and ARM64 runners. Pull
requests build without publishing. A push to `main` publishes
`ghcr.io/epr-consulting/lab-linux:basic-<full-commit-sha>` as a multi-platform
image. Deployments use the manifest digest, never a tag.

## Contract

The Pod starts `tini -- sleep infinity`, which is also the image's entrypoint and
command, and the terminal execs `bash` in it. The Pod runs the learner as:

- **root in a user namespace** (`hostUsers: false`): UID 0 in the Pod is an
  unprivileged user on the node. The image makes no other user; Ubuntu's own
  `ubuntu` (UID 1000) is removed, so a lab can create users freely;
- **unprivileged, with the container runtime's default capabilities** and never
  `SYS_ADMIN`. The tools need five: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID` and
  `SETGID` (`useradd`, `su`, `sudo`, `cron` and `chown` work with just those).
  `ping` also needs `NET_RAW`, which its file capability asks for;
- **no network** beyond the Pod, so nothing in the image needs one at run time;
- **a writable root filesystem**, with home in `/root`. The platform writes
  workspace files into `/tmp/student/workspace`, as for lab-control
  (epr-consulting/backend#226), and `~/workspace` links there.

The image has no `VOLUME`, no `EXPOSE` and no lab content. Every image must pass
`linux-smoke` under that contract, run as the Pod's command starts it. CI runs it
twice, and so can you: under Docker's defaults (which lack `SYS_ADMIN`), and under
the five capabilities alone, where the test skips `ping`:

```sh
docker buildx build --build-context shell=control --target basic -t linux-test:basic linux
docker run --rm --network none linux-test:basic linux-smoke
docker run --rm --network none --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE \
  --cap-add FOWNER --cap-add SETUID --cap-add SETGID linux-test:basic linux-smoke
```

`--build-context shell=control` supplies `control/history.bash`, so the history
contract stays in one place, as in [lab-project](../project/README.md). Neither
run uses `--userns`: user-namespace remapping is a Docker daemon setting, and the
Pod's `hostUsers: false` changes who root is on the node, not what the image
contains.

### What differs from lab-control's contract

lab-control's contract is that of a locked-down terminal for a student, and a
learner who is root on their own machine does not fit it:

| lab-control | lab-linux |
| --- | --- |
| UID/GID 1000, `HOME=/tmp/student` | root, `HOME=/root` |
| All capabilities dropped | the runtime's defaults without `SYS_ADMIN` |
| `no-new-privileges` | not set: `sudo` for a non-root user runs through setuid, so a Pod with `allowPrivilegeEscalation: false` cannot use it (the smoke test skips `sudo` when `no_new_privs` is set) |
| Read-only root, only `/tmp` writable | writable root: the learner edits `/etc` and installs files, and the session ends with the Pod |
| `control-smoke <tier>` | `linux-smoke` |
| The runner of hidden tests and an execute-only `bash` | neither: grading brings its own read-only static busybox, and root reads any file whatever its mode, so mode 0711 would protect nothing |
| The shell files `shell.bash`, `kube.bash`, `inputrc` and `vimrc.local` | only the history hook; the prompt is Ubuntu's `root@<pod>:~#` |

## Shell history

As in lab-control, interactive bash appends each finished command to
`/tmp/.mylabskills_history` after a `#<epoch seconds>` line: only the commands,
never their output, nothing typed after a space, no history expansion (a `!` means
what it means under `/bin/sh`), and the file is cut to its last 32 KiB once it
passes 64 KiB. The backend reads the end of that file when the learner shares their
recent commands with an AI hint (epr-consulting/backend#370).

`/etc/bash.bashrc` loads the hook. Root's own `~/.bashrc` runs after it and sets
`HISTCONTROL`, `HISTSIZE` and `HISTFILESIZE` again (it would, for one, drop a
repeated command), so `/root/.bashrc` loads the hook once more at its end. A
login shell reads both too. The smoke test checks the settings, a repeated
command, a login shell and the size.

Only root's shell writes the file. A shell of another user, from `su alice`, cannot
write the file root made, so its commands are not recorded.

## Man pages

The Ubuntu image drops man pages and diverts `man` to a notice that the system is
minimized. The build lifts the one dpkg exclude for `/usr/share/man`, installs
man-db and `manpages`, reinstalls the base packages whose commands labs use (bash,
coreutils, util-linux, tar, apt, dpkg and the others in the Dockerfile) so their
pages exist, removes the diversion and the `unminimize` package. The smoke test
checks that `man` finds the pages of the tools a lab names.

## What this image does not do

- **It runs no daemon.** There is no systemd, and nothing starts `cron` or any
  other service: run `cron` (it forks) when a lab needs it. A Linux lab that needs
  systemd or Docker has its own image (lab-images#15).
- **It cannot do what the Pod has no capability for**: `mount`, `hostname NAME`,
  `sysctl -w`, `ip addr add` and loading modules fail, and no firewall tool
  (`iptables`, `nft`) is installed.
- **It has no network use at run time.** `apt` has no package lists (the build
  removes them) and would have no network to read them from.
- **It carries no lab content**: no users, files, questions, answers or grading
  logic. The smoke test fails if `/home`, `/srv`, `/opt`, `/mnt`, `/media`,
  `/workspace` or `/var/tmp` hold anything, `/tmp` holds more than the empty
  workspace, or `/root` holds more than the shell's two dotfiles and the link to
  the workspace, or the image has a user beyond the system ones.
