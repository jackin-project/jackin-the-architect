# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
"""Guard the generated Mise file as the source of tool versions in Docker."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "Dockerfile"
TOOLCHAIN = ROOT / "jackin-toolchain" / "mise.toml"
RENOVATE = ROOT / "renovate.json"
VERSION_READER = ROOT / "maintained-image-build" / "read-mise-tool-version.sh"

# These tools are also installed or placed manually so their source asset
# checksums and Mise installation directories can be verified by Docker.
DERIVED_TOOLS = {
    "cargo-binstall": "cargo_binstall_version",
    "cargo-audit": "cargo_audit_version",
    "cargo-deny": "cargo_deny_version",
    "cargo-dylint": "cargo_dylint_version",
    "cargo-fuzz": "cargo_fuzz_version",
    "cargo-hack": "cargo_hack_version",
    "cargo-hakari": "cargo_hakari_version",
    "cargo-llvm-cov": "cargo_llvm_cov_version",
    "cargo-mutants": "cargo_mutants_version",
    "cargo-shear": "cargo_shear_version",
    "cargo-zigbuild": "cargo_zigbuild_version",
    "codebook-lsp": "codebook_lsp_version",
    "sccache": "sccache_version",
    "dylint-link": "dylint_link_version",
    "boltffi_cli": "boltffi_version",
    "node": "node_tools_version",
    "uv": "uv_version",
}

DOCKER_ARGS = {
    "cargo-binstall": "CARGO_BINSTALL_VERSION",
    "cargo-audit": "CARGO_AUDIT_VERSION",
    "cargo-deny": "CARGO_DENY_VERSION",
    "cargo-dylint": "CARGO_DYLINT_VERSION",
    "cargo-fuzz": "CARGO_FUZZ_VERSION",
    "cargo-hack": "CARGO_HACK_VERSION",
    "cargo-hakari": "CARGO_HAKARI_VERSION",
    "cargo-llvm-cov": "CARGO_LLVM_COV_VERSION",
    "cargo-mutants": "CARGO_MUTANTS_VERSION",
    "cargo-shear": "CARGO_SHEAR_VERSION",
    "cargo-zigbuild": "CARGO_ZIGBUILD_VERSION",
    "codebook-lsp": "CODEBOOK_LSP_VERSION",
    "sccache": "SCCACHE_VERSION",
    "dylint-link": "DYLINT_LINK_VERSION",
    "boltffi_cli": "BOLTFFI_VERSION",
    "node": "NODE_TOOLS_VERSION",
    "uv": "UV_VERSION",
}


class ToolchainVersionSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dockerfile = DOCKERFILE.read_text()
        cls.config = tomllib.loads(TOOLCHAIN.read_text())
        cls.renovate = json.loads(RENOVATE.read_text())

    def test_duplicate_build_args_are_removed_and_versions_are_derived(self) -> None:
        for tool, argument in DOCKER_ARGS.items():
            with self.subTest(tool=tool):
                self.assertNotRegex(self.dockerfile, rf"(?m)^ARG {argument}=")
                self.assertIn(
                    f'read-mise-tool-version /tmp/jackin-mise/mise.toml tools.{tool}',
                    self.dockerfile,
                )
                self.assertIn(tool, self.config["tools"])

    def test_changed_config_values_flow_through_mise_config_get(self) -> None:
        mise = shutil.which("mise")
        if mise is None:
            self.skipTest("Mise is required to exercise config get")

        fixture = """\
