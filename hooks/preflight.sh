#!/bin/bash
# Per-agent setup after jackin bootstrap (claude mcp etc. here).
set -euo pipefail

trap 'printf "[architect-preflight] ERROR: failed at line %s (exit %s)\n" "$LINENO" "$?" >&2; exit 1' ERR

log()  { printf '[architect-preflight] %s\n' "$*"; }
warn() { printf '[architect-preflight] WARNING: %s\n' "$*" >&2; }
err()  { printf '[architect-preflight] ERROR: %s\n'   "$*" >&2; }

json_set() {
    local file="$1"; shift
    local dir; dir="$(dirname "${file}")"
    mkdir -p "${dir}"
    [[ -f "${file}" ]] || printf '{}\n' > "${file}"

    local tmp; tmp="$(mktemp "${dir}/.$(basename "${file}").XXXXXX")"
    if jq "$@" "${file}" > "${tmp}"; then
        mv "${tmp}" "${file}"
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# Context7 setup (non-interactive).
setup_context7() {
    local agent_label="$1"
    shift

    if [[ -z "${CONTEXT7_API_KEY:-}" ]]; then
        log "CONTEXT7_API_KEY unset — skipping Context7 setup for ${agent_label}"
        return 0
    fi

    log "configuring Context7 for ${agent_label}"
    local rc=0
    mise exec -- ctx7 setup "$@" --api-key "$CONTEXT7_API_KEY" -y || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        err "ctx7 setup failed (exit ${rc}). Check CONTEXT7_API_KEY and reachability of context7.com"
        exit 1
    fi
}

register_headroom_mcp() {
    if ! command -v headroom >/dev/null 2>&1; then
        warn "headroom not on PATH — skipping"
        return 0
    fi

    case "${JACKIN_AGENT:-}" in
        claude)
            if mcp_err="$(claude mcp get headroom 2>&1 >/dev/null)"; then return 0; fi
            if [[ "$mcp_err" != *"No MCP server"* ]]; then err "headroom mcp get failed: $mcp_err"; exit 1; fi
            headroom mcp install --quiet 2>/dev/null || claude mcp add headroom -- headroom mcp serve
            ;;
        codex|amp|grok)
            "${JACKIN_AGENT}" mcp add headroom -- headroom mcp serve 2>/dev/null || true
            ;;
        opencode|kimi)
            patch_headroom_json "${JACKIN_AGENT}"
            ;;
    esac
}

patch_headroom_json() {
    local target="$1"
    if ! command -v jq >/dev/null 2>&1; then return 0; fi
    local file filter
    case "${target}" in
        opencode) file="${HOME}/.config/opencode/opencode.json"; filter='.mcp.headroom = {"type":"local","command":["headroom","mcp","serve"],"enabled":true}' ;;
        kimi) file="${HOME}/.kimi-code/mcp.json"; filter='.mcpServers.headroom = {"command":"headroom","args":["mcp","serve"]}' ;;
        *) return 0 ;;
    esac
    json_set "${file}" "${filter}" || true
}

seed_caveman_flag() {
    local claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
    local flag="${claude_dir}/.caveman-active"
    local mode="${CAVEMAN_DEFAULT_MODE:-ultra}"
    mkdir -p "${claude_dir}"
    printf '%s' "${mode}" > "${flag}"
    log "caveman flag seeded: ${flag} → ${mode}"
}

wire_caveman_statusline() {
    local claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
    local settings="${claude_dir}/settings.json"
    if ! command -v jq >/dev/null 2>&1; then return 0; fi
    local current=""
    [[ -f "${settings}" ]] && current="$(jq -r '.statusLine.command // ""' "${settings}" 2>/dev/null || echo "")"
    if [[ "${current}" == *caveman-statusline.sh* || -n "${current}" ]]; then return 0; fi
    local script
    script="$(find "${claude_dir}/plugins/marketplaces/caveman" "${claude_dir}/plugins/cache/caveman" -name caveman-statusline.sh -type f 2>/dev/null | head -n1)"
    if [[ -z "${script}" ]]; then return 0; fi
    json_set "${settings}" --arg cmd "bash ${script}" '.statusLine = {"type": "command", "command": $cmd}' || true
}

register_rtk_hook() {
    if ! command -v rtk >/dev/null 2>&1; then
        warn "rtk not on PATH — skipping"
        return 0
    fi
    if ! rtk init -g --hook-only --auto-patch; then
        warn "rtk init failed"
    fi
}

verify_codex_caveman_skills() {
    if [[ -f "${HOME}/.agents/skills/caveman/SKILL.md" ]]; then return 0; fi
    err "codex caveman skill missing"
    err "run: npx -y skills add JuliusBrussee/caveman -a codex --yes --global"
    exit 1
}

