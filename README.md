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

Jackin development tool versions come from [`jackin-project/jackin`](https://github.com/jackin-project/jackin). [`jackin-toolchain/mise.toml`](jackin-toolchain/mise.toml) is generated from the upstream `mise.toml` and keeps its tool pins plus the Cargo backend aliases/settings needed to install Rust tools through `cargo-binstall`. Comments and task definitions are intentionally omitted. [`jackin-toolchain/rust-toolchain.toml`](jackin-toolchain/rust-toolchain.toml) is copied from upstream as-is so Rust is installed from Jackin's tested toolchain file. Refresh both with `mise exec cargo:rust-script@0.36.0 -- scripts/update-jackin-toolchain.rs`; the scheduled `Jackin Toolchain` workflow opens a PR when upstream tool pins change.

Architect-only bootstrap tools remain pinned in `Dockerfile` ARGs (`CARGO_BINSTALL_VERSION`, `OPENTOFU_VERSION`, `CAVEMAN_VERSION`, `CTX7_VERSION`, `HEADROOM_VERSION`, `UV_VERSION`, `RTK_VERSION`); bump via `docker build --build-arg <NAME>=<value>`.

- **Jackin toolchain** (via mise): Node.js, Bun, Zig, Syft, Cosign, and Jackin's cargo tools from upstream `mise.toml` installed through `cargo-binstall`
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
- **xxd** — hex dump and binary patch helper

Shared shell/runtime tools come from `projectjackin/construct:trixie`.

## Plugins

Declared in [`jackin.role.toml`](./jackin.role.toml) under `[claude].plugins` and bootstrapped at runtime by jackin. Marketplaces beyond `@claude-plugins-official`:

- `@jackin-marketplace` — [jackin-project/jackin-marketplace](https://github.com/jackin-project/jackin-marketplace) (source of `jackin-dev`)
- `@tailrocks-marketplace` — [tailrocks/tailrocks-skills](https://github.com/tailrocks/tailrocks-skills) (source of `tailrocks-skills`, including Rust guidance, Rust project setup, proposal, and research skills)
- `@caveman` — [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) (source of `caveman`; pinned to a tagged release via Dockerfile `CAVEMAN_VERSION`)

Trust rationale: see [AGENTS.md § Threat model](./AGENTS.md#threat-model).

## Skills

Installed at build time via `skills add` for supported Agent Skills hosts (`claude-code`, `codex`, `amp`, `opencode`, and `kimi-code-cli`):

- `improve` — [shadcn/improve](https://github.com/shadcn/improve): read-only advisor that audits a codebase and writes self-contained implementation plans under `plans/` for other agents to execute.

## Runtime hooks

The `hooks/preflight.sh` script runs before the agent CLI starts:

1. **Context7** — non-interactive MCP setup (skips if unset).
2. **Headroom MCP** — for active agent.
3. **Caveman/RTK hooks** — for claude; skills for codex.
4. **Codex caveman check**.

## PR workflow

Reference for which Claude Code review command to run at which point in a PR's life: see [`docs/pr-workflow.md`](./docs/pr-workflow.md).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
