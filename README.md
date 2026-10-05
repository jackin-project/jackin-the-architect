# The Architect

**The Architect** is the jackin agent role for developing [jackin](https://github.com/jackin-project/jackin) itself (role identifier `the-architect`). It provides the Rust development environment needed to build and test the jackin CLI.

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

Jackin development tool versions come from [`jackin-project/jackin`](https://github.com/jackin-project/jackin). [`jackin-toolchain/mise.toml`](jackin-toolchain/mise.toml) is generated from the upstream `mise.toml` and keeps its tool pins plus the Cargo backend aliases/settings needed to install Rust tools through `cargo-binstall`. Comments and task definitions are intentionally omitted. [`jackin-toolchain/rust-toolchain.toml`](jackin-toolchain/rust-toolchain.toml) is copied from upstream as-is so Rust is installed from Jackin's tested toolchain file. Refresh both with `mise exec cargo:rust-script@0.36.0 -- scripts/update-jackin-toolchain.rs`; this repository has no scheduled updater workflow, so review and commit the generated diff manually.

Docker reads the versions for Jackin-managed tools from `jackin-toolchain/mise.toml`, including the manually installed binaries and the Node installation path. The per-architecture asset checksum cases remain explicit allowlists: when an upstream version changes, the image build fails until maintainers verify and add the matching asset checksums. The remaining Dockerfile version ARGs cover tools that are not in Jackin's generated toolchain, such as OpenTofu, cargo-watch, lychee, Headroom, and RTK.

- **Jackin toolchain** (via mise): Node.js, Bun, Zig, Syft, Cosign, and Jackin's cargo tools from upstream `mise.toml` installed through `cargo-binstall`
- **Rust** (via mise) with clippy, rustfmt, rust-analyzer
- **Cargo helper tools**: cargo-watch and lychee
- **Node.js** (via mise)
- **Bun** (via mise) for jackin docs development
- **OpenTofu** (via mise)
- **Context7** (npm) — up-to-date library docs via MCP
- **Caveman** token-compression hooks + skills (claude + codex profiles, pinned by Git commit, tree, and source-archive SHA-256 in the Dockerfile)
- **Headroom** (uv tool) — MCP tools for compressing large context inputs
- **RTK** (mise/aqua) — deterministic shell-output compression
- System build tools (`build-essential`, `libssl-dev`, `pkg-config`, `cmake`)
- **xxd** — hex dump and binary patch helper

Shared shell/runtime tools come from `projectjackin/construct:trixie`.

## Plugins

Declared in [`jackin.role.toml`](./jackin.role.toml) under `[claude].plugins` and bootstrapped at runtime by jackin. Marketplaces beyond `@claude-plugins-official`:

- `@jackin-marketplace` — [jackin-project/jackin-marketplace](https://github.com/jackin-project/jackin-marketplace) (source of `jackin-dev`)
- `@tailrocks-rust-skills` — [tailrocks/tailrocks-rust-skills](https://github.com/tailrocks/tailrocks-rust-skills) (Rust guidance, project setup, review, refactoring, and remediation)
- `@tailrocks-roadmap-skills` — [tailrocks/tailrocks-roadmap-skills](https://github.com/tailrocks/tailrocks-roadmap-skills) (research, brainstorming, planning, verification, and delivery)
- `@caveman` — [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) (source of `caveman`; Dockerfile pins an immutable Git commit, its tree, and the generated source-archive SHA-256)

To refresh Caveman, select an upstream release tag, fetch and resolve that tag to a commit and tree, then compute the archive digest with `git archive --format=tar <commit> | sha256sum`. Update the commit, tree, and digest together in the Dockerfile; the build checks all three before using the source. No Renovate manager tracks this immutable source tuple, so review it manually.

Invoke these skills explicitly; the Roadmap pack covers proposal work through idea capture, research, and planning skills.

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
