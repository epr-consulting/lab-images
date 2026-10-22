#!/bin/sh
# Checks the two binaries extracted from a lab-cli image: the pinned checksum
# for this architecture and the versions they report.
#   cli/smoke.sh <directory with vcluster and helm>
set -eu
dir=${1:?Pass the directory holding the extracted vcluster and helm}
case $(uname -m) in
  x86_64)
    vcluster=0c4216866e00f89b9f9b2ecd10e104c6316a4ba085eaa25f33874030adb0374c
    helm=7b6c0ae9b29c48ab2553b9477f92af6eebb2cbcaf37287a99c3772f9ae0ce8bf ;;
  aarch64|arm64)
    vcluster=b59d8697d06e635ab0059d9630679131eaba637f303d27099dc600f9d115c405
    helm=78eefeacd6222d1e4a8ce4723e6ab5d9b3625ef4ccf3e98ca0b2c7afbd503261 ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
echo "$vcluster  $dir/vcluster" | sha256sum -c -
echo "$helm  $dir/helm" | sha256sum -c -
# vCluster initializes a private cache even for --version.
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
test "$(HOME="$home" "$dir/vcluster" --version)" = "vcluster version 0.37.2"
test "$("$dir/helm" version --short | cut -d+ -f1)" = "v3.22.0"
echo "lab-cli smoke passed"
