## Headroom MCP

Tools: `headroom_compress` `headroom_retrieve` `headroom_stats`. Compress large tool output before context eaten.

Compress: logs, large JSON, repetitive search results, HTML docs.
Never compress: source code/diffs (ML mangle identifiers), responses <500 tokens, already-compressed content, content forwarded verbatim to another tool.

Memory (CCR): `headroom_compress` stores originals in session SQLite; call `headroom_retrieve` to restore. Use as memory layer — no paste large content into context manually.

Long sessions: call `headroom_stats` before reporting work complete.