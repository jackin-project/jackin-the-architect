#!/usr/bin/env bash
set -euo pipefail

source_url="${JACKIN_MISE_URL:-https://raw.githubusercontent.com/jackin-project/jackin/refs/heads/main/mise.toml}"
output="${1:-jackin-toolchain/mise.toml}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL "$source_url" -o "$tmp"
mkdir -p "$(dirname "$output")"

awk '
  BEGIN { in_tools = 0 }
  /^\[tools\]$/ {
    in_tools = 1
    print
    next
  }
  /^\[/ {
    if (in_tools) exit
  }
  in_tools {
    print
  }
' "$tmp" > "$output"

if ! grep -q '^\[tools\]$' "$output"; then
  echo "failed to extract [tools] from $source_url" >&2
  exit 1
fi
