# syntax=docker/dockerfile:1
# lab-cli: the vCluster and Helm CLIs the MyLabSkills lab worker uses to create
# and manage lab environments, rebuilt from their exact upstream sources with a
# patched Go toolchain. The image holds only the two binaries, at its root.
# Build context: this directory; no stage reads a file from it.

# The upstream v0.37.2 release CLI predates fixes now present in Loft's public
# source mirror. Build that CLI from the exact upstream security-update commit
# with a patched Go toolchain, and embed the exact v0.37.2 chart so the
# default-deny lab worker never downloads a chart at runtime.
FROM --platform=$BUILDPLATFORM golang:1.26.10-bookworm@sha256:fe3da92a5cb2881e4aa75e625cb0b7c50571632fb4cf340cbe53e6ccdcffdd51 AS vcluster-builder
ENV GOTOOLCHAIN=local GOMAXPROCS=4
ARG TARGETOS=linux
ARG TARGETARCH
ARG VCLUSTER_VERSION=0.37.2
ARG VCLUSTER_SOURCE_COMMIT=5d9d4284012e635f433edc8ea442799ca868d674
ARG VCLUSTER_SOURCE_SHA256=115b12724f7e68900903272b2e99757d981571242d5ed499902abfabec1ded86
ARG VCLUSTER_CHART_SHA256=0e3e1df3802a1199653930cfadcf52ba309ea7d5282a1a8541452bea8a9cf707
ARG CLI_X_NET_VERSION=v0.60.0
ARG CLI_COMPRESS_VERSION=v1.18.7
WORKDIR /src
RUN test "$TARGETOS" = "linux" && \
    case "$TARGETARCH" in amd64|arm64) ;; *) exit 1 ;; esac && \
    test "$VCLUSTER_VERSION" = "0.37.2" && \
    test "$VCLUSTER_SOURCE_COMMIT" = "5d9d4284012e635f433edc8ea442799ca868d674" && \
    test "$VCLUSTER_SOURCE_SHA256" = "115b12724f7e68900903272b2e99757d981571242d5ed499902abfabec1ded86" && \
    test "$VCLUSTER_CHART_SHA256" = "0e3e1df3802a1199653930cfadcf52ba309ea7d5282a1a8541452bea8a9cf707" && \
    curl -fL --retry 3 -o /tmp/vcluster-source.tar.gz \
      "https://codeload.github.com/loft-sh/vcluster/tar.gz/${VCLUSTER_SOURCE_COMMIT}" && \
    echo "$VCLUSTER_SOURCE_SHA256  /tmp/vcluster-source.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/vcluster-source.tar.gz --strip-components=1 && \
    rm /tmp/vcluster-source.tar.gz pkg/embed/chart/gitkeep.tgz && \
    curl -fL --retry 3 -o "pkg/embed/chart/vcluster-${VCLUSTER_VERSION}.tgz" \
      "https://charts.loft.sh/charts/vcluster-${VCLUSTER_VERSION}.tgz" && \
    echo "$VCLUSTER_CHART_SHA256  pkg/embed/chart/vcluster-${VCLUSTER_VERSION}.tgz" | sha256sum -c -
# Patch only the vendored HTTP/2 module. The mirror's test-only module graph
# includes private repositories; rebuilding that graph requires credentials.
# x/net v0.60.0 keeps the existing vendored x/* dependency versions and Go floor.
# Download outside that graph through Go's checksum database, then verify the
# exact module selected by the offline build. No private credential is needed.
RUN test "$CLI_X_NET_VERSION" = "v0.60.0" && \
    test "$(go list -mod=vendor -m golang.org/x/net)" = "golang.org/x/net v0.59.0" && \
    (cd /tmp && GOWORK=off go mod download "golang.org/x/net@${CLI_X_NET_VERSION}") && \
    go mod edit "-require=golang.org/x/net@${CLI_X_NET_VERSION}" && \
    sed -i "s|# golang.org/x/net v0.59.0|# golang.org/x/net ${CLI_X_NET_VERSION}|" vendor/modules.txt && \
    rm -rf vendor/golang.org/x/net && \
    cp -a "$(go env GOMODCACHE)/golang.org/x/net@${CLI_X_NET_VERSION}" vendor/golang.org/x/net && \
    test "$(go list -mod=vendor -m golang.org/x/net)" = "golang.org/x/net ${CLI_X_NET_VERSION}"
# Patch the vendored compression module the same way (CVE-2026-63209).
# v1.18.7 has no dependencies and keeps v1.18.5's Go floor, so the vendored
# graph and the `## explicit; go 1.24` marker stay valid.
RUN test "$CLI_COMPRESS_VERSION" = "v1.18.7" && \
    test "$(go list -mod=vendor -m github.com/klauspost/compress)" = "github.com/klauspost/compress v1.18.5" && \
    (cd /tmp && GOWORK=off go mod download "github.com/klauspost/compress@${CLI_COMPRESS_VERSION}") && \
    go mod edit "-require=github.com/klauspost/compress@${CLI_COMPRESS_VERSION}" && \
    sed -i "s|# github.com/klauspost/compress v1.18.5|# github.com/klauspost/compress ${CLI_COMPRESS_VERSION}|" vendor/modules.txt && \
    rm -rf vendor/github.com/klauspost/compress && \
    cp -a "$(go env GOMODCACHE)/github.com/klauspost/compress@${CLI_COMPRESS_VERSION}" vendor/github.com/klauspost/compress && \
    test "$(go list -mod=vendor -m github.com/klauspost/compress)" = "github.com/klauspost/compress ${CLI_COMPRESS_VERSION}"
