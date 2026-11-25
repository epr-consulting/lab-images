#!/usr/bin/env bash
set -euo pipefail
cd /source
# shellcheck source=kata-kernel/pins.env
source pins.env
case $(uname -m) in
  x86_64) arch=x86_64; oci_arch=amd64 ;;
  aarch64) arch=aarch64; oci_arch=arm64 ;;
  *) echo 'Unsupported native kernel architecture' >&2; exit 1 ;;
esac
mkdir -p /build /out/source /out/modules /var/cache/mls-kernel
cd /var/cache/mls-kernel
fetch() {
  local file=$1 checksum=$2 url=$3
  if ! test -f "$file" || ! echo "$checksum  $file" | sha256sum --check --status; then
    curl --fail --location --silent --show-error --retry 3 --proto '=https' --output "$file.part" "$url"
    echo "$checksum  $file.part" | sha256sum --check --status
    mv "$file.part" "$file"
  fi
}
fetch kata.tar.gz "$KATA_SOURCE_SHA256" "https://codeload.github.com/kata-containers/kata-containers/tar.gz/$KATA_COMMIT"
fetch "linux-$KERNEL_VERSION.tar.xz" "$KERNEL_SOURCE_SHA256" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
mkdir /build/kata
tar -xzf kata.tar.gz --strip-components=1 -C /build/kata
cp "linux-$KERNEL_VERSION.tar.xz" /build/
printf '%s  linux-%s.tar.xz\n' "$KERNEL_SOURCE_SHA256" "$KERNEL_VERSION" > "/build/linux-$KERNEL_VERSION.tar.xz.sha256"
cd /build
export KERNEL_DEBUG_ENABLED=yes
export KBUILD_BUILD_TIMESTAMP='2026-11-25 00:00:00 UTC'
export KBUILD_BUILD_USER=mylabskills KBUILD_BUILD_HOST=kernel-builder
# Explicit version uses the pinned, preverified archive, not upstream's moving
# versions/checksum lookup. This executes the original config/patch recipe.
./kata/tools/packaging/kernel/build-kernel.sh -v "$KERNEL_VERSION" -a "$arch" -k /build/linux setup
cd /build/linux
./scripts/kconfig/merge_config.sh -m .config /source/mls.config
make olddefconfig
# Requested options must survive Kconfig dependencies; a successful build alone
# is not proof they made it into the kernel.
while IFS= read -r line; do
  case "$line" in CONFIG_*=*) grep --fixed-strings --line-regexp --quiet "$line" .config ;; esac
done < /source/mls.config
make -j "$(nproc)"
release=$(make --silent kernelrelease)
make INSTALL_MOD_PATH=/out/modules INSTALL_MOD_STRIP=1 modules_install
# Build/source links name builder paths and are not useful in a guest.
rm -f "/out/modules/lib/modules/$release/build" "/out/modules/lib/modules/$release/source"
case "$oci_arch" in
  amd64) cp arch/x86/boot/bzImage /out/kernel ;;
  arm64) cp arch/arm64/boot/Image /out/kernel ;;
esac
cp .config /out/config
cp System.map /out/System.map
printf '%s\n' "$release" > /out/kernel.release
printf '%s\n' "$oci_arch" > /out/architecture
# Complete corresponding upstream sources, patches and custom build recipe
# travel with the binary. Nothing depends on a promise to recover old sources.
cp /var/cache/mls-kernel/kata.tar.gz /out/source/
cp "/var/cache/mls-kernel/linux-$KERNEL_VERSION.tar.xz" /out/source/
cp /source/pins.env /source/mls.config /source/build.sh /source/Dockerfile /out/source/
cp COPYING /out/source/KERNEL-COPYING
cp -a LICENSES /out/source/KERNEL-LICENSES
{ gcc --version; ld --version; pahole --version; dpkg-query -W; } > /out/toolchain.txt
cd /out
find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
chmod -R a+rX /out
