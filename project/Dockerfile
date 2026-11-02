# syntax=docker/dockerfile:1
# lab-project: the toolchains of MyLabSkills project labs, one target per track.
# Tools only: no lab content, answer or grading logic goes into this file.
#
# The learner's shell files come from the control image's directory, so the
# prompt, completion and history contract of a terminal stay in one place:
#   docker buildx build --build-context shell=control --target <track> project
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS debian

FROM debian AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash bash-completion ca-certificates curl git jq less make nano openssh-client procps tini vim \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system init.defaultBranch main \
    && groupadd --gid 1000 student \
    && useradd --uid 1000 --gid 1000 --home-dir /tmp/student --shell /bin/bash student
COPY --from=shell vimrc.local /etc/vim/vimrc.local
# Interactive bash loads bash-completion and keeps the learner's command history
# in a bounded file in /tmp, as in lab-control.
COPY --from=shell history.bash shell.bash inputrc /etc/mylabskills/
RUN printf '%s\n' '' \
    '. /usr/share/bash-completion/bash_completion' \
    '. /etc/mylabskills/history.bash' \
    '. /etc/mylabskills/shell.bash' >> /etc/bash.bashrc
# The same security contract as lab-control: only /tmp is writable, so tool
# state lives under /tmp/student. Telemetry and update checks are off, since a
# session reaches no outside host.
ENV HOME=/tmp/student XDG_CONFIG_HOME=/tmp/student/.config XDG_CACHE_HOME=/tmp/student/.cache \
    XDG_DATA_HOME=/tmp/student/.local/share TERM=xterm-256color \
    LANG=C.UTF-8 COLORTERM=truecolor INPUTRC=/etc/mylabskills/inputrc \
    DO_NOT_TRACK=1
WORKDIR /tmp
LABEL org.opencontainers.image.source="https://github.com/epr-consulting/lab-images"
COPY --chmod=0755 smoke.sh /usr/local/bin/project-smoke
USER 1000:1000
CMD ["sleep", "infinity"]

FROM debian AS downloads
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY download.py /download.py
ARG TARGETARCH

# Python tiers: a venv per tool set, installed from a hash-locked requirements
# file. The build tools come first, from their own lock, because a few
# dependencies ship only as pure-Python source and build without isolation.
FROM debian AS python
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
COPY locks/build.txt /locks/build.txt

FROM python AS ansible-venv
COPY locks/ansible.txt /locks/ansible.txt
# include-system-site-packages makes the learner's `pip install --user` visible
# in the read-only venv.
RUN python3 -m venv --system-site-packages /opt/ansible \
    && /opt/ansible/bin/pip install --no-cache-dir --no-deps --require-hashes -r /locks/build.txt \
    && /opt/ansible/bin/pip install --no-cache-dir --no-deps --require-hashes --no-build-isolation -r /locks/ansible.txt \
    && /opt/ansible/bin/pip check

FROM python AS moto-venv
COPY locks/moto.txt /locks/moto.txt
RUN python3 -m venv /opt/moto \
    && /opt/moto/bin/pip install --no-cache-dir --no-deps --require-hashes -r /locks/build.txt \
    && /opt/moto/bin/pip install --no-cache-dir --no-deps --require-hashes --no-build-isolation -r /locks/moto.txt \
    && /opt/moto/bin/pip check

FROM python AS mlops-venv
COPY locks/mlops.txt /locks/mlops.txt
RUN python3 -m venv --system-site-packages /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --no-deps --require-hashes -r /locks/build.txt \
    && /opt/venv/bin/pip install --no-cache-dir --no-deps --require-hashes --no-build-isolation -r /locks/mlops.txt \
    && /opt/venv/bin/pip check

# CI/CD: Gitea with its packages (container) registry, the Gitea runner, a
# rootless BuildKit and the Argo CD client.
FROM downloads AS cicd-downloads
RUN python3 /download.py cicd "$TARGETARCH" /out
FROM base AS cicd
USER root
# Rootless BuildKit maps ids with newuidmap and newgidmap, over the id range of
# BuildKit's own rootless image. They get their privilege from file capabilities,
# as in that image: a setuid-root newuidmap is refused by some kernels in an
# unprivileged container. Neither works under no-new-privileges (see the README).
RUN apt-get update && apt-get install -y --no-install-recommends libcap2-bin pigz uidmap xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && echo student:100000:65536 > /etc/subuid && echo student:100000:65536 > /etc/subgid \
    && chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap \
    && setcap cap_setuid=ep /usr/bin/newuidmap && setcap cap_setgid=ep /usr/bin/newgidmap