RUN --network=none CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -buildvcs=false -trimpath -mod=vendor -tags embed_chart \
      -ldflags "-s -w -X main.version=${VCLUSTER_VERSION} -X github.com/loft-sh/vcluster/pkg/telemetry.SyncerVersion=${VCLUSTER_VERSION}" \
      -o /usr/local/bin/vcluster ./cmd/vclusterctl && \
    case "$TARGETARCH" in \
      amd64) VCLUSTER_BINARY_SHA256=0c4216866e00f89b9f9b2ecd10e104c6316a4ba085eaa25f33874030adb0374c ;; \
      arm64) VCLUSTER_BINARY_SHA256=b59d8697d06e635ab0059d9630679131eaba637f303d27099dc600f9d115c405 ;; \
    esac && \
    echo "$VCLUSTER_BINARY_SHA256  /usr/local/bin/vcluster" | sha256sum -c -

FROM --platform=$BUILDPLATFORM golang:1.26.10-bookworm@sha256:fe3da92a5cb2881e4aa75e625cb0b7c50571632fb4cf340cbe53e6ccdcffdd51 AS helm-builder
ENV GOTOOLCHAIN=local GOMAXPROCS=4
ARG TARGETOS=linux
ARG TARGETARCH
ARG HELM_VERSION=3.22.0
ARG CLI_X_NET_VERSION=v0.60.0
ARG HELM_SOURCE_COMMIT=144ca65f8501953fa8b41cd1d37c7223051c85b7
ARG HELM_SOURCE_SHA256=b418a3db1021d5ec9b4f906da1b0a97ce85fab319d89a7046842feef8e00eeba
WORKDIR /src
RUN test "$TARGETOS" = "linux" && \
    case "$TARGETARCH" in amd64|arm64) ;; *) exit 1 ;; esac && \
    test "$HELM_VERSION" = "3.22.0" && \
    test "$HELM_SOURCE_COMMIT" = "144ca65f8501953fa8b41cd1d37c7223051c85b7" && \
    test "$HELM_SOURCE_SHA256" = "b418a3db1021d5ec9b4f906da1b0a97ce85fab319d89a7046842feef8e00eeba" && \
    curl -fL --retry 3 -o /tmp/helm-source.tar.gz \
      "https://codeload.github.com/helm/helm/tar.gz/${HELM_SOURCE_COMMIT}" && \
    echo "$HELM_SOURCE_SHA256  /tmp/helm-source.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/helm-source.tar.gz --strip-components=1 && \
    rm /tmp/helm-source.tar.gz && \
    test "$CLI_X_NET_VERSION" = "v0.60.0" && \
    go get "golang.org/x/net@${CLI_X_NET_VERSION}" && \
    go mod download && go mod verify && \
    test "$(go list -mod=readonly -m golang.org/x/net)" = "golang.org/x/net ${CLI_X_NET_VERSION}"
# Match the release Makefile's Kubernetes 1.37 compatibility constants.
RUN --network=none CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -buildvcs=false -trimpath -mod=readonly \
      -ldflags "-s -w -X helm.sh/helm/v3/internal/version.version=v${HELM_VERSION} -X helm.sh/helm/v3/internal/version.gitCommit=${HELM_SOURCE_COMMIT} -X helm.sh/helm/v3/internal/version.gitTreeState=clean -X helm.sh/helm/v3/pkg/lint/rules.k8sVersionMajor=1 -X helm.sh/helm/v3/pkg/lint/rules.k8sVersionMinor=37 -X helm.sh/helm/v3/pkg/chartutil.k8sVersionMajor=1 -X helm.sh/helm/v3/pkg/chartutil.k8sVersionMinor=37" \
      -o /usr/local/bin/helm ./cmd/helm && \
    case "$TARGETARCH" in \
      amd64) HELM_BINARY_SHA256=7b6c0ae9b29c48ab2553b9477f92af6eebb2cbcaf37287a99c3772f9ae0ce8bf ;; \
      arm64) HELM_BINARY_SHA256=78eefeacd6222d1e4a8ce4723e6ab5d9b3625ef4ccf3e98ca0b2c7afbd503261 ;; \
    esac && \
    echo "$HELM_BINARY_SHA256  /usr/local/bin/helm" | sha256sum -c -

# The published image: the two binaries at its root.
FROM scratch AS cli
COPY --from=vcluster-builder /usr/local/bin/vcluster /vcluster
COPY --from=helm-builder /usr/local/bin/helm /helm