# ── Third-party provider configuration ───────────────────────────────
# Writes ~/.claude/settings.json env block for the selected provider so
# Claude Code routes through a third-party Anthropic-compatible endpoint.
configure_claude_code_provider() {
    local provider="${CLAUDE_CODE_PROVIDER:-anthropic}"
    local settings="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"

    case "${provider}" in
        anthropic|"")
            return 0
            ;;
        zai)
            if [[ -z "${ZAI_API_KEY:-}" ]]; then
                warn "CLAUDE_CODE_PROVIDER=zai but ZAI_API_KEY unset — skipping"
                return 0
            fi
            log "configuring Claude Code for Z.AI (GLM-5.2, 1M ctx)"
            json_set "${settings}" --arg key "${ZAI_API_KEY}" \
                '.env = (.env // {}) |
                 .env.ANTHROPIC_BASE_URL = "https://api.z.ai/api/anthropic" |
                 .env.ANTHROPIC_AUTH_TOKEN = $key |
                 .env.ANTHROPIC_DEFAULT_OPUS_MODEL = "glm-5.2[1m]" |
                 .env.ANTHROPIC_DEFAULT_SONNET_MODEL = "glm-5.2[1m]" |
                 .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "glm-4.7" |
                 .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = "1000000" |
                 .env.API_TIMEOUT_MS = "3000000"' || warn "failed to write Z.AI config"
            ;;
        minimax)
            if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
                warn "CLAUDE_CODE_PROVIDER=minimax but MINIMAX_API_KEY unset — skipping"
                return 0
            fi
            log "configuring Claude Code for MiniMax (M3, 1M ctx)"
            json_set "${settings}" --arg key "${MINIMAX_API_KEY}" \
                '.env = (.env // {}) |
                 .env.ANTHROPIC_BASE_URL = "https://api.minimax.io/anthropic" |
                 .env.ANTHROPIC_AUTH_TOKEN = $key |
                 .env.ANTHROPIC_MODEL = "MiniMax-M3[1m]" |
                 .env.ANTHROPIC_DEFAULT_OPUS_MODEL = "MiniMax-M3[1m]" |
                 .env.ANTHROPIC_DEFAULT_SONNET_MODEL = "MiniMax-M3[1m]" |
                 .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "MiniMax-M3[1m]" |
                 .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = "1000000"' || warn "failed to write MiniMax config"
            ;;
        kimi)
            if [[ -z "${KIMI_API_KEY:-}" ]]; then
                warn "CLAUDE_CODE_PROVIDER=kimi but KIMI_API_KEY unset — skipping"
                return 0
            fi
            log "configuring Claude Code for Kimi (K2.7)"
            json_set "${settings}" --arg key "${KIMI_API_KEY}" \
                '.env = (.env // {}) |
                 .env.ANTHROPIC_BASE_URL = "https://api.kimi.com/coding/" |
                 .env.ANTHROPIC_API_KEY = $key |
                 .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = "262144"' || warn "failed to write Kimi config"
            ;;
        *)
            warn "unknown CLAUDE_CODE_PROVIDER=${provider} — skipping"
            ;;
    esac
}

# Writes ~/.codex/config.toml for the selected provider so Codex routes
# through a third-party OpenAI-compatible endpoint.
configure_codex_provider() {
    local provider="${CODEX_PROVIDER:-openai}"
    local cfg="${HOME}/.codex/config.toml"

    case "${provider}" in
        openai|"")
            return 0
            ;;
        minimax)
            if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
                warn "CODEX_PROVIDER=minimax but MINIMAX_API_KEY unset — skipping"
                return 0
            fi
            log "configuring Codex for MiniMax (M3)"
            mkdir -p "$(dirname "${cfg}")"
            cat > "${cfg}" <<TOML
model = "MiniMax-M3"
model_provider = "minimax"
model_context_window = 1000000

[model_providers.minimax]
name = "MiniMax"
base_url = "https://api.minimax.io/v1"
experimental_bearer_token = "${MINIMAX_API_KEY}"
wire_api = "responses"
TOML
            ;;
        zai)
            if [[ -z "${ZAI_API_KEY:-}" ]]; then
                warn "CODEX_PROVIDER=zai but ZAI_API_KEY unset — skipping"
                return 0
            fi
            log "configuring Codex for Z.AI (GLM-5.2)"
            mkdir -p "$(dirname "${cfg}")"
            cat > "${cfg}" <<TOML
model = "glm-5.2"
model_provider = "zai"
model_context_window = 1000000

[model_providers.zai]
name = "Z.AI"
base_url = "https://api.z.ai/api/coding/paas/v4"
experimental_bearer_token = "${ZAI_API_KEY}"
wire_api = "chat"
TOML
            ;;
        *)
            warn "unknown CODEX_PROVIDER=${provider} — skipping"
            ;;
    esac
}

case "${JACKIN_AGENT:-}" in
    claude)
        configure_claude_code_provider
        seed_caveman_flag
        wire_caveman_statusline
        register_rtk_hook
        setup_context7 claude --claude --mcp
        register_headroom_mcp
        ;;
    codex)
        configure_codex_provider
        verify_codex_caveman_skills
        setup_context7 codex --codex --mcp
        register_headroom_mcp
        ;;
    opencode)
        setup_context7 opencode --opencode --mcp
        register_headroom_mcp
        ;;
    amp|kimi|grok)
        setup_context7 "$JACKIN_AGENT" --cli
        register_headroom_mcp
        ;;
    "")     warn "JACKIN_AGENT unset — skipping per-agent setup" ;;
    *)      warn "unknown JACKIN_AGENT=${JACKIN_AGENT} — skipping per-agent setup" ;;
esac
