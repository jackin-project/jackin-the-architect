# The Architect

**The Architect** is the jackin agent role for developing [jackin](https://github.com/donbeave/jackin) itself (role identifier `the-architect`). It provides the Rust development environment needed to build and test the jackin CLI.

`jackin` validates this repo's Dockerfile, derives the final image itself, and mounts the cached repo checkout into `/workspace` when you run:

```sh
jackin load the-architect
# or, with the codex CLI instead of claude:
jackin load the-architect --agent codex
```

In a Codex session, caveman is delivered through Codex skills under `~/.agents/skills` rather than the Claude plugin/statusline path; trigger it with text such as `caveman mode`. Claude-only UI pieces like the statusline badge and `/caveman` hook command are not expected there.

## Contract

- Final Dockerfile stage must use the digest-pinned `projectjackin/construct:<version>-trixie` base.
- Plugins are declared in `jackin.role.toml`
- Threat model and hard rules: see [AGENTS.md](./AGENTS.md)

## Environment

Jackin development tool versions come from [`jackin-project/jackin`](https://github.com/jackin-project/jackin). [`jackin-toolchain/mise.toml`](jackin-toolchain/mise.toml) is generated from the upstream `mise.toml` and contains only its `[tools]` entries; comments, settings, and task definitions are intentionally omitted. [`jackin-toolchain/rust-toolchain.toml`](jackin-toolchain/rust-toolchain.toml) is copied from upstream as-is so Rust is installed from Jackin's tested toolchain file. Refresh both with `mise exec cargo:rust-script@0.36.0 -- scripts/update-jackin-toolchain.rs`; the scheduled `Jackin Toolchain` workflow opens a PR when upstream tool pins change.

Architect-only bootstrap tools remain pinned in `Dockerfile` ARGs (`CARGO_BINSTALL_VERSION`, `OPENTOFU_VERSION`, `CAVEMAN_VERSION`, `CTX7_VERSION`, `HEADROOM_VERSION`, `UV_VERSION`, `RTK_VERSION`); bump via `docker build --build-arg <NAME>=<value>`.

- **Jackin toolchain** (via mise): Node.js, Bun, Zig, Syft, Cosign, and Jackin's cargo tools from upstream `mise.toml`
- **Rust** (via mise) with clippy, rustfmt, rust-analyzer
- **Cargo helper tools**: cargo-watch and lychee
- **Node.js** (via mise)
- **Bun** (via mise) for jackin docs development
- **OpenTofu** (via mise)
- **Context7** (npm) — up-to-date library docs via MCP
- **Caveman** token-compression hooks + skills (claude + codex profiles, pinned to a tagged release)
- **Headroom** (uv tool) — MCP tools for compressing large context inputs
- **RTK** (mise/aqua) — deterministic shell-output compression
- System build tools (`build-essential`, `libssl-dev`, `pkg-config`, `cmake`)

Shared shell/runtime tools come from `projectjackin/construct:trixie`.

## Plugins

Declared in [`jackin.role.toml`](./jackin.role.toml) under `[claude].plugins` and bootstrapped at runtime by jackin. Marketplaces beyond `@claude-plugins-official`:

- `@jackin-marketplace` — [jackin-project/jackin-marketplace](https://github.com/jackin-project/jackin-marketplace) (source of `jackin-dev`)
- `@tailrocks-marketplace` — [tailrocks/tailrocks-marketplace](https://github.com/tailrocks/tailrocks-marketplace) (source of `rust-best-practices`)
- `@caveman` — [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) (source of `caveman`; pinned to a tagged release via Dockerfile `CAVEMAN_VERSION`)

Trust rationale: see [AGENTS.md § Threat model](./AGENTS.md#threat-model).

## Runtime hooks

The `hooks/preflight.sh` script runs before the agent CLI starts:

1. **Context7 MCP** — configures the Context7 MCP server for the active agent when `CONTEXT7_API_KEY` is set. Fully non-interactive: passes `--api-key` to `ctx7 setup`, picks the right target per agent (`--claude`/`--codex`/`--opencode` for MCP, `--cli` for amp/kimi/grok), and skips setup entirely when the key is absent (no OAuth device flow). Configure once via operator env with a host reference — `jackin config env set CONTEXT7_API_KEY '${CONTEXT7_API_KEY}'` — then export `CONTEXT7_API_KEY=ctx7sk-...` in the host shell.
2. **Headroom MCP** — registers `headroom mcp serve` for the active agent after jackin's runtime setup has created or refreshed agent config files.
3. **Claude token hooks** — seeds caveman ultra mode, wires the caveman statusline, and registers RTK's shell-output rewrite hook.
4. **Codex caveman skills check** — fails launch if `~/.agents/skills/caveman/SKILL.md` is missing (codex agent only); a missing file means the image was built wrong

## PR workflow

Reference for which Claude Code review command to run at which point in a PR's life: see [`docs/pr-workflow.md`](./docs/pr-workflow.md).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
