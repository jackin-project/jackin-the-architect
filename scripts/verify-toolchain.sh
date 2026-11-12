#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -eu

mode=${1-}
root=${VERIFY_ROOT-}
trusted=${VERIFY_USER:-root}
cargo_bin=$root/usr/local/cargo/bin
set -- "$root/usr/local/cargo" "$root/usr/local/rustup" "$root/usr/local/share/mise" "$root/etc/mise" "$root/usr/local/bin/mise" "$root/usr/bin/git" "$root/usr/lib/git-core"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'verify-toolchain: %s\n' "$1" >&2
  exit 1
}

untrusted() {
  find "$1" -prune \( ! -user "$trusted" -o \( ! -type l \( -perm -020 -o -perm -002 \) \) \) -print
}

walk() {
  walked=$1
  while :; do
    if [ -n "$(untrusted "$walked")" ]; then
      printf '%s\n' "$walked"
      return 1
    fi
    [ "$walked" = "${root:-/}" ] && return 0
    walked=$(dirname "$walked")
  done
}

own_dir() {
  case $(readlink -f "$1") in
    "$home" | "$home"/*) return 0 ;;
  esac
  return 1
}

trusted_path() {
  resolved=$(readlink -f "$1")
  if ! own_dir "$(dirname "$1")"; then
    bad=$(walk "$1") || fail "$2: $bad is not owned by $trusted or is writable by a group or by others"
  fi
  bad=$(walk "$resolved") || fail "$2: $bad is not owned by $trusted or is writable by a group or by others"
}

allowed_link() {
  case "$1" in
    "$root"/usr/local/cargo/registry | "$root"/usr/local/cargo/git | "$root"/usr/local/cargo/.package-cache | "$root"/usr/local/cargo/.package-cache-mutate)
      [ "$2" = "/sandbox/.cargo/${1##*/}" ] ;;
    *) return 1 ;;
  esac
}

inside_trees() {
  resolved=$1
  shift
  for tree in "$@"; do
    case "$resolved" in
      "$tree" | "$tree"/*) return 0 ;;
    esac
  done
  return 1
}

check_trees() {
  offenders=$(find "$@" \( ! -user "$trusted" -o -perm -020 -o -perm -002 \) ! -type l -print)
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; fail "owned by another user or writable by a group or by others"; }

  find "$@" -type l -print > "$work/links"
  : > "$work/escapes"
  while IFS= read -r link; do
    target=$(readlink "$link")
    allowed_link "$link" "$target" && continue
    inside_trees "$(readlink -f "$link")" "$@" || printf '%s -> %s\n' "$link" "$target" >> "$work/escapes"
  done < "$work/links"
  [ ! -s "$work/escapes" ] || { cat "$work/escapes" >&2; fail "symbolic link that leaves the trusted trees"; }
}

check_path() {
  [ -n "${HOME-}" ] || fail "HOME is not set"
  [ -z "${MISE_DATA_DIR-}" ] || fail "MISE_DATA_DIR is set, but a sandbox process has none"
  home=$(readlink -f "$HOME")

  [ "$(mise exec -- printenv CARGO_HOME)" = "$root/usr/local/cargo" ] || fail "CARGO_HOME under mise exec is not $root/usr/local/cargo"
  [ "$(mise exec -- printenv RUSTUP_HOME)" = "$root/usr/local/rustup" ] || fail "RUSTUP_HOME under mise exec is not $root/usr/local/rustup"
  missing=$(mise ls --missing)
  [ -z "$missing" ] || { printf '%s\n' "$missing" >&2; fail "tools of the mise config are not installed for this user"; }

  mise exec -- printenv PATH | tr : '\n' > "$work/path"
  reached=
  while IFS= read -r dir; do
    if [ "$dir" = "$cargo_bin" ]; then
      reached=1
      break
    fi
    case "$dir" in
      /*) ;;
      *) fail "PATH entry ahead of $cargo_bin is not absolute: '$dir'" ;;
    esac
    [ -d "$dir" ] || fail "PATH entry ahead of $cargo_bin is not a directory: $dir"
    own_dir "$dir" && continue
    trusted_path "$dir" "PATH entry ahead of $cargo_bin"
  done < "$work/path"
  [ -n "$reached" ] || fail "$cargo_bin is not on PATH under mise exec"

  for tool in cargo rustc; do
    trusted_path "$cargo_bin/$tool" "rustup proxy $tool"
  done
  for tool in cargo rustc mbx; do
    found=$(mise exec -- /bin/sh -c "command -v $tool") || fail "$tool is not found under mise exec"
    trusted_path "$found" "$tool resolves to $found"
  done
}

case "$mode" in
  trees) check_trees "$@" ;;
  path) check_path ;;
  *) fail "usage: verify-toolchain.sh trees|path" ;;
esac
