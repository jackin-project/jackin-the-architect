# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.37-trixie@sha256:67fc093e1dd9a021e2af66beebbeddbb4d676839dcd0a5371ce8a5d7b2cdcab4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG MISE_VERSION=2026.9.18
ARG MBX_VERSION=1.22.0
ARG CARGO_BINSTALL_VERSION=1.23.0
ARG CARGO_WATCH_VERSION=8.5.3
ARG LYCHEE_VERSION=0.24.2
ARG BOLTFFI_VERSION=0.30.1
ARG CARGO_FUZZ_VERSION=0.13.2
ARG CARGO_MUTANTS_VERSION=27.1.0
ARG TARGETARCH
ARG OPENTOFU_VERSION=1.12.6
ARG NODE_TOOLS_VERSION=24.21.0
ARG CARGO_BUILD_JOBS=4
ARG MISE_JOBS=1
# HEADROOM_VERSION.
ARG HEADROOM_VERSION=0.37.0
# UV_VERSION.
ARG UV_VERSION=0.12.15
# RTK_VERSION (aqua).
ARG RTK_VERSION=0.49.0

USER root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    openssl \
    pkg-config \
    cmake \
    xz-utils \
    xxd && \
    apt-get autoremove -y

USER agent

ENV PATH="/home/agent/.local/bin:/home/agent/.local/share/architect-node-tools/node_modules/.bin:/home/agent/.local/share/mise/shims:${PATH}"
ENV MISE_TRUSTED_CONFIG_PATHS=/workspace:/tmp/jackin-mise

COPY --chown=root:root jackin-toolchain/ /tmp/jackin-mise/

RUN set -eu; \
    mkdir -p "${HOME}/.local/bin"; \
    case "${TARGETARCH}" in \
        amd64) mise_arch=x64; mise_sha256=d24fe0bf7e613824ad99f7b8dac3f2b381a37b9f75f84dd250855217095a8de4 ;; \
        arm64) mise_arch=arm64; mise_sha256=2142433ae70decffc5fa24bd160e47931e33f55eb031d128beb97cbae634d168 ;; \
        *) echo "unsupported TARGETARCH for mise: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mise_archive="${HOME}/.local/bin/mise"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${mise_arch}" -o "${mise_archive}"; \
    printf '%s  %s\n' "${mise_sha256}" "${mise_archive}" | sha256sum --check --strict -; \
    chmod 0755 "${mise_archive}"; \
    "${mise_archive}" --version | grep -Fq "mise ${MISE_VERSION}"; \
    mkdir -p \
        "${HOME}/.cache/amp" \
        "${HOME}/.cache/mise" \
        "${HOME}/.cargo/bin" \
        "${HOME}/.cargo/registry" \
        "${HOME}/.cargo/git"

# Per-tool RUNs (caching).
RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    MISE_CARGO_BINSTALL_ONLY=1 mise install "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}"

RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    mise trust /tmp/jackin-mise/mise.toml && \
    mkdir -p "${HOME}/.config/mise" && \
    cp /tmp/jackin-mise/mise.toml "${HOME}/.config/mise/config.toml" && \
    : "Keep cargo-binstall pinned before installing Cargo-backed mise tools" && \
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise install -C /tmp/jackin-mise rust && \
    mise use -g --pin -C /tmp/jackin-mise rust && \
    mise use -g --pin -C /tmp/jackin-mise --tool-option mr_boxington=true rust "mr-boxington@${MBX_VERSION}"

