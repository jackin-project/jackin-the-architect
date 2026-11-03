#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
upstream_url=https://raw.githubusercontent.com/jackin-project/jackin/feature/openshell-native/mise.toml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

tools_block() {
  awk '
    /^\[tools\]$/ { in_tools = 1; next }
    /^\[/ { in_tools = 0 }
    in_tools && NF { print }
  ' "$1"
}

compare() {
  if ! (cd "$work" && diff -u "$1" "$2") > "$work/diff"; then
    cat "$work/diff" >&2
    printf 'check-jackin-pins: %s\n' "$3" >&2
    exit 1
  fi
}

tools_block "$root/toolchain/jackin-pins.toml" > "$work/pinned"

if [ "${1-}" = "--upstream" ]; then
  curl --fail --silent --show-error --location --proto '=https' --output upstream.toml "$upstream_url"
  tools_block upstream.toml > upstream
  compare pinned upstream "toolchain/jackin-pins.toml differs from [tools] in jackin feature/openshell-native; copy that block"
  exit 0
fi

tools_block "$root/toolchain/mise.toml" > "$work/toolchain"
compare pinned toolchain "[tools] in toolchain/mise.toml differs from toolchain/jackin-pins.toml; change both in one commit"

rust=$(sed -n 's/^rust = { version = "\([^"]*\)".*/\1/p' "$work/pinned")
[ -n "$rust" ] || { printf 'check-jackin-pins: no rust pin in toolchain/jackin-pins.toml\n' >&2; exit 1; }
grep -o 'mbx +[0-9][0-9.]*' "$root/Dockerfile" | sort -u > "$work/mbx" || true
printf 'mbx +%s\n' "$rust" > "$work/mbx.want"
compare mbx.want mbx "the Dockerfile uses a toolchain other than the rust pin"
