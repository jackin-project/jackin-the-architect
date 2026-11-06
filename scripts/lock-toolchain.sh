#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
data=${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}
cache=${MISE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mise}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/etc" "$work/home"
: > "$work/empty.toml"
cp "$root/toolchain/mise.toml" "$work/etc/config.toml"
cp "$root/toolchain/mise.lock" "$work/etc/mise.lock"
cp -R "$root/toolchain/.mise" "$work/etc/.mise"

cd "$work/home"
HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" MISE_DATA_DIR="$data" MISE_CACHE_DIR="$cache" \
  MISE_GLOBAL_CONFIG_FILE="$work/empty.toml" MISE_SYSTEM_CONFIG_DIR="$work/etc" \
  mise lock --global --platform linux-arm64,linux-x64

cp "$work/etc/mise.lock" "$root/toolchain/mise.lock"
rm -rf "$root/toolchain/.mise"
cp -R "$work/etc/.mise" "$root/toolchain/.mise"
