# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

ARG MISE_VERSION=v2026.11.0
ARG MISE_SHASUMS256=f664a2badead97a27b9555e71d14a9660bedb7f8ff311c0ebcb4f9ca418cc1fe
ARG RUSTUP_VERSION=1.29.3
ARG RUSTUP_SHA256_ARM64=9f608c142e0e38a78957d0661ba1dfaf0b6fb37184cfaa4b9a0aa57af6184282
ARG RUSTUP_SHA256_AMD64=b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55
ARG GIT_VERSION=2.56.0
ARG GIT_SHA256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3

FROM scratch AS mise-shasums
ARG MISE_VERSION
ARG MISE_SHASUMS256
ADD --checksum=sha256:${MISE_SHASUMS256} https://github.com/jdx/mise/releases/download/${MISE_VERSION}/SHASUMS256.txt /SHASUMS256.txt

FROM scratch AS mise-archive-arm64
ARG MISE_VERSION
ADD https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-arm64.tar.gz /mise.tar.gz

FROM scratch AS mise-archive-amd64
ARG MISE_VERSION
ADD https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-x64.tar.gz /mise.tar.gz

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
ARG MISE_VERSION
ARG TARGETARCH

USER 0
RUN --mount=type=cache,id=the-architect-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=the-architect-apt-lib,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        cmake \
        pkg-config

RUN --mount=type=bind,from=mise-shasums,source=/,target=/shasums \
    --mount=type=bind,from=mise-archive,source=/,target=/archive \
    case "${TARGETARCH}" in \
        arm64) asset="mise-${MISE_VERSION}-linux-arm64.tar.gz" ;; \
        amd64) asset="mise-${MISE_VERSION}-linux-x64.tar.gz" ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && awk -v name="./${asset}" '$2 == name { print $1 "  /archive/mise.tar.gz" }' /shasums/SHASUMS256.txt > /tmp/mise.sha256 \
    && test "$(wc -l < /tmp/mise.sha256)" -eq 1 \
    && sha256sum -c /tmp/mise.sha256 \
    && rm /tmp/mise.sha256 \
    && tar -xzf /archive/mise.tar.gz --no-same-owner --strip-components=2 -C /usr/local/bin mise/bin/mise \
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
    export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo \
    && mkdir -p "${CARGO_HOME}" \
    && /rustup/rustup-init -y --no-modify-path --default-toolchain none \
    && "${CARGO_HOME}/bin/rustup" set auto-self-update disable \
    && test -f "${RUSTUP_HOME}/settings.toml" \
    && test -d "${CARGO_HOME}/bin"

RUN export MISE_DATA_DIR=/usr/local/share/mise \
    && mise install --locked python uv \
    && mise install --locked \
    && rm -rf /sandbox/.cache /sandbox/.local /sandbox/.rustup /usr/local/share/mise/downloads \
    && chmod -R go-w /usr/local/cargo /usr/local/rustup /usr/local/share/mise /etc/mise \
    && install -d -o sandbox -g sandbox /sandbox/.cargo /sandbox/.cargo/registry /sandbox/.cargo/git \
    && for entry in registry git .package-cache .package-cache-mutate; do \
        ln -s "/sandbox/.cargo/${entry}" "/usr/local/cargo/${entry}"; \
    done

RUN offenders="$(find /usr/local/cargo /usr/local/rustup /usr/local/share/mise /etc/mise /usr/local/bin/mise /usr/bin/git /usr/lib/git-core \( ! -user root -o -perm /022 \) ! -type l -print)" \
    && if [ -n "${offenders}" ]; then printf '%s\n' "${offenders}" >&2; exit 1; fi

USER 1000
RUN for path in /usr/local/cargo/bin/cargo /usr/local/cargo/bin/rustc /usr/local/cargo/bin/rustup /usr/local/cargo/bin/injected /usr/local/cargo/injected; do \
        if (: > "${path}") 2>/dev/null; then printf 'writable by the sandbox user: %s\n' "${path}" >&2; exit 1; fi; \
    done \
    && if mv /usr/local/cargo/bin /usr/local/cargo/bin.moved 2>/dev/null; then echo "renamable by the sandbox user: /usr/local/cargo/bin" >&2; exit 1; fi \
    && test "$(mise exec -- printenv CARGO_HOME)" = /usr/local/cargo \
    && case "$(mise exec -- printenv PATH)" in /usr/local/cargo/bin:*) ;; *) echo "/usr/local/cargo/bin is not first on PATH" >&2; exit 1 ;; esac

RUN probe="$(mktemp -d)" \
    && mise exec -- cargo init --vcs none --name registry_probe "${probe}" \
    && mise exec -- cargo generate-lockfile --offline --manifest-path "${probe}/Cargo.toml" \
    && test -f "${probe}/Cargo.lock" \
    && test -e /sandbox/.cargo/.package-cache \
    && touch /usr/local/cargo/registry/probe /usr/local/cargo/git/probe \
    && rm -rf "${probe}" /usr/local/cargo/registry/probe /usr/local/cargo/git/probe /sandbox/.cargo/.package-cache /sandbox/.cargo/.package-cache-mutate

RUN mise exec -- mbx +1.99.1 --version \
    && mise exec -- cargo nextest --version \
    && rm -rf /sandbox/.cache /sandbox/.local
