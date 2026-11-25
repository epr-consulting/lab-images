#!/usr/bin/env bash
set -euo pipefail
cd /usr/share/mls-kata-kernel
sha256sum --check --status checksums.sha256
test "$(cat kernel.release)" = '6.18.56-mls-kata'
case $(uname -m) in
  x86_64) test "$(cat architecture)" = amd64 ;;
  aarch64) test "$(cat architecture)" = arm64 ;;
  *) exit 1 ;;
esac
while IFS= read -r line; do
  case "$line" in CONFIG_*=*) grep --fixed-strings --line-regexp --quiet "$line" config ;; esac
done < source/mls.config
test -s "modules/lib/modules/$(cat kernel.release)/modules.builtin"
test -s source/KERNEL-COPYING
printf 'Kernel sources, requested config, module inventory and native artifact hashes verified.\n'
