#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 OpenAI
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audit="$repo_root/scripts/marketplace-audit.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

expect_pass() {
  local label="$1"
  local fixture_dir="$tmp_dir/$label"
  mkdir -p "$fixture_dir"
  cp "$repo_root/jackin.role.toml" "$fixture_dir/jackin.role.toml"

  if ! (cd "$fixture_dir" && bash "$audit") >"$tmp_dir/$label.log" 2>&1; then
    echo "Expected marketplace audit to accept $label fixture:" >&2
    cat "$tmp_dir/$label.log" >&2
    return 1
  fi
}

expect_reject() {
  local label="$1"
  local expected_ref="$2"
  local fixture_dir="$tmp_dir/$label"
  mkdir -p "$fixture_dir"

  if (cd "$fixture_dir" && bash "$audit") >"$tmp_dir/$label.log" 2>&1; then
    echo "Expected marketplace audit to reject $label fixture." >&2
    return 1
  fi
  if ! grep -Fq "$expected_ref" "$tmp_dir/$label.log"; then
    echo "Marketplace audit rejected $label for an unexpected reason:" >&2
    cat "$tmp_dir/$label.log" >&2
    return 1
  fi
}

expect_pass valid

mkdir -p "$tmp_dir/prefix-spoof"
sed 's/@tailrocks-rust-skills"/@tailrocks-rust-skills-untrusted"/' \
  "$repo_root/jackin.role.toml" >"$tmp_dir/prefix-spoof/jackin.role.toml"
expect_reject prefix-spoof 'tailrocks-rust-skills@tailrocks-rust-skills-untrusted'

mkdir -p "$tmp_dir/multiple-separators"
sed 's/@tailrocks-rust-skills"/@unknown@tailrocks-rust-skills"/' \
  "$repo_root/jackin.role.toml" >"$tmp_dir/multiple-separators/jackin.role.toml"
expect_reject multiple-separators 'tailrocks-rust-skills@unknown@tailrocks-rust-skills'

mkdir -p "$tmp_dir/unknown-marketplace"
sed 's/@caveman"/@unlisted-marketplace"/' \
  "$repo_root/jackin.role.toml" >"$tmp_dir/unknown-marketplace/jackin.role.toml"
expect_reject unknown-marketplace 'caveman@unlisted-marketplace'

echo "Marketplace audit regression tests passed."
