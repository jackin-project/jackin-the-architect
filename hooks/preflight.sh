#!/bin/bash
# Runs after jackin installs the agent CLI and bootstraps plugins.
# `claude mcp add …` belongs here, not in the Dockerfile, because
# jackin injects the claude CLI per container at launch time.
set -euo pipefail

trap 'printf "[architect-preflight] ERROR: failed at line %s (exit %s)\n" "$LINENO" "$?" >&2; exit 1' ERR

log()  { printf '[architect-preflight] %s\n' "$*"; }
warn() { printf '[architect-preflight] WARNING: %s\n' "$*" >&2; }
err()  { printf '[architect-preflight] ERROR: %s\n'   "$*" >&2; }

# Configure Context7 for the active agent when CONTEXT7_API_KEY is set.
# Without an API key the launch is treated as Context7-disabled — no
# OAuth device flow is attempted (operators run headlessly and OAuth
# would block). Set the key via operator env with a host reference:
#   jackin config env set CONTEXT7_API_KEY '${CONTEXT7_API_KEY}'
# then export CONTEXT7_API_KEY=ctx7sk-... on the host.
#
# Args: label, then ctx7 CLI flags selecting the agent and mode.
setup_context7() {
    local agent_label="$1"
    shift

    if [[ -z "${CONTEXT7_API_KEY:-}" ]]; then
        log "CONTEXT7_API_KEY unset — skipping Context7 setup for ${agent_label}"
        return 0
    fi

    log "configuring Context7 for ${agent_label}"
    if ! mise exec -- ctx7 setup "$@" --api-key "$CONTEXT7_API_KEY" -y; then
        err "ctx7 setup failed (exit $?). Check CONTEXT7_API_KEY and reachability of context7.com"
        exit 1
    fi
}

# Register headroom as an MCP server for the active agent.
# Headroom exposes headroom_compress / headroom_retrieve / headroom_stats.
# MCP mode only — proxy mode conflicts with Claude Code's prompt-cache management.
# opencode / kimi: baked into their JSON configs at image build time.
# grok: registered here via `grok mcp add` (writes ~/.grok/config.toml, which
# setup_grok reseeds). The earlier "reads ~/.claude/mcp.json" note was wrong —
# nothing wrote that file, so grok got no headroom at all.
register_headroom_mcp() {
    if ! command -v headroom >/dev/null 2>&1; then
        warn "headroom not on PATH — skipping MCP registration for ${JACKIN_AGENT:-unknown}"
        return 0
    fi

    case "${JACKIN_AGENT:-}" in
        claude)
            local mcp_err
            if mcp_err="$(claude mcp get headroom 2>&1 >/dev/null)"; then
                return 0
            fi
            if [[ "$mcp_err" != *"No MCP server"* ]]; then
                err "claude mcp get headroom failed unexpectedly: $mcp_err"
                exit 1
            fi
            log "registering headroom MCP server for claude"
            headroom mcp install --quiet 2>/dev/null || \
                claude mcp add headroom -- headroom mcp serve
            ;;
        codex)
            log "registering headroom MCP server for codex"
            codex mcp add headroom -- headroom mcp serve 2>/dev/null || true
            ;;
        amp)
            log "registering headroom MCP server for amp"
            amp mcp add headroom -- headroom mcp serve 2>/dev/null || true
            ;;
        grok)
            log "registering headroom MCP server for grok"
            grok mcp add headroom -- headroom mcp serve 2>/dev/null || true
            ;;
        opencode|kimi|""|*)
            ;;
    esac
}

# Write the caveman-active flag file for agents that use the Claude Code
# plugin hook system (caveman-mode-tracker.js reads this on every
# UserPromptSubmit). Writing here ensures the flag exists before the
# first prompt, so caveman is active from turn 1 — not from turn 2
# after the SessionStart hook has fired and been processed.
#
# CAVEMAN_DEFAULT_MODE is already set to "ultra" via jackin.role.toml.
# printf (not echo) avoids a trailing newline that would make readFlag
# return null (the whitelist check trims, but belt-and-suspenders).
seed_caveman_flag() {
    local claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
    local flag="${claude_dir}/.caveman-active"
    local mode="${CAVEMAN_DEFAULT_MODE:-ultra}"
    mkdir -p "${claude_dir}"
    printf '%s' "${mode}" > "${flag}"
    log "caveman flag seeded: ${flag} → ${mode}"
}

verify_codex_caveman_skills() {
    if [[ -f "${HOME}/.agents/skills/caveman/SKILL.md" ]]; then
        log "codex caveman skills present in ${HOME}/.agents/skills"
        return 0
    fi

    err "codex caveman skill missing from ${HOME}/.agents/skills"
    err "this image is broken — rebuild/pull projectjackin/jackin-the-architect:latest or run: npx -y skills add JuliusBrussee/caveman -a codex --yes --global"
    exit 1
}

case "${JACKIN_AGENT:-}" in
    claude)
        seed_caveman_flag
        setup_context7 claude --claude --mcp
        register_headroom_mcp
        ;;
    codex)
        verify_codex_caveman_skills
        setup_context7 codex --codex --mcp
        register_headroom_mcp
        ;;
    opencode)
        setup_context7 opencode --opencode --mcp
        ;;
    amp|kimi|grok)
        # No native MCP target — install the docs skill under
        # ~/.agents/skills/ so the agent invokes `ctx7 library` /
        # `ctx7 docs` directly. grok also has no per-agent step
        # beyond this (uses --always-approve from jackin).
        setup_context7 "$JACKIN_AGENT" --cli --universal
        register_headroom_mcp
        ;;
    "")     warn "JACKIN_AGENT unset — skipping per-agent setup" ;;
    *)      warn "unknown JACKIN_AGENT=${JACKIN_AGENT} — skipping per-agent setup" ;;
esac
