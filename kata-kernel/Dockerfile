# syntax=docker/dockerfile:1
# Tools only: an upstream Kata guest kernel with the features required by the
# AWS nested-virtualization qualification. This is not a runtime acceptance.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev libelf-dev dwarves python3 xz-utils \
    cpio kmod curl ca-certificates git pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /source
COPY pins.env mls.config build.sh Dockerfile ./
RUN --mount=type=cache,target=/var/cache/mls-kernel ./build.sh

FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
COPY --from=build /out/ /usr/share/mls-kata-kernel/
COPY smoke.sh /usr/local/bin/kernel-smoke
ENTRYPOINT ["/usr/bin/bash", "/usr/local/bin/kernel-smoke"]
