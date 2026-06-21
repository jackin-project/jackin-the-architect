// Vendored from rtk-ai/rtk hooks/opencode/rtk.ts @ v0.42.4 (RTK_VERSION).
// This is a STABLE thin shim — all rewrite logic lives in the `rtk` binary
// (`rtk rewrite`, src/discover/registry.rs), so this file does not change
// across RTK versions and does not need to track RTK_VERSION. Refresh only if
// the opencode plugin API changes. Source of truth for rules: the Rust binary.
//
// Gives opencode the same shell-output compression the claude PreToolUse hook
// provides: rewrites `git status` -> `rtk git status` before execution. RTK
// is the stack's SHELL layer (cargo/git/build/test); native reads + headroom
// own the rest. Self-disables if `rtk` is not on PATH (mise shim) — never
// breaks opencode startup.
import type { Plugin } from "@opencode-ai/plugin"

export const RtkOpenCodePlugin: Plugin = async ({ $ }) => {
  try {
    await $`which rtk`.quiet()
  } catch {
    console.warn("[rtk] rtk binary not found in PATH — plugin disabled")
    return {}
  }

  return {
    "tool.execute.before": async (input, output) => {
      const tool = String(input?.tool ?? "").toLowerCase()
      if (tool !== "bash" && tool !== "shell") return
      const args = output?.args
      if (!args || typeof args !== "object") return

      const command = (args as Record<string, unknown>).command
      if (typeof command !== "string" || !command) return

      try {
        const result = await $`rtk rewrite ${command}`.quiet().nothrow()
        const rewritten = String(result.stdout).trim()
        if (rewritten && rewritten !== command) {
          ;(args as Record<string, unknown>).command = rewritten
        }
      } catch {
        // rtk rewrite failed — pass through unchanged
      }
    },
  }
}
