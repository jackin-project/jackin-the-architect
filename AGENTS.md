# Rules

Keep this section identical in all four repositories. Write the rules for one repository under `## This project`.

## Program

- This program rebuilds jackin on NVIDIA OpenShell. The program files are in `jackin/rewrite/` on the branch `feature/openshell-native`. `rewrite/DESIGN.md` is the authority. `rewrite/PLAN.md` lists the tasks and the gates.
- OpenShell is the only execution engine. Do not run an agent, a sandbox, or a container with Docker, Podman, or Apple `container`.
- Jackin builds the role images with Docker BuildKit through `docker buildx`. Only the `jackin-image` crate starts `docker`.
- An agent can run Docker containers in its sandbox only when its role or workspace enables the Docker capability (decision D24). The capability is disabled by default.
- Codex is the only agent. Do not add code, files, or configuration for another agent.
- Use the old code only as a reference. To read an old jackin file, run `git show 470fc5d6:<path>` in jackin. Copy old code only when the task states a reason.
- Do not keep compatibility. Do not write a migration, an importer, a shim, an alias, or a fallback. Make breaking changes.
- Use the latest stable version of every tool and every dependency. Do not use a prerelease.
- Run silently. Do not ask a human. If you are not sure, find the facts. Decide. Record the decision in `jackin/rewrite/decisions.tsv`.

## Code

- Do not write comments in code. The only exceptions are SPDX license headers, shebang lines, parser directives such as the Dockerfile `# syntax=` line, and files that a repository generator writes and verifies.
- Write clap help text with `#[command(about = "...")]` and `#[arg(help = "...")]`. Do not use doc comments for help text.
- Before you fix a bug, find why the design permitted it. Find whether the same design permits related bugs. Fix the cause. Do not fix only the symptom.
- Judge work by correctness, consistency, and fit. Do not keep a known-wrong state because of cost or effort.

## Tests

- Delete all old tests. Write new tests only for the behavior that the program builds.
- Before you write a test, get approval of its plan from an independent reviewer subagent. In the plan, name the behavior, the positive and negative cases, and the reason that no other test covers them.
- Keep a test only after an independent reviewer subagent sees it fail on broken code and pass on fixed code.
- Test through public interfaces. Assert the resulting state. Do not assert the sequence of calls.
- Do not use a fake for code that you own. Use a fake only at an external boundary, behind an interface that you own. The boundaries are the OpenShell gateway, the network, the clock, and the filesystem.
- Keep tests hermetic and deterministic. Do not use a live network in nextest. Run live tests against a real gateway in `xtask e2e`.
- Run tests with `cargo nextest` through `mise exec -- mbx`. Never use `cargo test`.
- If a test is flaky, quarantine it at once. Mark it `#[ignore]` with a tracking reference. Do not weaken, skip, or delete a test to hide broken behavior.

## Work

- Use subagents for research, implementation, review, and verification. Use a different subagent to review the work of each implementer.
- Verify from the repository root before each commit.
- Use Conventional Commits. Commit with `git commit -s`. Push after each commit.
- Work on `feature/openshell-native`, or on a local worktree branch that you merge into it. Do not force-push. Do not merge to `main`. The operator merges the pull requests.
- Before the operator merges a pull request, read every review, comment, and thread. Fix accepted feedback and reply with the URL of the fix commit. Reply to rejected feedback with the evidence.
- Keep this file short. Put plans, explanations, and progress in documentation.

## This project (jackin-the-architect)

- The Architect is a Codex role for jackin development. Decision D20 in `jackin/rewrite/DESIGN.md` defines it.
- The final stage of the `Dockerfile` starts `FROM construct`. Jackin builds the image. Do not publish the image from this repository.
- `toolchain/mise.toml` is the global mise config of the image, and `toolchain/mise.lock` locks it. Keep its `[tools]` table equal to the one in jackin `mise.toml`: copy the table into `toolchain/jackin-pins.toml` and `toolchain/mise.toml` in one commit, then run `mise run lock:toolchain`. `scripts/check-jackin-pins.sh` checks this.
- The policy permits the crates.io index and download hosts, and the GitHub `info/refs` and `git-upload-pack` paths. It names no Codex host, because OpenShell adds the rule of the Codex provider. Add a host only when the G-FAST gate in a sandbox proves it is needed. Review every widening of the policy as a change to what prompt-injected content can reach.
- The gates are `jackin role check .` with the jackin binary from `jackin/target/debug/jackin`, `mise run test`, and the jackin G-FAST gate in a sandbox of this role.
- `.github/` and `config/fleet/` are generated by `velnor-actions generate`. Do not edit them by hand.
- Do not put a secret in the role.
