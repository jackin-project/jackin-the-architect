# Token tools

- **Shell output -> RTK.** Auto-compressed on claude and opencode. On codex/amp/kimi/grok, prefix heavy commands yourself: `rtk cargo test`, `rtk git status`, `rtk git diff`.
- **Everything else -> headroom MCP.** Call `headroom_compress` on large tool output before it enters context (logs, big JSON, search results, HTML). **Never** compress source/diffs (mangles identifiers), responses under ~500 tokens, or already-compressed content. `headroom_retrieve` restores an original; `headroom_stats` before reporting work done.
