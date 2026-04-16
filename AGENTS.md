# AGENTS.md — jackin-the-architect

A privileged Claude Code agent image. Extends `projectjackin/construct:trixie` and layers Rust, Node.js, OpenTofu, and ~18 Claude Code plugins including `superpowers`, `plugin-dev`, and `hookify`. Named "The Architect" because it has the broadest operator capability of any agent in this org.

**Image distribution is public.** Because of the plugin count and the presence of OpenTofu (which can manage org-write credentials at runtime), this image has a larger blast radius than the sibling `jackin-agent-smith`. Treat it with proportionally more care.

## Threat model

Same base concerns as `jackin-agent-smith` (base image, mise pulls, runtime credentials, layer secrets, plugin trust), plus:

1. **Plugin breadth.** 18 plugins, each with its own update cadence, means a compromised plugin in any of them runs with the agent's full capability. `plugin-dev` and `hookify` in particular can generate code that auto-executes via hooks.
2. **OpenTofu credential adjacency.** An operator running this image against `jackin-github-terraform` exports `GITHUB_TOKEN` with org-admin scope into the shell. Anything the agent does (any plugin, any skill) can see that token via `/proc/*/environ`.
3. **Rust `cargo install`.** `cargo install --locked cargo-nextest cargo-watch` pulls from crates.io at build time. Lock file pins transitive deps, but root crates are unpinned — a malicious version of `cargo-watch` on crates.io lands in a future image rebuild.
4. **Wider tool surface for supply-chain.** Rust + Node + OpenTofu + mise = four separate package ecosystems, each with its own registry trust.

## Hard rules (do not break these)

Inherits all of jackin-agent-smith's rules, and adds:

1. **Never add a plugin without documenting its trust anchor.** Marketplace name alone is insufficient for this repo — note in the PR why the specific plugin is trusted.
2. **Never `ENV GITHUB_TOKEN=...` or any credential ENV.** OpenTofu reads from the shell at run time; baking any credential into the image exposes it to every puller.
3. **`cargo install` without `--locked` is forbidden.** Every `cargo install` line must include `--locked` so the lock file pins transitive deps.

## Required pre-commit checks

```bash
# 1. What's staged? Anything surprising?
git status --porcelain

# 2. Dockerfile sanity: no secret-shaped ARGs/ENVs, no un-locked cargo install
if git diff --cached --name-only | grep -qx Dockerfile; then
  grep -iE '^(ARG|ENV)\s+[A-Z_]*(TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL)' Dockerfile \
    && { echo "SECRET-SHAPED ARG/ENV in Dockerfile"; exit 1; } || true
  grep -E 'cargo install' Dockerfile | grep -v -- '--locked' \
    && { echo "UN-LOCKED cargo install in Dockerfile"; exit 1; } || true
fi

# 3. jackin.agent.toml plugin-source audit
if git diff --cached --name-only | grep -qx jackin.agent.toml; then
  grep -E '"[^@]+@[^"]+"' jackin.agent.toml | grep -Ev '@(claude-plugins-official|jackin-marketplace)' \
    && echo "NOTE: plugin from non-default marketplace — document trust rationale in PR body" || true
fi

# 4. Credential scan (defense-in-depth)
git diff --cached --name-only -z | xargs -0 -r \
  grep -l -iE "ghp_|gho_|ghs_|ghr_|github_pat_|BEGIN [A-Z ]*PRIVATE KEY|aws_access_key_id|aws_secret_access_key|bearer [a-z0-9-]{20,}" 2>/dev/null
```

The third check is advisory (prints a note, doesn't exit non-zero) — a non-default marketplace isn't necessarily wrong, but the PR reviewer should see a trust rationale.

## Conventions

- Branch naming: `chore/*`, `feat/*`, `fix/*`
- Commit messages follow Conventional Commits
- `main` is the primary branch
- All changes go through PR

## What this does NOT protect against

Inherits everything in `jackin-agent-smith`, plus:
- A compromised plugin that runs during agent startup before a hook check fires — `hookify` and `plugin-dev` are architecturally able to introduce such plugins.
- OpenTofu credential leakage through a plugin that reads `/proc/*/environ` — runtime isolation isn't in scope here; anchor trust in the plugin set.
- crates.io package takeover on a future rebuild — `--locked` mitigates for transitive deps but not for the top-level crate name.
