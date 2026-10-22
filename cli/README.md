# lab-cli

The vCluster and Helm command-line tools the MyLabSkills lab worker uses to
create and manage lab environments. They run in the lab worker, not in a lab,
and the image holds only the two binaries at its root:

| Path | Tool |
| --- | --- |
| `/vcluster` | vCluster CLI 0.37.2, built from upstream commit `5d9d428`, with the v0.37.2 chart embedded |
| `/helm` | Helm 3.22.0, built from upstream commit `144ca65` |

## Why rebuild

The upstream release binaries were compiled with Go releases that predate
security fixes. Both tools are rebuilt from their exact upstream sources with
Go 1.26.10, and their vendored `golang.org/x/net` (and vCluster's
`klauspost/compress`) are raised to fixed versions. Each binary is checked
against a pinned per-architecture SHA-256 at build time, so the build is
reproducible: any change to the toolchain, sources or flags fails until the
checksums in `Dockerfile` and `smoke.sh` are updated together.

The base images are deliberately not on Dependabot: a new Go image changes the
binaries' checksums, so upgrade the toolchain by hand with the checksums.

## CI and publishing

CI builds the image on native AMD64 and ARM64 runners, extracts both binaries
and runs `smoke.sh` on them. Pull requests build without publishing. A push to
`main` publishes `ghcr.io/epr-consulting/lab-cli:<full-commit-sha>` as a
multi-platform image. Consumers pin the manifest digest, never a tag.

```sh
docker build --target cli -t cli-test cli
id=$(docker create cli-test /vcluster)
docker cp "$id:/vcluster" ./vcluster && docker cp "$id:/helm" ./helm && docker rm "$id"
sh cli/smoke.sh .
```
