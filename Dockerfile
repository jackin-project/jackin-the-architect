# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

ARG MISE_VERSION=2026.10.25
ARG MISE_SHA256_ARM64=a7d1e2add53441ff76e7e971e7a3fb15c117741836ce51c026f5fb7eebe7dbcf
ARG MISE_SHA256_AMD64=199966edaad1b208eb4c72955f1722dafb8fa799f575db720dea05aaa8216546
ARG RUSTUP_VERSION=1.29.2
ARG RUSTUP_SHA256_ARM64=a9c168dbea81a84671c6b7a5c1795cb0eb699020110d107ddfca427bd797e697
ARG RUSTUP_SHA256_AMD64=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4
ARG GIT_VERSION=2.56.0
ARG GIT_SHA256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3

FROM scratch AS mise-archive-arm64
ARG MISE_VERSION
ARG MISE_SHA256_ARM64
ADD --checksum=sha256:${MISE_SHA256_ARM64} https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-arm64.tar.gz /mise.tar.gz

FROM scratch AS mise-archive-amd64
ARG MISE_VERSION
ARG MISE_SHA256_AMD64
ADD --checksum=sha256:${MISE_SHA256_AMD64} https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64.tar.gz /mise.tar.gz

FROM mise-archive-${TARGETARCH} AS mise-archive

FROM scratch AS rustup-init-arm64
ARG RUSTUP_VERSION
ARG RUSTUP_SHA256_ARM64
ADD --checksum=sha256:${RUSTUP_SHA256_ARM64} --chmod=0755 https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/aarch64-unknown-linux-gnu/rustup-init /rustup-init

FROM scratch AS rustup-init-amd64
ARG RUSTUP_VERSION
ARG RUSTUP_SHA256_AMD64
ADD --checksum=sha256:${RUSTUP_SHA256_AMD64} --chmod=0755 https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init /rustup-init

FROM rustup-init-${TARGETARCH} AS rustup-init

FROM scratch AS git-source
ARG GIT_VERSION
ARG GIT_SHA256
ADD --checksum=sha256:${GIT_SHA256} https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz /git.tar.xz

FROM construct AS git-build
ARG GIT_VERSION

USER 0
RUN --mount=type=cache,id=the-architect-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=the-architect-apt-lib,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        gettext \
        libcurl4-gnutls-dev \
        zlib1g-dev

RUN --mount=type=bind,from=git-source,source=/,target=/source \
    tar -xJf /source/git.tar.xz -C /tmp \
    && make -C "/tmp/git-${GIT_VERSION}" -j"$(nproc)" prefix=/usr gitexecdir=lib/git-core NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 NO_EXPAT=1 NO_OPENSSL=1 NO_RUST=1 all \
    && make -C "/tmp/git-${GIT_VERSION}" prefix=/usr gitexecdir=lib/git-core NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 NO_EXPAT=1 NO_OPENSSL=1 NO_RUST=1 DESTDIR=/out install

FROM construct

ARG GIT_VERSION

USER 0
RUN --mount=type=cache,id=the-architect-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=the-architect-apt-lib,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        cmake \
        pkg-config

RUN --mount=type=bind,from=mise-archive,source=/,target=/archive \
    tar -xzf /archive/mise.tar.gz --no-same-owner --strip-components=2 -C /usr/local/bin mise/bin/mise \
    && mise --version

RUN rm -rf /usr/lib/git-core
COPY --from=git-build --chown=root:root /out/usr/ /usr/
RUN test "$(git --version)" = "git version ${GIT_VERSION}" \
    && test -x /usr/lib/git-core/git-remote-https \
    && ldd /usr/lib/git-core/git-remote-https > /tmp/ldd.txt \
    && ! grep -q "not found" /tmp/ldd.txt \
    && rm /tmp/ldd.txt

COPY --chown=root:root toolchain/mise.toml /etc/mise/config.toml
COPY --chown=root:root toolchain/mise.lock /etc/mise/mise.lock
COPY --chown=root:root toolchain/.mise/ /etc/mise/.mise/

RUN --mount=type=bind,from=rustup-init,source=/,target=/rustup \
    export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/sandbox/.cargo \
    && mkdir -p "${CARGO_HOME}" \
    && /rustup/rustup-init -y --no-modify-path --default-toolchain none \
    && "${CARGO_HOME}/bin/rustup" set auto-self-update disable \
    && test -f "${RUSTUP_HOME}/settings.toml" \
    && test -d "${CARGO_HOME}/bin"

RUN export MISE_DATA_DIR=/usr/local/share/mise \
    && mise install --locked python uv \
    && mise install --locked \
    && rm -rf /sandbox/.cache /sandbox/.local /sandbox/.rustup /usr/local/share/mise/downloads \
    && chown -R sandbox:sandbox /sandbox/.cargo

USER 1000
RUN mise exec -- mbx +1.99.1 --version \
    && mise exec -- cargo nextest --version \
    && rm -rf /sandbox/.cache /sandbox/.local
