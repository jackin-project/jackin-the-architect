#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: read-mise-tool-version CONFIG tools.NAME" >&2
    exit 2
fi

config_file="$1"
tool_key="$2"

if [[ ! -f "${config_file}" || -L "${config_file}" ]]; then
    echo "Mise config is not a regular file: ${config_file}" >&2
    exit 1
fi
if [[ ! "${tool_key}" =~ ^tools\.[a-zA-Z0-9_-]+$ ]]; then
    echo "invalid Mise tool key: ${tool_key}" >&2
    exit 2
fi

version="$(mise config get --file "${config_file}" "${tool_key}")"
if [[ ! "${version}" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "unsupported version value for ${tool_key}: ${version}" >&2
    exit 1
fi

printf '%s\n' "${version}"
