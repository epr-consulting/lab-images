#!/usr/bin/env bash
# Build a small, checked runtime archive. Full corresponding upstream sources
# are separate assets of the same public release, not a dependency of boot.
set -euo pipefail
image=${1:?image required}
output=${2:?new output directory required}
test ! -e "$output"
mkdir -p "$output"
output=$(cd "$output" && pwd)
stage=$(mktemp -d)
container=''
cleanup() {
  if test -n "$container"; then docker rm --force "$container" >/dev/null; fi
  rm -rf "$stage"
}
trap cleanup EXIT
container=$(docker create --network none --entrypoint /bin/true "$image")
docker cp "$container:/usr/share/mls-kata-kernel/." "$stage/"
cd "$stage"
sha256sum --check --status checksums.sha256
architecture=$(cat architecture)
case "$architecture" in amd64|arm64) ;; *) exit 1 ;; esac
test "$(cat kernel.release)" = '6.18.56-mls-kata'
# Full sources are still present in the tested build image and are published
# alongside these binary archives by the main-only release job.
rm source/kata.tar.gz source/linux-6.18.56.tar.xz checksums.sha256
find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
archive="kata-kernel-6.18.56-$architecture.tar.gz"
tar --sort=name --mtime='2026-11-25 00:00:00 UTC' --owner=0 --group=0 --numeric-owner -czf "$output/$archive" .
cd "$output"
sha256sum "$archive" > "$archive.sha256"
