#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
jackin_ref=90acf49722f31c566702c23eea51282beba1cdad
jackin_branches="feature/openshell-native main"
jackin_api=https://api.github.com/repos/jackin-project/jackin
upstream_url=https://raw.githubusercontent.com/jackin-project/jackin/${jackin_ref}/mise.toml
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
  case "$jackin_ref" in
    *[!0-9a-f]* | "") printf 'check-jackin-pins: jackin_ref must be a full commit hash\n' >&2; exit 1 ;;
  esac
  [ "${#jackin_ref}" -eq 40 ] || { printf 'check-jackin-pins: jackin_ref must be a full commit hash\n' >&2; exit 1; }
  reachable=
  for branch in $jackin_branches; do
    status=$(curl --fail --silent --show-error --proto '=https' "${jackin_api}/compare/${branch}...${jackin_ref}" | sed -n 's/^  "status": "\([a-z]*\)".*/\1/p') || status=
    case "$status" in
      behind | identical) reachable=1 ;;
    esac
  done
  [ -n "$reachable" ] || { printf 'check-jackin-pins: jackin commit %s is not reachable from any of the jackin branches: %s\n' "$jackin_ref" "$jackin_branches" >&2; exit 1; }
  curl --fail --silent --show-error --location --proto '=https' --output upstream.toml "$upstream_url"
  tools_block upstream.toml > upstream
  compare pinned upstream "toolchain/jackin-pins.toml differs from [tools] in jackin commit ${jackin_ref}; copy that block or change jackin_ref"
  exit 0
fi

tools_block "$root/toolchain/mise.toml" > "$work/toolchain"
compare pinned toolchain "[tools] in toolchain/mise.toml differs from toolchain/jackin-pins.toml; change both in one commit"

rust=$(sed -n 's/^rust = { version = "\([^"]*\)".*/\1/p' "$work/pinned")
[ -n "$rust" ] || { printf 'check-jackin-pins: no rust pin in toolchain/jackin-pins.toml\n' >&2; exit 1; }
grep -o 'mbx +[0-9][0-9.]*' "$root/Dockerfile" | sort -u > "$work/mbx" || true
printf 'mbx +%s\n' "$rust" > "$work/mbx.want"
compare mbx.want mbx "the Dockerfile uses a toolchain other than the rust pin"