# ARM64 lacks compatible binary assets for these two Cargo-backed Mise tools.
# MBX routes Cargo registry installs but does not cache their install sessions;
# BuildKit retains Cargo's target artifacts instead.
RUN --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    --mount=type=cache,target=/home/agent/.cache/cargo-target-${TARGETARCH},uid=1000 \
    set -eu; \
    case "${TARGETARCH}" in \
        amd64) ;; \
        arm64) \
            MISE_EXEC_AUTO_INSTALL=0 \
            MISE_CARGO_BINSTALL_ONLY=1 \
            CARGO_TARGET_DIR="/home/agent/.cache/cargo-target-${TARGETARCH}" \
                mise exec -- mbx install --locked \
                    --root "${HOME}/.local/share/mise/installs/cargo-fuzz/${CARGO_FUZZ_VERSION}" \
                    "cargo-fuzz@${CARGO_FUZZ_VERSION}"; \
            MISE_EXEC_AUTO_INSTALL=0 \
            MISE_CARGO_BINSTALL_ONLY=1 \
            CARGO_TARGET_DIR="/home/agent/.cache/cargo-target-${TARGETARCH}" \
                mise exec -- mbx install --locked \
                    --root "${HOME}/.local/share/mise/installs/cargo-mutants/${CARGO_MUTANTS_VERSION}" \
                    "cargo-mutants@${CARGO_MUTANTS_VERSION}"; \
            test -x "${HOME}/.local/share/mise/installs/cargo-fuzz/${CARGO_FUZZ_VERSION}/bin/cargo-fuzz"; \
            test -x "${HOME}/.local/share/mise/installs/cargo-mutants/${CARGO_MUTANTS_VERSION}/bin/cargo-mutants" \
            ;; \
        *) echo "unsupported TARGETARCH for Rust tool installation: ${TARGETARCH}" >&2; exit 1 ;; \
    esac

# BoltFFI publishes verified x64 and ARM64 release binaries with custom names.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) boltffi_arch=x86_64; boltffi_sha256=342af5abf855dcea1b88b1f2fd8b72ba09083f0d8eab7a0930b954539defce4a ;; \
        arm64) boltffi_arch=aarch64; boltffi_sha256=ec4d6a94cd5c032e8a381a824deddf97c724e7e3f43d86050e4df9f86e2e7b41 ;; \
        *) echo "unsupported TARGETARCH for BoltFFI: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    boltffi_root="${HOME}/.local/share/mise/installs/boltffi-cli/${BOLTFFI_VERSION}"; \
    mkdir -p "${boltffi_root}/bin"; \
    boltffi_archive="/tmp/boltffi-linux-${boltffi_arch}.tar.gz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/boltffi/boltffi/releases/download/v${BOLTFFI_VERSION}/boltffi-linux-${boltffi_arch}.tar.gz" -o "${boltffi_archive}"; \
    printf '%s  %s\n' "${boltffi_sha256}" "${boltffi_archive}" | sha256sum --check --strict -; \
    tar --extract --gzip --file "${boltffi_archive}" --directory "${boltffi_root}/bin"; \
    test -x "${boltffi_root}/bin/boltffi"; \
    rm -f "${boltffi_archive}"

RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    MISE_CARGO_BINSTALL_ONLY=1 mise install && \
    mise exec -- rustup component add rust-analyzer

# Checksum-pinned upstream helper binaries avoid a direct, unpinned Cargo install.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) \
            release_target=x86_64-unknown-linux-gnu; \
            cargo_watch_sha512=2b6e28821aea9642d79f24290b18f58be615ff6b52da5e1536c0ad9a1eda834af713c78183a356273047cd63c43bc6ebcb372bccbecccc1e45246cffbe043320; \
            lychee_sha256=1f4e0ef7f6554a6ed33dd7ac144fb2e1bbed98598e7af973042fc5cd43951c9a \
            ;; \
        arm64) \
            release_target=aarch64-unknown-linux-gnu; \
            cargo_watch_sha512=e1d29699863de701e57568b26e5ff2b2c8c6b93ee7a3a66209228a6ee40c60ea3c2cdd7b3840071b58e18bf4cb022c09ad43b329fab5f4f8a1d196bd4985bc85; \
            lychee_sha256=91a7bd65685da41b90ccb9bc867a3d649a7818042dae04ff405e55a25bddee4c \
            ;; \
        *) echo "unsupported TARGETARCH for helper binaries: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cargo_watch_archive="/tmp/cargo-watch-v${CARGO_WATCH_VERSION}-${release_target}.tar.xz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/watchexec/cargo-watch/releases/download/v${CARGO_WATCH_VERSION}/cargo-watch-v${CARGO_WATCH_VERSION}-${release_target}.tar.xz" -o "${cargo_watch_archive}"; \
    printf '%s  %s\n' "${cargo_watch_sha512}" "${cargo_watch_archive}" | sha512sum --check --strict -; \
    mkdir -p /tmp/cargo-watch; \
    tar --extract --xz --file "${cargo_watch_archive}" --directory /tmp/cargo-watch --strip-components=1; \
    install -m 0755 /tmp/cargo-watch/cargo-watch "${HOME}/.local/bin/cargo-watch"; \
    lychee_archive="/tmp/lychee-${release_target}.tar.gz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-${release_target}.tar.gz" -o "${lychee_archive}"; \
    printf '%s  %s\n' "${lychee_sha256}" "${lychee_archive}" | sha256sum --check --strict -; \
    mkdir -p /tmp/lychee; \
    tar --extract --gzip --file "${lychee_archive}" --directory /tmp/lychee --strip-components=1; \
    install -m 0755 /tmp/lychee/lychee "${HOME}/.local/bin/lychee"; \
    rm -rf /tmp/cargo-watch /tmp/lychee "${cargo_watch_archive}" "${lychee_archive}"

RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    mise install "opentofu@${OPENTOFU_VERSION}" && \
    mise use -g --pin "opentofu@${OPENTOFU_VERSION}"

# The package lock pins both Node CLIs and every npm tarball they install.
COPY --chown=agent:agent maintained-image-build/skills-cli/package.json maintained-image-build/skills-cli/package-lock.json /home/agent/.local/share/architect-node-tools/

# Pinned sources avoid moving-branch lookups, Git credential fallbacks, and adapter drift.
RUN . ~/.profile && set -eu; \
    node_bin="${HOME}/.local/share/mise/installs/node/${NODE_TOOLS_VERSION}/bin"; \
    npm_home=/tmp/architect-npm-home; \
    npm_config_dir=/tmp/architect-npm-config; \
    source_root=/tmp/architect-sources; \
    git_home=/tmp/architect-git-home; \
    rm -rf "${npm_home}" "${npm_config_dir}" "${source_root}" /tmp/architect-npm-cache "${git_home}"; \
    mkdir -p "${npm_home}" "${npm_config_dir}" "${source_root}/git-template"; \
    : > "${npm_config_dir}/user.npmrc"; \
    : > "${npm_config_dir}/global.npmrc"; \
    export PATH="${node_bin}:${PATH}"; \
    test "$("${node_bin}/node" --version)" = "v${NODE_TOOLS_VERSION}"; \
    test "$("${node_bin}/npm" --version)" = "11.19.0"; \
    cd /tmp; \
    env -i HOME="${npm_home}" PATH="${node_bin}:/usr/bin:/bin" \
        NPM_CONFIG_USERCONFIG="${npm_config_dir}/user.npmrc" \
        NPM_CONFIG_GLOBALCONFIG="${npm_config_dir}/global.npmrc" \
        NPM_CONFIG_REGISTRY=https://registry.npmjs.org/ \
        NPM_CONFIG_CACHE=/tmp/architect-npm-cache \
        NPM_CONFIG_IGNORE_SCRIPTS=true NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false \
        "${node_bin}/npm" ci --prefix "${HOME}/.local/share/architect-node-tools" \
            --ignore-scripts --no-audit --no-fund; \
    mkdir -p "${git_home}"; \
    git_clean() { \
        env -i HOME="${git_home}" PATH=/usr/bin:/bin \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https GIT_LFS_SKIP_SMUDGE=1 \
            /usr/bin/git "$@"; \
    }; \
    acquire_source() { \
        source_name="$1"; \
        repository="$2"; \
        commit_sha="$3"; \
        tree_sha="$4"; \
        archive_sha="$5"; \
        source_dir="${source_root}/${source_name}"; \
        git_dir="${source_root}/${source_name}.git"; \
        archive_path="${source_root}/${source_name}.tar"; \
        mkdir -p "${source_dir}"; \
        git_clean init --template="${source_root}/git-template" --quiet "${git_dir}"; \
        git_clean -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "${git_dir}" \
            fetch --quiet --depth=1 "https://github.com/${repository}.git" "${commit_sha}"; \
        test "$(git_clean -C "${git_dir}" rev-parse FETCH_HEAD)" = "${commit_sha}"; \
        test "$(git_clean -C "${git_dir}" rev-parse 'FETCH_HEAD^{tree}')" = "${tree_sha}"; \
        git_clean -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "${git_dir}" \
            archive --format=tar --output="${archive_path}" FETCH_HEAD; \
        printf '%s  %s\n' "${archive_sha}" "${archive_path}" | sha256sum --check --strict -; \
        tar --extract --file "${archive_path}" --directory "${source_dir}" --no-same-owner; \
        rm -rf "${git_dir}" "${archive_path}"; \
    }; \
    acquire_source caveman JuliusBrussee/caveman \
        8b0c1d3699b8d83e87fe4605b378da20c41555e0 \
        4e8aa5e191457ba9ebd34b4a7eee6a7bd246ccff \
        954909b361634fad64bd299642ca3d5d5f6320d8b9fb6760efc51a4e83eea718; \
    acquire_source jackin-dev jackin-project/jackin-dev \
        a01b342162bc56cdf1e8bbaab793e73d31c1d621 \
        df2808b2fd551d0466036352579571b20efb0933 \
        97972af0add734cdeee560dba3c3861d8da8084f04b688aabfbcfe6c900fd0e1; \
    acquire_source shadcn-improve shadcn/improve \
        cac56e1ebd3c279aa9153616cfeac7b174ab90f9 \
        b8195551ac5dae1830e0eaed20079a4ee555a20b \
        9aa4067c152f18270a220b01dce8d83da9e5a8f30cd264f3a2ad30eedc1d14b1; \
    skills_cli="${HOME}/.local/share/architect-node-tools/node_modules/.bin/skills"; \
    test -x "${skills_cli}" && test -x "${HOME}/.local/share/architect-node-tools/node_modules/.bin/ctx7"; \
    caveman_source="${source_root}/caveman"; \
    "${node_bin}/node" "${caveman_source}/bin/install.js" --only opencode --no-mcp-shrink; \
    test -f "${HOME}/.config/opencode/plugins/caveman/plugin.js"; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${caveman_source}" -a codex --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${caveman_source}" -a amp --yes --global; \
    test -f "${HOME}/.agents/skills/caveman/SKILL.md"; \
    jackin_source="${source_root}/jackin-dev"; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${jackin_source}" -s '*' -a codex --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${jackin_source}" -s '*' -a amp --yes --global; \
    test -f "${HOME}/.agents/skills/jackin-propose/SKILL.md"; \
    test -f "${HOME}/.agents/skills/jackin-merge-pr/SKILL.md"; \
    shadcn_source="${source_root}/shadcn-improve"; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a claude-code --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a codex --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a amp --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a opencode --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a kimi-code-cli --yes --global; \
    test -f "${HOME}/.claude/skills/improve/SKILL.md"; \
    test -f "${HOME}/.agents/skills/improve/SKILL.md"; \
    rm -rf "${source_root}" "${npm_home}" "${npm_config_dir}" /tmp/architect-npm-cache /tmp/architect-git-home; \
    mkdir -p \
        /home/agent/.config/caveman \
        /home/agent/.claude \
        /home/agent/.codex \
        /home/agent/.config/amp \
        /home/agent/.kimi-code \
        /home/agent/.grok

