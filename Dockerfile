FROM projectjackin/construct:0.11-trixie@sha256:821b41aa5942a7d18101ff8eafc8982f25d2513b4d65c06196c31090cec61075

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CARGO_BINSTALL_VERSION=1.20.0
ARG OPENTOFU_VERSION=1.12.3
# CAVEMAN_VERSION must be a release tag from
# https://github.com/JuliusBrussee/caveman/releases — never `main`,
# never a raw commit SHA. The `skills` CLI's shallow git-clone fetch
# resolves tags but not arbitrary SHAs.
ARG CAVEMAN_VERSION=1.9.0
ARG CTX7_VERSION=0.5.2

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    openssl \
    pkg-config \
    cmake && \
    sudo apt-get autoremove -y

USER agent

ENV MISE_TRUSTED_CONFIG_PATHS=/workspace:/tmp/jackin-mise

COPY --chown=root:root jackin-toolchain/ /tmp/jackin-mise/

RUN mkdir -p \
    "${HOME}/.cache/mise" \
    "${HOME}/.cargo/bin" \
    "${HOME}/.cargo/registry" \
    "${HOME}/.cargo/git"

# Per-tool RUNs are deliberate: bumping one ARG only invalidates that
# tool's layer. Trips hadolint DL3059; the cache reuse is worth it.
RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    mise install "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}"

RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    mise trust /tmp/jackin-mise/mise.toml && \
    mkdir -p "${HOME}/.config/mise" && \
    cp /tmp/jackin-mise/mise.toml "${HOME}/.config/mise/config.toml" && \
    # the cp replaces the global config and unpins cargo-binstall, leaving an
    # orphaned shim that exits 1; re-pin so `mise install` binstalls cargo: tools
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise install -C /tmp/jackin-mise rust && \
    mise use -g --pin -C /tmp/jackin-mise rust && \
    mise install && \
    mise exec -- rustup component add rust-analyzer

# cargo-binstall downloads prebuilt binaries — avoids compiling from source.
# Cache mounts preserve the crate registry across layer rebuilds on persistent runners.
RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    . ~/.profile && \
    cargo binstall --no-confirm cargo-watch lychee

RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    mise install "opentofu@${OPENTOFU_VERSION}" && \
    mise use -g --pin "opentofu@${OPENTOFU_VERSION}"

RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    mise exec -- npm install -g "ctx7@${CTX7_VERSION}"

# Caveman ≥1.8.0 native opencode plugin needs repoRoot (a local clone);
# curl-pipe can't do it. Shallow-clone at the pinned tag, run bin/install.js.
#
# `--only opencode` covers the opencode native plugin (CLI copies files into
# ~/.config/opencode/plugins/caveman/). Claude registration is owned by the
# jackin plugin bootstrap — the derived Dockerfile appends
# `RUN claude plugin install caveman@caveman` from the `[claude].plugins` and
# `[[claude.marketplaces]]` declarations in jackin.role.toml — so we
# deliberately do NOT pass `--only claude` here. Doing so would race the
# plugin bootstrap: the caveman installer runs before jackin's claude-CLI
# install block, the `claude plugin install` call fails, and the installer
# falls back to wiring hooks in settings.json. The plugin bootstrap then
# runs after, registers hooks via the manifest, and both paths fire on
# every event (caveman issue #392 — double CAVEMAN MODE block, double
# reinforcement line).
#
# `--no-mcp-shrink` keeps the caveman-shrink MCP proxy out of this step;
# `hooks/preflight.sh::register_caveman_shrink` does it at container start
# where the claude CLI is guaranteed to be on PATH.
#
# Codex and Amp have no Claude-plugin path, so the caveman skills tree at
# `${HOME}/.agents/skills/caveman/` is installed via `skills add --global`.
# `hooks/preflight.sh::verify_codex_caveman_skills` checks that file is
# present for codex.
RUN . ~/.profile && \
    git clone --depth 1 --branch "v${CAVEMAN_VERSION}" https://github.com/JuliusBrussee/caveman.git /tmp/caveman && \
    node /tmp/caveman/bin/install.js --only opencode --no-mcp-shrink && \
    test -f "${HOME}/.config/opencode/plugins/caveman/plugin.js" && \
    npx -y skills add "JuliusBrussee/caveman#v${CAVEMAN_VERSION}" -a codex --yes --global && \
    npx -y skills add "JuliusBrussee/caveman#v${CAVEMAN_VERSION}" -a amp --yes --global && \
    test -f "${HOME}/.agents/skills/caveman/SKILL.md" && \
    rm -rf /tmp/caveman

# jackin-dev workflow skills (propose, brainstorm, research, create-pr, merge-pr,
# release*). Claude installs them via `jackin-dev@jackin-marketplace` in
# jackin.role.toml; codex/amp/opencode/kimi all read ${HOME}/.agents/skills/,
# so install the portable SKILL.md tree there once, same pattern as caveman
# above. `--global` writes the canonical ~/.agents/skills/<skill>/ tree; opencode
# and kimi read that same path, so the codex+amp installs cover all four agents.
# `-s '*'` grabs every skill (the default takes only a root SKILL.md, and
# jackin-dev has none — its skills live under skills/<name>/SKILL.md).
#
# Tracks jackin-dev `main` (first-party, no tagged release yet — the skill set
# is still iterating). Pin to `jackin-project/jackin-dev#vX.Y.Z` once it tags.
RUN . ~/.profile && \
    npx -y skills add "jackin-project/jackin-dev" -s '*' -a codex --yes --global && \
    npx -y skills add "jackin-project/jackin-dev" -s '*' -a amp --yes --global && \
    test -f "${HOME}/.agents/skills/propose/SKILL.md" && \
    test -f "${HOME}/.agents/skills/merge-pr/SKILL.md"
