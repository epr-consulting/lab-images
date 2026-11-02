#!/bin/sh
# Checks the two binaries extracted from a lab-cli image: the pinned checksum
# for this architecture and the versions they report.
#   cli/smoke.sh <directory with vcluster and helm>
set -eu
dir=${1:?Pass the directory holding the extracted vcluster and helm}
case $(uname -m) in
  x86_64)
    vcluster=fb37b896bb41129adccb1c409e53472db9703525ad4ba28ab4be66ecf5fe48ee
    helm=7b6c0ae9b29c48ab2553b9477f92af6eebb2cbcaf37287a99c3772f9ae0ce8bf ;;
  aarch64|arm64)
    vcluster=893cd7ec576224c815f0074b96b70e62372a9e9dd313b8d2aa441dea1b2be165
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
