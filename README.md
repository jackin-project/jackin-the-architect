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

- Final Dockerfile stage must literally be `FROM projectjackin/construct:trixie`
- Plugins are declared in `jackin.role.toml`
- Threat model and hard rules: see [AGENTS.md](./AGENTS.md)

## Environment

Versions pinned in `Dockerfile` ARGs (`RUST_VERSION`, `NODE_VERSION`, `BUN_VERSION`, `JUST_VERSION`, `OPENTOFU_VERSION`, `CAVEMAN_VERSION`, `CTX7_VERSION`); bump via `docker build --build-arg <NAME>=<value>`.

- **Rust** (via mise) with clippy, rustfmt, rust-analyzer, cargo-nextest, cargo-watch, lychee
- **Node.js** (via mise)
- **Bun** (via mise) for jackin docs development
- **Just** (via mise) for jackin task recipes
- **OpenTofu** (via mise)
- **Context7** (npm) — up-to-date library docs via MCP
- **Caveman** token-compression hooks + skills (claude + codex profiles, pinned to a tagged release)
- System build tools (`build-essential`, `libssl-dev`, `pkg-config`, `cmake`)

Shared shell/runtime tools come from `projectjackin/construct:trixie`.

## Plugins

Declared in [`jackin.role.toml`](./jackin.role.toml) under `[claude].plugins` and bootstrapped at runtime by jackin. Marketplaces beyond `@claude-plugins-official`:

- `@jackin-marketplace` — [jackin-project/jackin-marketplace](https://github.com/jackin-project/jackin-marketplace) (source of `jackin-dev`)
- `@tailrocks-marketplace` — [tailrocks/tailrocks-marketplace](https://github.com/tailrocks/tailrocks-marketplace) (source of `rust-best-practices`)
- `@caveman` — [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) (source of `caveman`; pinned to a tagged release via Dockerfile `CAVEMAN_VERSION`)

Trust rationale: see [AGENTS.md § Threat model](./AGENTS.md#threat-model).

## Pre-launch hooks

The `hooks/preflight.sh` script runs before the agent CLI starts:

1. **Context7 MCP** — configures the MCP server if `CONTEXT7_API_KEY` is provided (prompted at launch, skippable)
2. **caveman-shrink MCP** — registers caveman-shrink as a Claude MCP middleware (claude agent only, idempotent; fails launch if the claude CLI is missing — see hook header for the contract)
3. **Codex caveman skills check** — fails launch if `~/.agents/skills/caveman/SKILL.md` is missing (codex agent only); a missing file means the image was built wrong

## PR workflow

Reference for which Claude Code review command to run at which point in a PR's life: see [`docs/pr-workflow.md`](./docs/pr-workflow.md).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
