FROM projectjackin/construct:0.13-trixie@sha256:830798c5ebd7b8a04c8bf2a5e341bca7486709d640d8cf30b08c3c9d5b854c95

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CARGO_BINSTALL_VERSION=1.20.0
ARG OPENTOFU_VERSION=1.12.3
# CAVEMAN_VERSION must be a release tag from
# https://github.com/JuliusBrussee/caveman/releases — never `main`,
# never a raw commit SHA. The `skills` CLI's shallow git-clone fetch
# resolves tags but not arbitrary SHAs.
ARG CAVEMAN_VERSION=1.9.0
ARG CTX7_VERSION=0.5.3
# See https://pypi.org/project/headroom-ai/ for the current release.
ARG HEADROOM_VERSION=0.26.0
# See https://github.com/astral-sh/uv/releases for the current release.
ARG UV_VERSION=0.11.21

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
# `--no-mcp-shrink` keeps the caveman-shrink MCP proxy out entirely —
# shrink required a wired-up upstream MCP server that was never configured
# (caveman issue #474) and has been dropped from this role.
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

# ── Token-optimisation stack ──────────────────────────────────────────────────

# Caveman ultra default for agents that read ~/.config/caveman/config.json.
# CAVEMAN_DEFAULT_MODE env var (highest priority) is declared in jackin.role.toml.
# Use /home/agent/ prefix — ${HOME} does not expand in COPY destinations
# (only ENV/ARG vars do; HOME is set by the OS, not an ENV instruction).
#
# Agent global-instruction files: single source → every runtime path.
# Real files, not symlinks — Codex refuses symlinked config dirs (codex#11314).
# opencode: plugin owns ~/.config/opencode/AGENTS.md; do not COPY here.
# grok: reads ~/.claude/CLAUDE.md natively; covered by the claude COPY below.
RUN mkdir -p \
    /home/agent/.config/caveman \
    /home/agent/.claude \
    /home/agent/.codex \
    /home/agent/.config/amp \
    /home/agent/.kimi-code
COPY --chown=root:agent --chmod=440 caveman-config.json /home/agent/.config/caveman/config.json
COPY --chown=root:agent --chmod=440 token-optimization.md /home/agent/.claude/CLAUDE.md
COPY --chown=root:agent --chmod=440 token-optimization.md /home/agent/.codex/AGENTS.md
COPY --chown=root:agent --chmod=440 token-optimization.md /home/agent/.config/amp/AGENTS.md
COPY --chown=root:agent --chmod=440 token-optimization.md /home/agent/.kimi-code/AGENTS.md

# Headroom: input-side context compression. MCP mode only — the proxy mode
# conflicts with Claude Code's prompt-cache management.
# Exposes headroom_compress / headroom_retrieve / headroom_stats as MCP tools.
# TextCompressor (kompress-base ML model) not explicitly disabled here — no
# stable config key yet (see chopratejas/headroom). Agent guidance in
# token-optimization.md covers what to compress; rule-based compressors
# (LogCompressor, SmartCrusher, SearchCompressor) are what the guidance enables.
# TODO(token-opt): add explicit kompress-base=off once headroom ships a config key.
RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    . ~/.profile && \
    cargo binstall --no-confirm "uv@${UV_VERSION}"

RUN . ~/.profile && uv tool install "headroom-ai[mcp]==${HEADROOM_VERSION}"

# Expose uv tool binaries (headroom, etc.) on PATH.
ENV PATH="/home/agent/.local/bin:${PATH}"

# Bake headroom MCP entry into opencode and kimi configs at build time.
# Claude and Grok handled in hooks/preflight.sh (claude CLI not available here).
# Codex and Amp handled in hooks/preflight.sh (prefer CLI for idempotency).
RUN . ~/.profile && node -e '\
  const fs=require("fs"),h=process.env.HOME;\
  const oc=JSON.parse(fs.readFileSync(h+"/.config/opencode/opencode.json","utf8"));\
  (oc.mcp||(oc.mcp={})).headroom={command:"headroom",args:["mcp","serve"]};\
  fs.writeFileSync(h+"/.config/opencode/opencode.json",JSON.stringify(oc,null,2));\
  fs.writeFileSync(h+"/.kimi-code/mcp.json",JSON.stringify({mcpServers:{headroom:{command:"headroom",args:["mcp","serve"]}}},null,2));\
'
