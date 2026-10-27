# syntax=docker/dockerfile:1
FROM docker:29-cli@sha256:eccaacfeed644c7de222ff047483568cb988dde95476fbaaf10ea2d04921bb66 AS docker-tools
FROM golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 AS go-tools
FROM node:26-trixie-slim@sha256:36793bcbb160a6a16cede1e62b93f84e26b78a972a8a4c0b879c1c12f22761ec AS node-tools
FROM rust:1.99.1-slim-trixie@sha256:1a939748a7cbab172de91a014e3804a97af1394a8c844faa67fce9401c4e40fb AS rust-tools

FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl openssl vim-tiny git procps iproute2 iputils-ping \
    dnsutils netcat-openbsd less jq tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 student \
    && useradd --uid 1000 --gid 1000 --home-dir /tmp/student --shell /bin/bash student
RUN ln -s /usr/bin/vim.tiny /usr/local/bin/vim
# Interactive bash keeps the learner's command history in a bounded file in /tmp.
COPY history.bash /etc/mylabskills/history.bash
RUN printf '\n. /etc/mylabskills/history.bash\n' >> /etc/bash.bashrc
# Backend mounts only /tmp writable. Shells/tools must not try to modify /root.
ENV HOME=/tmp/student XDG_CONFIG_HOME=/tmp/student/.config XDG_CACHE_HOME=/tmp/student/.cache \
    XDG_DATA_HOME=/tmp/student/.local/share TERM=xterm-256color
WORKDIR /tmp
LABEL org.opencontainers.image.source="https://github.com/epr-consulting/lab-images"
COPY smoke.sh /usr/local/bin/control-smoke
USER 1000:1000
CMD ["sleep", "infinity"]

FROM base AS downloads
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY download.py /download.py
ARG TARGETARCH

FROM downloads AS kubernetes-downloads
RUN python3 /download.py k8s "$TARGETARCH" /out
FROM base AS k8s
COPY --from=kubernetes-downloads /out/ /usr/local/bin/

FROM downloads AS agent-downloads
RUN python3 /download.py agent "$TARGETARCH" /out
FROM base AS agent
COPY --from=agent-downloads /out/ /usr/local/bin/

FROM base AS docker
COPY --from=docker-tools /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-tools /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

FROM base AS linux
USER root
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv util-linux \
    && rm -rf /var/lib/apt/lists/*
USER 1000:1000

FROM downloads AS editor-downloads
RUN python3 /download.py dev "$TARGETARCH" /out
FROM base AS dev
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*
COPY --from=go-tools /usr/local/go/ /usr/local/go/
COPY --from=node-tools /usr/local/bin/node /usr/local/bin/node
COPY --from=node-tools /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
COPY --from=rust-tools /usr/local/cargo/ /opt/cargo/
COPY --from=rust-tools /usr/local/rustup/ /opt/rustup/
COPY --from=editor-downloads /out/ /opt/code-server/
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s /opt/code-server/bin/code-server /usr/local/bin/code-server
ENV PATH=/opt/cargo/bin:/usr/local/go/bin:$PATH RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/tmp/student/.cargo GOPATH=/tmp/student/go GOCACHE=/tmp/student/.cache/go-build \
    GOTOOLCHAIN=local PYTHONDONTWRITEBYTECODE=1
USER 1000:1000
