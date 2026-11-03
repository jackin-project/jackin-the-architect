# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

ARG MISE_VERSION=2026.10.25
ARG MISE_SHA256_ARM64=a7d1e2add53441ff76e7e971e7a3fb15c117741836ce51c026f5fb7eebe7dbcf
ARG MISE_SHA256_AMD64=199966edaad1b208eb4c72955f1722dafb8fa799f575db720dea05aaa8216546
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

FROM scratch AS git-source
ARG GIT_VERSION
ARG GIT_SHA256
ADD --checksum=sha256:${GIT_SHA256} https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz /git.tar.xz

FROM construct AS git-build
ARG GIT_VERSION

USER 0
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        gettext \
        libcurl4-gnutls-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=git-source,source=/,target=/source \
    tar -xJf /source/git.tar.xz -C /tmp \
    && make -C "/tmp/git-${GIT_VERSION}" -j"$(nproc)" prefix=/usr gitexecdir=lib/git-core NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 NO_EXPAT=1 NO_OPENSSL=1 NO_RUST=1 all \
    && make -C "/tmp/git-${GIT_VERSION}" prefix=/usr gitexecdir=lib/git-core NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 NO_EXPAT=1 NO_OPENSSL=1 NO_RUST=1 DESTDIR=/out install

FROM construct

ARG GIT_VERSION

USER 0
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        cmake \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=mise-archive,source=/,target=/archive \
    tar -xzf /archive/mise.tar.gz --no-same-owner --strip-components=2 -C /usr/local/bin mise/bin/mise \
    && mise --version

COPY --from=git-build --chown=root:root /out/usr/ /usr/
RUN test "$(git --version)" = "git version ${GIT_VERSION}"

COPY --chown=root:root toolchain/mise.toml /etc/mise/config.toml

RUN mise install \
    && mise exec -- mbx +1.99.1 --version \
    && mise exec -- cargo nextest --version \
    && rm -rf /sandbox/.cache \
    && chown -R sandbox:sandbox /sandbox

USER 1000
