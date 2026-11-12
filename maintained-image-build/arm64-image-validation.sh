#!/bin/bash
set -euo pipefail

: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
workspace="${GITHUB_WORKSPACE:-$PWD}"
case "$workspace" in
  /*) ;;
  *) echo 'WORKSPACE must be absolute' >&2; exit 2 ;;
esac

exec /usr/bin/env -i \
  PATH=/usr/bin:/bin \
  LC_ALL=C \
  "GITHUB_SHA=$GITHUB_SHA" \
  "GITHUB_RUN_ID=$GITHUB_RUN_ID" \
  "GITHUB_RUN_ATTEMPT=$GITHUB_RUN_ATTEMPT" \
  "RUNNER_TEMP=$RUNNER_TEMP" \
  "WORKSPACE=$workspace" \
  /usr/bin/python3 -I -S -B \
  "$workspace/maintained-image-build/arm64-image-validation.py"
