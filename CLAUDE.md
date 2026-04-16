# CLAUDE.md

See [AGENTS.md](AGENTS.md) for shared agent instructions.

This is the **highest-capability public agent image** in `jackin-project`. It ships ~18 plugins and includes OpenTofu, which at runtime has access to the operator's `GITHUB_TOKEN`. Plugin additions require documented trust rationale in the PR body. Never bake credentials into layers. Every `cargo install` must be `--locked`.

This repository uses `main` as its primary branch.
