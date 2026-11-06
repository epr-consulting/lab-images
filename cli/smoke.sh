#!/bin/sh
# Checks the two binaries extracted from a lab-cli image: the pinned checksum
# for this architecture and the versions they report.
#   cli/smoke.sh <directory with vcluster and helm>
set -eu
dir=${1:?Pass the directory holding the extracted vcluster and helm}
case $(uname -m) in
  x86_64)
    vcluster=37556b9a3cc1e93c2a8fb6341d829c43d9bb835ee79d2234c5ba8f9e44462df5
    helm=7742eaa4836c89a420b481002b45567005b2de76fbd318b5c0bed8ddb67a9c92 ;;
  aarch64|arm64)
    vcluster=1c3e24f9ecf9e0f1fa1903bd97ef5345be746d0823643a0e2a3411b8ec78be30
    helm=6b40fff48a685c0eddfd2031dd5d15fcf7735d72b9904d9224bc290fd2e33364 ;;
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
