# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.25-trixie@sha256:ad853971892ae36eb8b43201f219192405d12b51d317b37fde073f02708aee95

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CARGO_BINSTALL_VERSION=1.20.1
ARG OPENTOFU_VERSION=1.12.3
# CAVEMAN_VERSION must be tagged release.
ARG CAVEMAN_VERSION=1.9.1
ARG CTX7_VERSION=0.5.3
# HEADROOM_VERSION.
ARG HEADROOM_VERSION=0.31.0
# UV_VERSION.
ARG UV_VERSION=0.11.27
# RTK_VERSION (aqua).
ARG RTK_VERSION=0.43.0

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
    xxd && \
    apt-get autoremove -y

USER agent

ENV MISE_TRUSTED_CONFIG_PATHS=/workspace:/tmp/jackin-mise

COPY --chown=root:root jackin-toolchain/ /tmp/jackin-mise/

RUN mkdir -p \
    "${HOME}/.cache/amp" \
    "${HOME}/.cache/mise" \
    "${HOME}/.cargo/bin" \
    "${HOME}/.cargo/registry" \
    "${HOME}/.cargo/git"

# Per-tool RUNs (caching).
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
    : "Keep cargo-binstall pinned before installing Cargo-backed mise tools" && \
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise install -C /tmp/jackin-mise rust && \
    mise use -g --pin -C /tmp/jackin-mise rust && \
    mise install && \
    mise exec -- rustup component add rust-analyzer

# cargo-binstall + caches.
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

# Caveman (opencode clone, codex/amp skills).
RUN . ~/.profile && \
    git clone --depth 1 --branch "v${CAVEMAN_VERSION}" https://github.com/JuliusBrussee/caveman.git /tmp/caveman && \
    node /tmp/caveman/bin/install.js --only opencode --no-mcp-shrink && \
    test -f "${HOME}/.config/opencode/plugins/caveman/plugin.js" && \
    npx -y skills add "JuliusBrussee/caveman#v${CAVEMAN_VERSION}" -a codex --yes --global && \
    npx -y skills add "JuliusBrussee/caveman#v${CAVEMAN_VERSION}" -a amp --yes --global && \
    test -f "${HOME}/.agents/skills/caveman/SKILL.md" && \
    rm -rf /tmp/caveman

# jackin-dev skills.
RUN . ~/.profile && \
    npx -y skills add "jackin-project/jackin-dev" -s '*' -a codex --yes --global && \
    npx -y skills add "jackin-project/jackin-dev" -s '*' -a amp --yes --global && \
    test -f "${HOME}/.agents/skills/jackin-propose/SKILL.md" && \
    test -f "${HOME}/.agents/skills/jackin-merge-pr/SKILL.md"

# improve skill (shadcn/improve).
RUN . ~/.profile && \
    npx -y skills add "shadcn/improve" -a claude-code --yes --global && \
    npx -y skills add "shadcn/improve" -a codex --yes --global && \
    npx -y skills add "shadcn/improve" -a amp --yes --global && \
    npx -y skills add "shadcn/improve" -a opencode --yes --global && \
    npx -y skills add "shadcn/improve" -a kimi-code-cli --yes --global && \
    test -f "${HOME}/.claude/skills/improve/SKILL.md" && \
    test -f "${HOME}/.agents/skills/improve/SKILL.md"

# ── Token-optimisation stack ──────────────────────────────────────────────────

# AGENTS.md setup.
RUN mkdir -p \
    /home/agent/.config/caveman \
    /home/agent/.claude \
    /home/agent/.codex \
    /home/agent/.config/amp \
    /home/agent/.kimi-code \
    /home/agent/.grok
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
RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    mise install "uv@${UV_VERSION}" && \
    mise use -g --pin "uv@${UV_VERSION}"

RUN . ~/.profile && uv tool install "headroom-ai[mcp]==${HEADROOM_VERSION}"

# PATH for shims.
ENV PATH="/home/agent/.local/bin:/home/agent/.local/share/mise/shims:${PATH}"

# RTK.
RUN --mount=type=secret,id=github_token,uid=1000,required=false \
    --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) \
    mise install "rtk@${RTK_VERSION}" && \
    mise use -g --pin "rtk@${RTK_VERSION}" && \
    mise exec -- rtk --version

ENV RTK_TELEMETRY_DISABLED=1

# opencode RTK.
RUN . ~/.profile && \
    rtk init -g --opencode && \
    test -f /home/agent/.config/opencode/plugins/rtk.ts
