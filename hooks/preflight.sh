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

# Wire the caveman statusline badge ([CAVEMAN:ULTRA]) into Claude Code's
# settings.json. The caveman *plugin* (registered via the marketplace in
# jackin.role.toml) ships the /caveman command and the mode-tracker hook
# that writes .caveman-active — but a Claude Code plugin cannot set
# `statusLine`; that is a settings.json field. The standalone caveman
# installer is what normally wires it, and this role deliberately skips it
# (`install.js --only opencode`) to avoid the double-hook bug (caveman
# #392). Result: the mode is active but the badge never renders. Wire just
# the statusLine here — idempotent, and never clobbering an operator's own
# statusLine.
wire_caveman_statusline() {
    local claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
    local settings="${claude_dir}/settings.json"

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not on PATH — cannot wire caveman statusline into ${settings}"
        return 0
    fi

    local script
    script="$(find "${claude_dir}/plugins/marketplaces/caveman" \
                   "${claude_dir}/plugins/cache/caveman" \
                   -name caveman-statusline.sh -type f 2>/dev/null | head -n1)"
    if [[ -z "${script}" ]]; then
        warn "caveman-statusline.sh not found under ${claude_dir}/plugins — skipping statusline wiring"
        return 0
    fi

    mkdir -p "${claude_dir}"
    [[ -f "${settings}" ]] || printf '{}\n' > "${settings}"

    # Preserve an operator-set statusLine; only wire (or refresh) ours.
    local current
    current="$(jq -r '.statusLine.command // ""' "${settings}" 2>/dev/null || echo "")"
    if [[ -n "${current}" && "${current}" != *caveman-statusline.sh* ]]; then
        log "operator statusLine present — leaving it untouched"
        return 0
    fi

    local command="bash ${script}"
    local tmp
    tmp="$(mktemp "${claude_dir}/.settings.json.XXXXXX")"
    if jq --arg cmd "${command}" \
          '.statusLine = {"type": "command", "command": $cmd}' \
          "${settings}" > "${tmp}"; then
        mv "${tmp}" "${settings}"
        log "caveman statusline wired: ${command}"
    else
        rm -f "${tmp}"
        warn "failed to update ${settings} with caveman statusline"
    fi
}

# Register RTK's auto-rewrite PreToolUse hook for Claude Code, natively and
# non-interactively. RTK compresses shell-command output (cargo/git/build/test/
# log) at the Bash tool boundary — deterministic, no model, cache-safe, exit
# codes preserved. The hook rewrites `git status` -> `rtk git status` before
# execution, so the agent receives compact output without knowing RTK is there.
#
# `rtk init -g`:
#   --hook-only  : write ONLY the hook — no RTK.md / CLAUDE.md patch (we own the
#                  guidance file token-optimization.md).
#   --auto-patch : patch settings.json without a TTY prompt. Required here:
#                  without it, rtk detects the non-interactive shell and defaults
#                  to "no patch" (src/hooks/init.rs::prompt_user_consent), so the
#                  hook would silently never install.
#
# Native install is the upstream-blessed path and is safe alongside caveman:
# rtk APPENDS to .hooks.PreToolUse (preserving caveman's hooks AND statusLine),
# backs up settings.json.bak before patching, honors CLAUDE_CONFIG_DIR, and is
# idempotent (skips when its hook is already present). It also keeps the hook
# command shape version-matched to the binary across RTK_VERSION bumps — which a
# hand-merged JSON entry would not. Telemetry stays off (RTK_TELEMETRY_DISABLED
# + the consent prompt is TTY-gated).
#
# claude only: codex/amp/kimi/grok have no RTK PreToolUse hook. codex's own
# native RTK mode is AGENTS.md instructions (and cannot combine with
# --auto-patch), which token-optimization.md already provides non-interactively;
# amp/kimi/grok are unsupported upstream and rely on the same manual-prefix
# guidance. opencode is wired natively at image build (`rtk init -g --opencode`).
register_rtk_hook() {
    if ! command -v rtk >/dev/null 2>&1; then
        warn "rtk not on PATH — skipping RTK hook registration for claude"
        return 0
    fi
    log "registering RTK hook for claude (rtk init -g --hook-only --auto-patch)"
    if ! rtk init -g --hook-only --auto-patch; then
        warn "rtk init failed — RTK auto-rewrite hook not registered for claude"
    fi
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
        wire_caveman_statusline
        register_rtk_hook
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
        #
        # `--universal` is NOT a `ctx7 setup` option (it lives on
        # `ctx7 generate`); passing it makes `setup` abort with
        # "unknown option '--universal'", which fails this preflight
        # hook and tears the agent's tab down at startup. `--cli`
        # alone already installs the universal .agents/skills target.
        setup_context7 "$JACKIN_AGENT" --cli
        register_headroom_mcp
        ;;
    "")     warn "JACKIN_AGENT unset — skipping per-agent setup" ;;
    *)      warn "unknown JACKIN_AGENT=${JACKIN_AGENT} — skipping per-agent setup" ;;
esac