[tools]
cargo-audit = "0.22.3"
node = "24.22.0"
uv = "0.13.0"
"""
        expected = {
            "cargo-audit": "0.22.3",
            "node": "24.22.0",
            "uv": "0.13.0",
        }

        with tempfile.TemporaryDirectory(prefix="architect-mise-version-") as temp:
            root = Path(temp)
            config = root / "mise.toml"
            config.write_text(fixture)
            env = {
                "HOME": str(root / "home"),
                "PATH": f"{os.path.dirname(mise)}:/usr/bin:/bin",
                "MISE_NO_CONFIG": "1",
                "MISE_NO_ENV": "1",
                "MISE_NO_HOOKS": "1",
                "MISE_DISABLE_UPDATE_WARNING": "1",
            }
            (root / "home").mkdir()

            for tool, version in expected.items():
                with self.subTest(tool=tool):
                    result = subprocess.run(
                        [
                            str(VERSION_READER),
                            str(config),
                            f"tools.{tool}",
                        ],
                        check=True,
                        capture_output=True,
                        text=True,
                        env=env,
                    )
                    self.assertEqual(result.stdout, f"{version}\n")

    def test_unsupported_asset_version_fails_closed_before_download(self) -> None:
        # An updated Mise file selects the new version automatically. Until its
        # architecture-specific checksum is reviewed and allowlisted, the
        # package/version/architecture case must stop before curl can run.
        self.assertNotIn("cargo-audit@0.22.3", self.dockerfile)
        case_start = self.dockerfile.index('case "${package}@${version}:${TARGETARCH}" in')
        fail_closed = self.dockerfile.index(
            '*) echo "unsupported pinned prebuilt Cargo tool:', case_start
        )
        download = self.dockerfile.index('curl -q -fsSL', case_start)
        self.assertLess(case_start, fail_closed)
        self.assertLess(fail_closed, download)
        self.assertIn("return 1", self.dockerfile[fail_closed:download])
        run_start = self.dockerfile.rfind("\nRUN ", 0, case_start)
        self.assertIn("set -eu;", self.dockerfile[run_start:case_start])

        function_start = self.dockerfile.index("install_prebuilt_cargo_tool() {")
        function_end = self.dockerfile.index(
            "\n    install_mbx_cargo_tool()", function_start
        )
        function_lines = []
        for line in self.dockerfile[function_start:function_end].splitlines():
            line = line.rstrip()
            if line.endswith("\\"):
                line = line[:-1]
            function_lines.append(line)
        script = "\n".join(
            [
                "set -eu",
                'TARGETARCH="${TARGETARCH:?}"',
                'curl() { : > "${CURL_MARKER:?}"; return 90; }',
                *function_lines,
                "install_prebuilt_cargo_tool cargo-audit 0.22.3",
            ]
        )
        with tempfile.TemporaryDirectory(prefix="architect-unsupported-pin-") as temp:
            marker = Path(temp) / "curl-was-called"
            result = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                env={
                    "HOME": temp,
                    "PATH": "/usr/bin:/bin",
                    "TARGETARCH": "amd64",
                    "CURL_MARKER": str(marker),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported pinned prebuilt Cargo tool", result.stderr)
            self.assertFalse(marker.exists())

    def test_prebuilt_matrix_keeps_both_architectures(self) -> None:
        entries = set(
            re.findall(
                r"([a-z0-9-]+)@([0-9.]+):(amd64|arm64)", self.dockerfile
            )
        )
        by_package_version: dict[tuple[str, str], set[str]] = {}
        for package, version, arch in entries:
            by_package_version.setdefault((package, version), set()).add(arch)

        self.assertTrue(by_package_version)
        for (package, version), arches in by_package_version.items():
            with self.subTest(package=package, version=version):
                if package in {"cargo-fuzz", "cargo-mutants"}:
                    self.assertEqual(arches, {"amd64"})
                    self.assertIn(
                        f'install_mbx_cargo_tool {package} "${{{DERIVED_TOOLS[package]}}}"',
                        self.dockerfile,
                    )
                else:
                    self.assertEqual(arches, {"amd64", "arm64"})

    def test_other_download_checksum_matrices_key_version_and_arch(self) -> None:
        for tool, selector in (
            ("sccache", "sccache_version"),
            ("boltffi_cli", "boltffi_version"),
        ):
            version = self.config["tools"][tool]
            self.assertIsInstance(version, str)
            with self.subTest(tool=tool, version=version):
                self.assertIn(
                    f'case "${{{selector}}}:${{TARGETARCH}}" in', self.dockerfile
                )
                entries = set(
                    re.findall(
                        rf"{re.escape(version)}:(amd64|arm64)\)",
                        self.dockerfile,
                    )
                )
                self.assertEqual(entries, {"amd64", "arm64"})

    def test_renovate_arg_managers_only_match_existing_build_args(self) -> None:
        for manager in self.renovate["customManagers"]:
            for match_string in manager["matchStrings"]:
                match = re.search(r"ARG ([A-Z][A-Z0-9_]*)=", match_string)
                if match is not None:
                    with self.subTest(argument=match.group(1)):
                        self.assertRegex(
                            self.dockerfile,
                            rf"(?m)^ARG {re.escape(match.group(1))}=",
                        )

    def test_readme_describes_current_update_paths(self) -> None:
        readme = (ROOT / "README.md").read_text()
        self.assertNotIn("scheduled `Jackin Toolchain` workflow", readme)
        self.assertNotIn("CAVEMAN_VERSION", readme)
        self.assertIn("commit, tree, and source-archive SHA-256", readme)


if __name__ == "__main__":
    unittest.main()