# ── Token-optimisation stack ──────────────────────────────────────────────────

# AGENTS.md setup.
ENV CAVEMAN_DEFAULT_MODE=ultra
COPY --chown=root:agent --chmod=440 caveman-config.json /home/agent/.config/caveman/config.json
COPY --chown=agent:agent --chmod=644 AGENTS.md.d/ /tmp/AGENTS.md.d/
RUN find /tmp/AGENTS.md.d -maxdepth 1 -type f -name '*.md' | sort | \
    while IFS= read -r file; do cat "${file}"; printf '\n'; done > /tmp/AGENTS.md && \
    install -m 0644 /tmp/AGENTS.md /home/agent/AGENTS.md && \
    install -m 0644 /tmp/AGENTS.md /home/agent/CLAUDE.md && \
    ln -sf /home/agent/CLAUDE.md /home/agent/.claude/CLAUDE.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.codex/AGENTS.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.config/amp/AGENTS.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.kimi-code/AGENTS.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.grok/AGENTS.md

# Headroom.
RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    mise install "uv@${UV_VERSION}" && \
    mise use -g --pin "uv@${UV_VERSION}"

RUN . ~/.profile && uv tool install --no-build "headroom-ai[mcp]==${HEADROOM_VERSION}"

# RTK.
RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    mise install "rtk@${RTK_VERSION}" && \
    mise use -g --pin "rtk@${RTK_VERSION}" && \
    mise exec -- rtk --version

ENV RTK_TELEMETRY_DISABLED=1

# opencode RTK.
RUN . ~/.profile && \
    rtk init -g --opencode && \
    test -f /home/agent/.config/opencode/plugins/rtk.ts
