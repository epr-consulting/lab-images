# syntax=docker/dockerfile:1
# lab-linux: the machine of a Linux basic lab (epr-consulting/lab-images#15), one
# Kubernetes Pod per session that the learner's terminal execs bash in. Tools
# only: no lab content, answer or grading logic goes into this file.
#
# The learner's history hook comes from the control image's directory, so the
# history contract of a terminal stays in one place:
#   docker buildx build --build-context shell=control --target basic linux
#
# Ubuntu 24.04.5 LTS, the build of 2026-10-24, pinned by multi-architecture digest.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 AS basic

# The Ubuntu image drops man pages, and a Linux admin looks things up with man.
# So lift that one dpkg exclude (documentation and translations stay out), install
# man-db and reinstall the base packages whose commands a lab uses, so their
# pages are there too. The image also diverts /usr/bin/man to a notice that the
# system is minimized; drop that diversion and unminimize, which no longer applies.
# Nothing else is installed: no systemd, no compiler. cron needs a sysusers tool
# and would take systemd itself, the first of its alternatives, so the standalone
# one is named. bind9-dnsutils is what the transitional dnsutils package installs
# (dig, nslookup, host). The install leaves an empty /root/.ssh behind; ssh makes
# it when a learner needs it.
RUN sed -i '\#^path-exclude=/usr/share/man/\*$#d' /etc/dpkg/dpkg.cfg.d/excludes \
    && ! grep -q /usr/share/man /etc/dpkg/dpkg.cfg.d/excludes \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --reinstall \
        tini bash bash-completion coreutils findutils grep sed gawk less vim nano \
        tar gzip xz-utils zip unzip \
        procps psmisc iproute2 iputils-ping bind9-dnsutils \
        passwd login sudo acl attr file man-db manpages systemd-standalone-sysusers cron logrotate rsync openssh-client \
        jq curl ca-certificates locales tzdata \
        util-linux mount bsdutils diffutils e2fsprogs hostname ncurses-bin sysvinit-utils debianutils apt dpkg \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/bin/man \
    && dpkg-divert --quiet --remove --rename /usr/bin/man \
    && DEBIAN_FRONTEND=noninteractive apt-get purge -y unminimize \
    && rm -rf /root/.ssh \
    && userdel --remove ubuntu

# Interactive bash loads bash-completion and keeps the learner's command history
# in a bounded file in /tmp, as in lab-control (epr-consulting/backend#370).
# Root's own ~/.bashrc runs after /etc/bash.bashrc and sets HISTCONTROL,
# HISTSIZE and HISTFILESIZE again, so the hook is loaded once more at its end.
COPY --from=shell history.bash /etc/mylabskills/history.bash
RUN printf '%s\n' '' \
    '. /usr/share/bash-completion/bash_completion' \
    '. /etc/mylabskills/history.bash' >> /etc/bash.bashrc \
    && printf '%s\n' '' \
    '# The platform reads the command history this hook writes; keep its settings.' \
    '. /etc/mylabskills/history.bash' >> /root/.bashrc

# A UTF-8 locale that needs no locale-gen, and a terminal type with colours, as in
# lab-control. The learner is root, so their home is /root.
ENV LANG=C.UTF-8 TERM=xterm-256color
WORKDIR /root
# The platform places and grades workspace files in /tmp/student/workspace, as in
# lab-control (epr-consulting/backend#226); root's ~/workspace is the same place.
RUN mkdir -p /tmp/student/workspace && ln -s /tmp/student/workspace /root/workspace
LABEL org.opencontainers.image.source="https://github.com/epr-consulting/lab-images"
COPY --chmod=0755 smoke.sh /usr/local/bin/linux-smoke
# The Pod's command is "tini -- sleep infinity"; the image starts the same way.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
