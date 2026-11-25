# Kata guest kernel artifacts

Kata 4.3.1's debug guest configuration plus AppArmor, BPF/Falco and Cilium
network features, built from checksum-pinned Linux 6.18.56 and the exact upstream
Kata commit/patches. Loadable modules and their matching inventory are included
for guest administration. All of this is tooling; no lab content or grading is
present.

The build uses this repository's pinned Ubuntu builder and native AMD64/ARM64
jobs. It runs upstream's config/patch setup, adds the small `mls.config` fragment,
requires every requested option to survive Kconfig, builds the kernel/modules,
and records actual compiler/package versions and every output hash. Build time,
user and host are fixed. Ubuntu build packages follow the existing repository's
APT practice; source pins and the toolchain receipt do not promise identical
bytes after a compiler-package update.

```sh
docker buildx build --load --tag kata-kernel-test:native kata-kernel
docker run --rm --network none --cap-drop ALL --read-only kata-kernel-test:native
bash kata-kernel/package.sh kata-kernel-test:native /new/output/directory
```

PRs build and check both architectures. Main publishes versioned public GitHub
Release assets under `kata-kernel-<full-source-commit>`, with binary archive
checksums, complete corresponding Linux/Kata source archives and the custom
build recipe. The image is a local/CI build vehicle; runtime nodes download the
small checksum-pinned archive. This avoids a new registry credential or a public
package-visibility setup. A rerun verifies matching existing release assets and never overwrites them.

The binary archive contains `kernel`, `kernel.release`, architecture, `.config`
(named `config`), System.map, matching modules, toolchain receipt, source recipe,
licenses and file checksums. An installer must verify the outer archive hash
and extracted file hashes before selecting the kernel. Do not follow `latest`
or an unverified tag. Guest `/lib/modules` must match the reported kernel
release, without mounting the host's modules into the guest.

**Not yet a runtime qualification.** Native compilation/configuration checks do
not establish KVM boot, enforcement, Falco events, Docker/kubeadm/Cilium behavior,
node-cluster timing, cleanup or cross-session isolation. AWS staging initially
qualifies Intel only; publishing an ARM64 artifact does not enable an ARM64 Kata
pool. The fixed control hosts are never rebooted into this guest kernel.

Linux keeps its GPL-2.0 license and exceptions in the included corresponding
sources/license files; the custom build recipe follows this repository's
Apache-2.0 license. Full corresponding source assets travel with each release.
