#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
data=${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}
cache=${MISE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mise}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'lock-toolchain: %s\n' "$1" >&2
  exit 1
}

mkdir "$work/etc" "$work/home"
cp "$root/toolchain/mise.toml" "$work/etc/config.toml"
cp "$root/toolchain/mise.lock" "$work/etc/mise.lock"
cp -R "$root/toolchain/.mise" "$work/etc/.mise"
: > "$work/system.toml"

cd "$work/home"
HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" MISE_DATA_DIR="$data" MISE_CACHE_DIR="$cache" \
  MISE_GLOBAL_CONFIG_FILE="$work/etc/config.toml" MISE_SYSTEM_CONFIG_FILE="$work/system.toml" \
  mise lock --global --platform linux-arm64,linux-x64

[ -s "$work/etc/mise.lock" ] || fail "mise wrote no lockfile for the copied toolchain config"

awk '
  /^\[tools\]$/ { in_tools = 1; next }
  /^\[/ { in_tools = 0 }
  in_tools && /^("[^"]+"|[A-Za-z0-9_.-]+) *=/ {
    key = $0
    sub(/ *=.*$/, "", key)
    gsub(/"/, "", key)
    print key
  }
' "$root/toolchain/mise.toml" > "$work/tools"

[ -s "$work/tools" ] || fail "toolchain/mise.toml declares no tools"

while IFS= read -r tool; do
  grep -F -x -q "[[tools.\"$tool\"]]" "$work/etc/mise.lock" \
    || grep -F -x -q "[[tools.$tool]]" "$work/etc/mise.lock" \
    || fail "the lock does not cover $tool"
done < "$work/tools"

cp "$work/etc/mise.lock" "$root/toolchain/mise.lock"
rm -rf "$root/toolchain/.mise"
cp -R "$work/etc/.mise" "$root/toolchain/.mise"