COPY --from=cicd-downloads /out/ /usr/local/bin/
# The tools write their own bash completions, generated at build time with no
# network. A tmpfs over /tmp keeps what a tool writes under HOME out of the layer.
RUN --network=none --mount=type=tmpfs,target=/tmp set -e; \
    for tool in argocd gitea-runner; do \
      "$tool" completion bash >"/usr/share/bash-completion/completions/$tool"; \
    done
# BuildKit applies its rootless defaults only when $USER names a non-root user.
ENV USER=student GITEA_WORK_DIR=/tmp/student/gitea XDG_RUNTIME_DIR=/tmp/student/run \
    BUILDKIT_HOST=unix:///tmp/student/run/buildkit/buildkitd.sock
USER 1000:1000

# IaC: OpenTofu, Ansible with its collections, and Moto's AWS API server.
FROM downloads AS iac-downloads
RUN python3 /download.py iac "$TARGETARCH" /out
FROM base AS iac
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=iac-downloads /out/tofu /usr/local/bin/tofu
COPY --from=ansible-venv /opt/ansible/ /opt/ansible/
COPY --from=moto-venv /opt/moto/ /opt/moto/
RUN ln -s /opt/moto/bin/moto_server /usr/local/bin/moto_server \
    && printf '%s\n' 'complete -C /usr/local/bin/tofu tofu' >/usr/share/bash-completion/completions/tofu
# Ansible's python is the learner's python3: it has boto3 and kubernetes for the
# amazon.aws and kubernetes.core collections, and pytest for tests.
ENV PATH=/opt/ansible/bin:$PATH VIRTUAL_ENV=/opt/ansible PIP_USER=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1
USER 1000:1000

# MLOps: MLflow, DVC and CPU-only training libraries.
FROM base AS mlops
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=mlops-venv /opt/venv/ /opt/venv/
ENV PATH=/opt/venv/bin:$PATH VIRTUAL_ENV=/opt/venv PIP_USER=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 DVC_NO_ANALYTICS=1 DVC_SITE_CACHE_DIR=/tmp/student/.cache/dvc-site \
    MLFLOW_DISABLE_TELEMETRY=true
USER 1000:1000

# Web: Node.js, Playwright with a pinned headless Chromium, and code-server.
FROM downloads AS web-downloads
RUN python3 /download.py web "$TARGETARCH" /out
FROM base AS web
USER root
# The libraries Chrome for Testing's headless shell links against (its deb.deps).
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-liberation libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 \
    libcups2t64 libdbus-1-3 libexpat1 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 \
    libudev1 libvulkan1 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
    libxkbcommon0 libxrandr2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=web-downloads /out/node/bin/ /usr/local/bin/
COPY --from=web-downloads /out/node/lib/ /usr/local/lib/
COPY --from=web-downloads /out/code-server/ /opt/code-server/
COPY --from=web-downloads /out/chromium_headless_shell-1248/ /opt/playwright/chromium_headless_shell-1248/
COPY locks/web/ /opt/web-tools/
RUN ln -s /opt/code-server/bin/code-server /usr/local/bin/code-server \
    && npm ci --prefix /opt/web-tools --ignore-scripts --omit=peer --no-audit --no-fund \
    && ln -s /opt/web-tools/node_modules/.bin/playwright /usr/local/bin/playwright
RUN --network=none --mount=type=tmpfs,target=/tmp \
    npm completion >/usr/share/bash-completion/completions/npm
COPY code-server.yaml /etc/mylabskills/code-server.yaml
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    NODE_PATH=/opt/web-tools/node_modules CODE_SERVER_CONFIG=/etc/mylabskills/code-server.yaml \
    npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
USER 1000:1000

# Mobile: the web tier plus Expo's command-line tools.
FROM web AS mobile
USER root
COPY locks/mobile/ /opt/mobile-tools/
RUN npm ci --prefix /opt/mobile-tools --ignore-scripts --omit=peer --no-audit --no-fund \
    && for tool in expo create-expo-app expo-doctor; do \
         ln -s "/opt/mobile-tools/node_modules/.bin/$tool" "/usr/local/bin/$tool"; \
       done
ENV EXPO_NO_TELEMETRY=1 EXPO_OFFLINE=1
USER 1000:1000
