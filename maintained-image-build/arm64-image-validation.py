#!/usr/bin/python3
"""Build and validate the Architect image on a native Linux ARM64 host."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Sequence


CONTEXT_EXACT_FILES = frozenset(
    {
        ".dockerignore",
        "Dockerfile",
        "caveman-config.json",
        "maintained-image-build/skills-cli/package.json",
        "maintained-image-build/skills-cli/package-lock.json",
    }
)
CONTEXT_PREFIXES = ("AGENTS.md.d/", "jackin-toolchain/")
CONTEXT_REQUIRED_FILES = CONTEXT_EXACT_FILES | frozenset(
    {
        "AGENTS.md.d/caveman.md",
        "AGENTS.md.d/token-tools.md",
        "jackin-toolchain/mise.toml",
        "jackin-toolchain/rust-toolchain.toml",
    }
)
CARGO_TOOL_VERSIONS = {
    "cargo-audit": "0.22.2",
    "cargo-deny": "0.20.2",
    "cargo-dylint": "6.0.4",
    "cargo-fuzz": "0.13.2",
    "cargo-hack": "0.6.45",
    "cargo-hakari": "0.9.38",
    "cargo-llvm-cov": "0.8.7",
    "cargo-mutants": "27.1.0",
    "cargo-shear": "1.13.4",
    "cargo-zigbuild": "0.23.0",
    "codebook-lsp": "0.3.42",
    "dylint-link": "6.0.4",
    "sccache": "0.17.0",
}
SKILL_SHA256 = {
    "cavecrew": "c05f8e8d16bd8ae1c8d0b0abf6e8b9671051bde61653c4986304c2de3a1cf5d4",
    "caveman-commit": "c788a282fc75b981b421dfdad5d84ea7f83f946c126daa39cfc7d3f97845e193",
    "caveman-compress": "377b0b8682d9db1a832c20ee6732ed0f19f55e4f7048955296128244c869c916",
    "caveman-discover": "0483d17fce14ca5bbfcf1e085c180412dc20a672f5e8e4171fd0bbbb6f42b81a",
    "caveman-evidence-review": "05bd896c76a41918fe7b87113dabe852117727a579a7e445891aa41391ed57c2",
    "caveman-explore": "908f504ce45f5f8517ac7b64dc89fef57c4519d26f92b0b1843febf4b6fe2ac8",
    "caveman-help": "3effbc5b8943900c7500da48f73ab9de297866705c105df1b324d4337dec3a9a",
    "caveman-learn": "8b210c266f5c14cfded85b1c32b3742b4b23b4a0628b9cafa6627fd954609026",
    "caveman-manage": "3404a3c8651d63b6a7c02ccda17fcb4fca2489e931bb814580979a9ff548a48e",
    "caveman-optimize": "93f391beb93198b5bf9c0c21bc8b7b194e57cb7855fbf05384a4a5d6dd8c06cb",
    "caveman-review": "599330563f19b5c59c3efddffcd7e8d9098b74c29817ab422ccd3253b103fcb8",
    "caveman-setup": "42c8b8eeba19c6d4ffd3c421be60a7e8b5c0e5108fd4496f0be3c7ced90bfd5f",
    "caveman-stats": "4632f1611a56483df7851a0dabcc1e0c1952393cd8f5d08ddeda17f81a4e1e50",
    "caveman": "0bf09a0a9a017d004a81d4b693e5a2d830e1a28230a5885df773e1ed9c0571cc",
    "investigate-first": "7cc19dd2fc457eb20d65c44dee4d1b72dcdfcd1617182f5bff666700f2a055d8",
    "lean-build": "4d498073c6312858b220e9a04b7456c2485c734edb077f6bb17d88a7ed96ad7a",
    "migration": "fe7cf96a58b0521130fbb886dab2a326869d6ed0001e0306fd244014ba7a9662",
    "safe-refactor": "cd52867aba26aafb53379d43068cef9b2feca3a3fff850f877a99f710ccd02c0",
    "surgical-patch": "81ea9f7b51409970099e04b98875dd65806cd35472f9a774b847030328187387",
    "verify-and-stop": "3d5599f49771b864eba94f27f456fda295c48c1a37fa6ba2f65fdcb13cc32acb",
    "jackin-brainstorm": "afda534174a35c7da4a39d3982849e05f1f123fcb732d681cdf6a6bb71e8a329",
    "jackin-checkout-pr": "288ddb285e18b63847520269318849599d078d9cce72793a2222bb30b5de17f8",
    "jackin-create-pr": "48ad3f63686e8d9864a8f739566846d48adce97c110f5af4fa36701df48e149d",
    "jackin-goal-prompt": "b6657734102dcabca3a74104e67d4dbbb0c2876a6d184a8984c4ab7be6ac6d94",
    "jackin-merge-pr": "60d1c1c8de6185173d19b803d047e1aba032cfc2f658cd0252d9a9675a0d8dc0",
    "jackin-propose": "57f86f3654b317e24a52ae686a08eae3512aca43716983a7e6bd612feb221372",
    "jackin-refresh-pr": "e26be1eb234040ffbc1780cc949a42b84a5d18a3ec75e361d45900c9ad0ac048",
    "jackin-release-check": "c6b9fda70e51abb13280270263b36027298199da290a1ded8bb15afff3d0a7db",
    "jackin-release-notes": "2e76f3efb58ed87e26959af9ffb9a00ddf068d61cd72e6c3aec5249edb9020c4",
    "jackin-release": "2573a491fa5317e12a841d403f60429b1a94d3081b630127b7c0c25b415971a7",
    "jackin-research": "1a0b545acdd234b3de6592f3871a359e6163cb7829b115f6c09cd8fcb5352bfc",
    "improve": "1599aa29e9b16424cb767779efac53fa56e3f38be92dff4ac587393a1ad5070a",
}
PLUGIN_SHA256 = "8892c69b346b87be0709274c772bca295aba62003dc0f9fe22bcbddf88408f7a"
CRATE_SOURCE_SHA256 = {
    "cargo-fuzz": "5acfd01930e49823e58c30dd8012d3338a620377d7c7d4cc140ca4b2169400e2",
    "cargo-mutants": "07072e7bcdeb425d5e5fdbfd9f15a2c749e23cb2edf5ef40aee5876760ae1cf9",
}
GIT_BIN = Path("/usr/bin/git")
BUILD_PLATFORM = "linux/arm64"
BUILD_JOBS = "2"
MISE_JOBS = "1"
BUILD_MEMORY = "6g"
BUILD_CPU_QUOTA = "200000"
BUILD_CPU_PERIOD = "100000"
BUILD_TIMEOUT_SECONDS = 42 * 60
PROBE_TIMEOUT_SECONDS = 4 * 60
COMMAND_TIMEOUT_SECONDS = 20
TERM_GRACE_SECONDS = 1.0
RUNTIME_TMPFS = "/tmp:rw,noexec,nosuid,nodev,size=2g"
RUNTIME_HOME = "/home/agent"
PROBE_ROOT = "/home/agent/.cache/architect-image-probe"
NATIVE_IMAGE_TASK_ID = "architect-arm64-image"


class ValidationError(RuntimeError):
    """The host or image did not satisfy the reviewed validation contract."""


class CancellationRequested(Exception):
    """The hosted job was cancelled and owned children must be reaped."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_object_digest(kind: str, data: bytes, object_format: str) -> str:
    if object_format not in {"sha1", "sha256"}:
        raise ValidationError(f"unsupported Git object format: {object_format}")
    header = f"{kind} {len(data)}\0".encode("ascii")
    return hashlib.new(object_format, header + data).hexdigest()


def clean_git_env(home: Path) -> dict[str, str]:
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_LFS_SKIP_SMUDGE": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
    }


def git_output(repo: Path, args: Sequence[str], home: Path) -> str:
    completed = subprocess.run(
        [str(GIT_BIN), "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=clean_git_env(home),
        text=True,
    )
    if completed.returncode != 0:
        raise ValidationError(f"Git command failed: {args!r}: {completed.stderr.strip()}")
    return completed.stdout.strip()


def git_bytes(repo: Path, args: Sequence[str], home: Path) -> bytes:
    completed = subprocess.run(
        [str(GIT_BIN), "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=clean_git_env(home),
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise ValidationError(f"Git command failed: {args!r}: {detail}")
    return completed.stdout


def verify_source(repo: Path, expected_commit: str, git_home: Path) -> tuple[str, str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", expected_commit):
        raise ValidationError("GITHUB_SHA is not a full lowercase commit ID")
    head = git_output(repo, ["rev-parse", "--verify", "HEAD^{commit}"], git_home)
    if head != expected_commit:
        raise ValidationError(f"checkout HEAD differs from GITHUB_SHA: {head}")
    object_format = git_output(repo, ["rev-parse", "--show-object-format"], git_home)
    commit_data = git_bytes(repo, ["cat-file", "commit", expected_commit], git_home)
    if git_object_digest("commit", commit_data, object_format) != expected_commit:
        raise ValidationError("raw commit bytes do not match GITHUB_SHA")
    tree_line = next((line for line in commit_data.splitlines() if line.startswith(b"tree ")), None)
    if tree_line is None:
        raise ValidationError("commit object has no root tree")
    tree = tree_line[5:].decode("ascii", "strict")
    tree_data = git_bytes(repo, ["cat-file", "tree", tree], git_home)
    if git_object_digest("tree", tree_data, object_format) != tree:
        raise ValidationError("raw tree bytes do not match the commit root tree ID")
    return expected_commit, tree, object_format


def path_is_allowed(path: str) -> bool:
    if not path or any(
        component in {"", ".", ".."}
        or not re.fullmatch(r"[A-Za-z0-9._-]+", component)
        for component in path.split("/")
    ):
        return False
    return path in CONTEXT_EXACT_FILES or any(
        path.startswith(prefix) and len(path) > len(prefix) for prefix in CONTEXT_PREFIXES
    )


def materialize_tree_context(
    repo: Path, tree: str, object_format: str, destination: Path, git_home: Path
) -> dict[str, object]:
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    tree_data = git_bytes(repo, ["cat-file", "tree", tree], git_home)
    if git_object_digest("tree", tree_data, object_format) != tree:
        raise ValidationError("raw context tree bytes do not match the reviewed tree ID")
    listing = git_bytes(
        repo,
        ["ls-tree", "-rz", "--full-tree", "-r", tree, "--", *CONTEXT_PREFIXES, *sorted(CONTEXT_EXACT_FILES)],
        git_home,
    )
    seen: set[str] = set()
    for record in listing.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode_bytes, kind_bytes, oid_bytes = metadata.split(b" ")
            name = raw_path.decode("utf-8", "strict")
            mode = mode_bytes.decode("ascii")
            kind = kind_bytes.decode("ascii")
            oid = oid_bytes.decode("ascii")
        except (ValueError, UnicodeError) as error:
            raise ValidationError(f"malformed raw Git tree record: {record!r}") from error
        path = PurePosixPath(name)
        if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
            raise ValidationError(f"unsafe path in source tree: {name!r}")
        if not path_is_allowed(name) or name in seen:
            raise ValidationError(f"unexpected or duplicate context path: {name}")
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise ValidationError(f"unsupported context entry: {mode} {kind} {name}")
        if len(oid) != {"sha1": 40, "sha256": 64}.get(object_format):
            raise ValidationError(f"blob ID does not match Git object format: {name}")
        data = git_bytes(repo, ["cat-file", "blob", oid], git_home)
        if git_object_digest("blob", data, object_format) != oid:
            raise ValidationError(f"raw blob bytes do not match tree entry: {name}")
        target = destination.joinpath(*path.parts)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        file_mode = 0o755 if mode == "100755" else 0o644
        descriptor = os.open(target, flags, file_mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        target.chmod(file_mode)
        seen.add(name)
    missing = CONTEXT_REQUIRED_FILES - seen
    if missing:
        raise ValidationError(f"required source paths absent from tree: {sorted(missing)}")
    return context_manifest(destination)


def context_manifest(destination: Path) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    for current, directory_names, file_names in os.walk(destination, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in [*directory_names, *file_names]:
            path = Path(current) / name
            relative = path.relative_to(destination).as_posix()
            if path.is_symlink():
                raise ValidationError(f"symlink in raw context: {relative}")
            if path.is_dir():
                allowed_directory = any(
                    relative == prefix.rstrip("/") or relative.startswith(prefix)
                    for prefix in CONTEXT_PREFIXES
                ) or relative in {"maintained-image-build", "maintained-image-build/skills-cli"}
                if not allowed_directory:
                    raise ValidationError(f"unexpected context directory: {relative}")
                continue
            if not path_is_allowed(relative):
                raise ValidationError(f"unexpected context file: {relative}")
            mode = stat.S_IMODE(path.stat().st_mode)
            entries.append({"path": relative, "mode": f"{mode:04o}", "sha256": sha256_file(path)})
    payload = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return {"files": entries, "manifest_sha256": sha256_bytes(payload)}


def validate_dockerfile_contract(dockerfile: Path) -> None:
    source = dockerfile.read_text(encoding="utf-8")
    required = (
        "ARG TARGETARCH",
        "ARG CARGO_BUILD_JOBS=4",
        "ARG MISE_JOBS=1",
        'case "${TARGETARCH}" in',
        "cargo-fuzz@0.13.2) crate_sha256=5acfd01930e49823e58c30dd8012d3338a620377d7c7d4cc140ca4b2169400e2",
        "cargo-mutants@27.1.0) crate_sha256=07072e7bcdeb425d5e5fdbfd9f15a2c749e23cb2edf5ef40aee5876760ae1cf9",
        'mise exec -C /tmp/jackin-mise -- mbx install',
        '--locked --path "${source_root}" --root "${install_root}"',
        "test -s \"${source_root}/Cargo.lock\"",
    )
    missing = [item for item in required if item not in source]
    if missing:
        raise ValidationError(f"Dockerfile no longer satisfies ARM source-install contract: {missing}")
    flattened = re.sub(r"\\\n[ \t]*", " ", source)
    fuzz_install = flattened.find("install_mbx_cargo_tool cargo-fuzz")
    mutants_install = flattened.find("install_mbx_cargo_tool cargo-mutants")
    case_start = flattened.rfind('case "${TARGETARCH}" in', 0, fuzz_install)
    case_end = flattened.find("esac", mutants_install)
    route = flattened[case_start:case_end] if case_start >= 0 and case_end >= 0 else ""
    if (
        not route
        or "amd64)" not in route
        or "arm64)" not in route
        or not re.search(
            r'arm64\).*install_mbx_cargo_tool cargo-fuzz "\$\{CARGO_FUZZ_VERSION\}"; '
            r'.*install_mbx_cargo_tool cargo-mutants "\$\{CARGO_MUTANTS_VERSION\}"',
            route,
        )
    ):
        raise ValidationError("ARM64 Dockerfile route must install fuzz and mutants from locked sources")


def normalize_arch(value: str) -> str:
    aliases = {"aarch64": "arm64", "arm64": "arm64"}
    try:
        return aliases[value.strip().lower()]
    except KeyError as error:
        raise ValidationError(f"native ARM64 host required, received {value.strip()!r}") from error


def require_buildx_resource_flag(help_text: str) -> None:
    if not re.search(r"(?m)^\s*--resource\s+\S+", help_text):
        raise ValidationError("Docker Buildx does not expose the required --resource option")


def parse_buildx_plugin_info(output: str) -> dict[str, str]:
    parsed: object | None = None
    for line in reversed(output.splitlines()):
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, list):
            parsed = candidate
            break
    if not isinstance(parsed, list):
        raise ValidationError("Docker info did not report CLI plugins as JSON")
    entries = [item for item in parsed if isinstance(item, dict) and item.get("Name") == "buildx"]
    if len(entries) != 1:
        raise ValidationError(f"expected one Buildx plugin, found {len(entries)}")
    path = entries[0].get("Path")
    version = entries[0].get("Version")
    if not isinstance(path, str) or not Path(path).is_absolute():
        raise ValidationError("Buildx plugin path is missing or not absolute")
    if not isinstance(version, str) or not version:
        raise ValidationError("Buildx plugin version is missing")
    return {"path": path, "version": version}


def make_builder_create_argv(docker: Path, builder: str) -> list[str]:
    return [
        str(docker),
        "buildx",
        "create",
        "--name",
        builder,
        "--driver",
        "docker-container",
        "--driver-opt",
        f"memory={BUILD_MEMORY}",
        "--driver-opt",
        f"cpu-quota={BUILD_CPU_QUOTA}",
        "--driver-opt",
        f"cpu-period={BUILD_CPU_PERIOD}",
        "--bootstrap",
    ]


def make_builder_name(run_id: str, attempt: str) -> str:
    if not re.fullmatch(r"[1-9][0-9]{0,19}", run_id):
        raise ValidationError("GITHUB_RUN_ID must be a positive decimal identifier")
    if not re.fullmatch(r"[1-9][0-9]{0,5}", attempt):
        raise ValidationError("GITHUB_RUN_ATTEMPT must be a positive decimal identifier")
    name = f"vlnr-{run_id}-{attempt}-{NATIVE_IMAGE_TASK_ID}"
    if len(name) > 63:
        raise ValidationError("task-owned Buildx builder name exceeds the supported length")
    return name


def make_builder_remove_argv(docker: Path, builder: str) -> list[str]:
    return [str(docker), "buildx", "rm", "--force", builder]


def make_build_argv(docker: Path, builder: str, tag: str, context: Path) -> list[str]:
    return [
        str(docker),
        "buildx",
        "build",
        "--builder",
        builder,
        "--platform",
        BUILD_PLATFORM,
        "--no-cache",
        "--pull",
        "--load",
        "--tag",
        tag,
        "--file",
        str(context / "Dockerfile"),
        "--progress=plain",
        "--resource",
        f"memory={BUILD_MEMORY}",
        "--resource",
        f"cpu-quota={BUILD_CPU_QUOTA}",
        "--resource",
        f"cpu-period={BUILD_CPU_PERIOD}",
        "--build-arg",
        f"CARGO_BUILD_JOBS={BUILD_JOBS}",
        "--build-arg",
        f"MISE_JOBS={MISE_JOBS}",
        str(context),
    ]


def make_container_name(run_id: str, attempt: str) -> str:
    make_builder_name(run_id, attempt)
    return f"architect-{run_id}-{attempt}-{NATIVE_IMAGE_TASK_ID}"


def make_probe_create_argv(docker: Path, image_id: str, container_name: str) -> list[str]:
    validate_image_id(image_id)
    return [
        str(docker),
        "create",
        "--interactive",
        "--name",
        container_name,
        "--network=none",
        f"--platform={BUILD_PLATFORM}",
        "--cpus=1",
        "--memory=4g",
        "--pids-limit=128",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges:true",
        "--tmpfs",
        RUNTIME_TMPFS,
        "--env",
        f"CARGO_BUILD_JOBS={BUILD_JOBS}",
        "--env",
        f"MISE_JOBS={MISE_JOBS}",
        "--env",
        "MISE_EXEC_AUTO_INSTALL=0",
        "--workdir",
        RUNTIME_HOME,
        "--entrypoint=/bin/bash",
        image_id,
        "-s",
    ]


def make_probe_start_argv(docker: Path, container_id: str) -> list[str]:
    return [str(docker), "start", "--attach", "--interactive", validate_container_id(container_id)]


def validate_image_id(image_id: str) -> str:
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValidationError(f"image inspect returned an invalid immutable ID: {image_id!r}")
    return image_id


def validate_container_id(container_id: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{64}", container_id):
        raise ValidationError(f"container create returned an invalid immutable ID: {container_id!r}")
    return container_id


def make_docker_env(home: Path, config: Path, docker: Path) -> dict[str, str]:
    return {
        "HOME": str(home),
        "DOCKER_CONFIG": str(config),
        "DOCKER_BUILDKIT": "1",
        "PATH": f"{docker.parent}:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "TZ": "UTC",
    }


def make_probe_script() -> bytes:
    """Return the credential-free in-image assertions and MBX fixture builds."""
    skills = "\n".join(f"  [{name}]={digest}" for name, digest in sorted(SKILL_SHA256.items()))
    cargo_tools = "\n".join(
        f"  [{name}]={version}" for name, version in sorted(CARGO_TOOL_VERSIONS.items())
    )
    return f'''#!/bin/bash
set -euo pipefail
export MISE_EXEC_AUTO_INSTALL=0 MISE_JOBS={MISE_JOBS} CARGO_BUILD_JOBS={BUILD_JOBS}
PROBE_ROOT="{PROBE_ROOT}"
die() {{ echo "IMAGE_CHECK_FAIL: $*" >&2; exit 1; }}
printf 'IMAGE_ID uid=%s gid=%s groups=%s\\n' "$(id -u)" "$(id -g)" "$(id -G)"
test "$(id -u)" = 1000 || die 'unexpected image UID'
umask 077
test ! -L /home && test -d /home || die '/home must be a real directory'
test ! -L /tmp && test -d /tmp || die '/tmp must be a real directory'
test "$(realpath -e /tmp)" = /tmp || die '/tmp resolves elsewhere'
test "$HOME" = "$RUNTIME_HOME" || die 'unexpected agent HOME'
test ! -L "$HOME" && test -d "$HOME" || die 'agent home must be a real directory'
test "$(realpath -e "$HOME")" = "$RUNTIME_HOME" || die 'agent home resolves elsewhere'
test "$(stat -Lc '%u' "$HOME")" = "$(id -u)" || die 'agent home owner mismatch'
home_mode="$(stat -Lc '%a' "$HOME")"
(( (8#$home_mode & 0022) == 0 )) || die 'agent home is group/other writable'
if [[ ! -e "$HOME/.cache" && ! -L "$HOME/.cache" ]]; then mkdir -- "$HOME/.cache"; fi
test ! -L "$HOME/.cache" && test -d "$HOME/.cache" || die 'agent cache must be a real directory'
test "$(realpath -e "$HOME/.cache")" = "$HOME/.cache" || die 'agent cache resolves elsewhere'
test "$(stat -Lc '%u' "$HOME/.cache")" = "$(id -u)" || die 'agent cache owner mismatch'
cache_mode="$(stat -Lc '%a' "$HOME/.cache")"
(( (8#$cache_mode & 0022) == 0 )) || die 'agent cache is group/other writable'
test ! -e "$PROBE_ROOT" && test ! -L "$PROBE_ROOT" || die 'probe directory already exists'
mkdir "$PROBE_ROOT"
test "$(stat -Lc '%a' "$PROBE_ROOT")" = 700 || die 'probe directory is not private'
test "$(stat -Lc '%u' "$PROBE_ROOT")" = "$(id -u)" || die 'probe directory owner mismatch'
test "$(realpath -e "$PROBE_ROOT")" = "$PROBE_ROOT" || die 'probe directory resolves elsewhere'
mount_line() {{ awk -v target="$1" '$5 == target {{ print; found=1 }} END {{ if (!found) exit 1 }}' /proc/self/mountinfo; }}
tmp_line="$(mount_line /tmp)" || die '/tmp mount is missing'
tmp_options="$(awk '{{ print $6 }}' <<<"$tmp_line")"
for option in noexec nosuid nodev; do [[ ",$tmp_options," == *",$option,"* ]] || die "/tmp lacks $option"; done
printf 'TMP_MOUNT %s\\n' "$tmp_line"
check_prefix() {{ local name="$1" expected="$2" actual="$3"; printf 'VERSION %s %s\\n' "$name" "$actual"; [[ "$actual" == "$expected"* ]] || die "$name version mismatch: $actual"; }}
check_prefix mise '2026.9.18 ' "$(mise --version)"
check_prefix rustc 'rustc 1.98.1' "$(mise exec --deny-net -- rustc --version)"
check_prefix node 'v24.21.0' "$(mise exec --deny-net -- node --version)"
check_prefix npm '11.19.0' "$(mise exec --deny-net -- npm --version)"
check_prefix mbx 'mbx 1.22.0' "$(mise exec --deny-net -- mbx --version)"
declare -A expected_tool_version=(
{cargo_tools}
)
for tool in "${{!expected_tool_version[@]}}"; do
  tool_path="$(mise which "$tool")"
  tool_version="$(mise which "$tool" --version)"
  test "$tool_version" = "${{expected_tool_version[$tool]}}" || die "$tool version mismatch: $tool_version"
  expected_path="$HOME/.local/share/mise/installs/$tool/$tool_version/bin/$tool"
  test "$tool_path" = "$expected_path" || die "$tool escaped its Mise install: $tool_path"
  test -x "$tool_path" || die "$tool is not executable"
  printf 'CARGO_TOOL %s version=%s path=%s sha256=%s\\n' "$tool" "$tool_version" "$tool_path" "$(sha256sum "$tool_path" | awk '{{print $1}}')"
done
for pair in 'cargo-fuzz:cargo-fuzz 0.13.2' 'cargo-mutants:cargo-mutants 27.1.0'; do
  tool="${{pair%%:*}}"; expected="${{pair#*:}}"; tool_path="$(mise which "$tool")"
  actual="$("$tool_path" --version)"
  [[ "$actual" == "$expected"* ]] || die "$tool binary version mismatch: $actual"
  printf 'ARM_MBX_TOOL %s\\n' "$actual"
done
mise_config="$HOME/.config/mise/config.toml"
grep -Eq 'mr_boxington[[:space:]]*=[[:space:]]*true' "$mise_config" || die 'native MBX option missing'
grep -Eq 'mr-boxington[[:space:]]*=[[:space:]]*"1\\.22\\.0"' "$mise_config" || die 'native MBX pin missing'
cargo_dispatch="$(mise exec --deny-net -- sh -c 'command -v cargo')"
expected_dispatch="$HOME/.local/share/mise/command-wrappers/bin/cargo"
test "$cargo_dispatch" = "$expected_dispatch" || die "Cargo bypasses Mise wrapper: $cargo_dispatch"
test "$(readlink -f "$cargo_dispatch")" = "$(readlink -f "$(command -v mise)")" || die 'Cargo wrapper target is not Mise'
check_prefix wrapped-cargo 'cargo ' "$(mise exec --deny-net -- cargo --version)"
printf 'MBX_WRAPPER path=%s real=%s\\n' "$cargo_dispatch" "$(readlink -f "$cargo_dispatch")"
printf 'CODEX_RUNTIME NOT_RUN; installed by Jackin in the derived agent image\\n'
test -x "$HOME/.local/share/architect-node-tools/node_modules/.bin/skills" || die 'skills CLI missing'
test -x "$HOME/.local/share/architect-node-tools/node_modules/.bin/ctx7" || die 'ctx7 package executable missing'
skills_version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$HOME/.local/share/architect-node-tools/node_modules/skills/package.json")"
ctx7_version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$HOME/.local/share/architect-node-tools/node_modules/ctx7/package.json")"
test "$skills_version" = 1.5.22 && test "$ctx7_version" = 0.5.11 || die 'Node package pin mismatch'
printf 'PACKAGE_VERSION skills=%s ctx7=%s (ctx7 CLI not invoked)\\n' "$skills_version" "$ctx7_version"
test "$CAVEMAN_DEFAULT_MODE" = ultra || die 'Caveman mode mismatch'
node -e 'const c=require(process.argv[1]); if(c.defaultMode !== "ultra") process.exit(1)' "$HOME/.config/caveman/config.json" || die 'Caveman configuration mismatch'
check_file() {{ local file="$1" digest="$2"; test ! -L "$file" && test -f "$file" || die "missing or symlinked $file"; test "$(stat -Lc '%u' "$file")" = "$(id -u)" || die "owner mismatch $file"; mode="$(stat -Lc '%a' "$file")"; (( (8#$mode & 0022) == 0 )) || die "group/other writable $file"; actual="$(sha256sum "$file" | awk '{{print $1}}')"; test "$actual" = "$digest" || die "digest mismatch $file"; printf 'FILE_OK %s mode=%s sha256=%s\\n' "$file" "$mode" "$actual"; }}
check_file "$HOME/.config/opencode/plugins/caveman/plugin.js" {PLUGIN_SHA256}
grep -Rq caveman "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc" 2>/dev/null || die 'OpenCode Caveman entry missing'
declare -A expected_skill_sha=(
{skills}
)
for skill in "${{!expected_skill_sha[@]}}"; do
  check_file "$HOME/.agents/skills/$skill/SKILL.md" "${{expected_skill_sha[$skill]}}"
done
check_file "$HOME/.claude/skills/improve/SKILL.md" "${{expected_skill_sha[improve]}}"
count="$(find "$HOME/.agents/skills" -mindepth 2 -maxdepth 2 -type f -name SKILL.md | wc -l | tr -d ' ')"
test "$count" = 32 || die "expected 32 universal skills, got $count"
for agent in cavecrew-builder cavecrew-investigator cavecrew-reviewer; do
  file="$HOME/.config/opencode/agents/$agent.md"
  test -r "$file" || die "OpenCode agent missing $agent"
  ! grep -Eq '^(tools|model):' "$file" || die "provider metadata remains in $agent"
done
printf 'SKILL_COUNTS caveman=20 jackin-dev=11 shadcn-improve=1 universal-files=%s\\n' "$count"
check_stats() {{
  local file="$1" label="$2" parsed schema hits misses unconsulted verifications bypasses reasons total digest mode
  test -f "$file" || die "$label MBX stats missing"
  test "$(stat -Lc '%u' "$file")" = "$(id -u)" || die "$label stats owner mismatch"
  mode="$(stat -Lc '%a' "$file")"; (( (8#$mode & 0022) == 0 )) || die "$label stats mode is unsafe"
  digest="$(sha256sum "$file" | awk '{{print $1}}')"
  parsed="$(mise exec --deny-net -- node -e '
const fs=require("node:fs"); const r=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if (!r || typeof r !== "object" || Array.isArray(r) || r.version !== 5) throw new Error("schema");
const keys=["hits","misses","unconsulted","verifications"];
for (const k of keys) if (!Number.isSafeInteger(r[k]) || r[k] < 0) throw new Error(k);
if (!r.bypasses || typeof r.bypasses !== "object" || Array.isArray(r.bypasses)) throw new Error("bypasses");
let b=0; const e=Object.entries(r.bypasses).sort(([a],[c])=>a<c?-1:a>c?1:0);
for (const [k,v] of e) {{ if (!Number.isSafeInteger(v)||v<0) throw new Error(k); b+=v; if(!Number.isSafeInteger(b))throw new Error("overflow"); }}
const t=r.hits+r.misses+r.unconsulted+r.verifications+b; if(!Number.isSafeInteger(t)||t<1)throw new Error("empty");
process.stdout.write([r.version,r.hits,r.misses,r.unconsulted,r.verifications,b,JSON.stringify(e)].join("\\t"));' "$file")" || die "$label stats invalid"
  IFS=$'\\t' read -r schema hits misses unconsulted verifications bypasses reasons <<< "$parsed"
  total=$((hits + misses + unconsulted + verifications + bypasses))
  test "$schema" = 5 && test "$total" -gt 0 || die "$label stats summary invalid"
  printf 'MBX_STATS %s schema=%s hits=%s misses=%s unconsulted=%s verifications=%s bypasses=%s reasons=%s sha256=%s\\n' "$label" "$schema" "$hits" "$misses" "$unconsulted" "$verifications" "$bypasses" "$reasons" "$digest"
  MBX_HITS=$((MBX_HITS + hits))
}}
MBX_HITS=0
write_bin_fixture() {{
  local name="$1" message="$2" root="$PROBE_ROOT/$name"
  mkdir -p "$root/src"
  cat > "$root/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
edition = "2021"
EOF
  cat > "$root/Cargo.lock" <<EOF
version = 4

[[package]]
name = "$name"
version = "0.1.0"
EOF
  cat > "$root/src/main.rs" <<EOF
fn main() {{ println!("$message"); }}
EOF
}}
write_lib_fixture() {{
  local name="$1" root="$PROBE_ROOT/$1"
  mkdir -p "$root/src"
  cat > "$root/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
edition = "2021"
EOF
  cat > "$root/Cargo.lock" <<EOF
version = 4

[[package]]
name = "$name"
version = "0.1.0"
EOF
  cat > "$root/src/lib.rs" <<EOF
pub fn marker() -> &'static str {{ "$name" }}
EOF
}}
MBX_HITS=0
write_bin_fixture architect_arm64_mbx_probe MBX_ARM64_EXPLICIT_OK
explicit_stats="$PROBE_ROOT/explicit-stats.json"
rm -f -- "$explicit_stats"
(
  cd /tmp
  CARGO_TARGET_DIR="$PROBE_ROOT/target-explicit" MBX_STATS_REPORT="$explicit_stats" \\
    mise exec --deny-net -- mbx build --locked --offline --manifest-path "$PROBE_ROOT/architect_arm64_mbx_probe/Cargo.toml"
)
check_stats "$explicit_stats" explicit
binary="$PROBE_ROOT/target-explicit/debug/architect_arm64_mbx_probe"
test -x "$binary" || die 'explicit MBX build did not create an executable'
test "$("$binary")" = MBX_ARM64_EXPLICIT_OK || die 'explicit MBX binary output differs'
write_lib_fixture architect_arm64_mise_cargo_probe
wrapper_target="$PROBE_ROOT/target-wrapper"
cold_stats="$PROBE_ROOT/wrapper-cold.json"
rm -f -- "$cold_stats"
(
  cd /tmp
  CARGO_TARGET_DIR="$wrapper_target" MBX_STATS_REPORT="$cold_stats" \\
    mise exec --deny-net -- cargo check --lib --locked --offline --manifest-path "$PROBE_ROOT/architect_arm64_mise_cargo_probe/Cargo.toml"
)
check_stats "$cold_stats" wrapper-cold
rm -rf -- "$wrapper_target"
hits_before_warm="$MBX_HITS"
warm_stats="$PROBE_ROOT/wrapper-warm.json"
rm -f -- "$warm_stats"
(
  cd /tmp
  CARGO_TARGET_DIR="$wrapper_target" MBX_STATS_REPORT="$warm_stats" \\
    mise exec --deny-net -- cargo check --lib --locked --offline --manifest-path "$PROBE_ROOT/architect_arm64_mise_cargo_probe/Cargo.toml"
)
check_stats "$warm_stats" wrapper-warm
test "$MBX_HITS" -gt "$hits_before_warm" || die 'fresh-target repeat produced no MBX cache hit'
metadata="$(find "$wrapper_target/debug/deps" -maxdepth 1 -type f -name 'libarchitect_arm64_mise_cargo_probe-*.rmeta' -print -quit)"
test -n "$metadata" || die 'wrapped cargo check did not create metadata'
printf 'MBX_WARM_CACHE_HIT PASS hits=%s fresh_target=yes\\n' "$MBX_HITS"
printf 'IMAGE_VALIDATION PASS native ARM64; no network/auth/model/context7 invocation\\n'
'''.encode()


def require_builder_arm64(output: str) -> None:
    match = re.search(r"(?m)^Platforms:\s*(.+)$", output)
    if match is None or BUILD_PLATFORM not in {item.strip() for item in match.group(1).split(",")}:
        raise ValidationError("task-owned Buildx builder does not report native linux/arm64")


def validate_image_id_from_log(path: Path) -> str:
    return validate_image_id(path.read_text(encoding="utf-8").strip())


def verify_arm_fallback_build_log(path: Path) -> None:
    log = path.read_text(encoding="utf-8", errors="replace")
    required = (
        "Compiling cargo-fuzz v0.13.2",
        "Compiling cargo-mutants v27.1.0",
    )
    missing = [marker for marker in required if marker not in log]
    if missing:
        raise ValidationError(f"ARM BuildKit log does not prove source compilation: {missing}")
    cache_summaries = log.count("mbx[cache]:")
    if cache_summaries < 2:
        raise ValidationError(f"ARM BuildKit log has only {cache_summaries} MBX cache summaries")
    for marker in required:
        for line in log.splitlines():
            if marker in line:
                print(f"ARM_SOURCE_COMPILE {line.strip()}")


def tail_log(path: Path, limit: int = 12000) -> str:
    try:
        with path.open("rb") as stream:
            stream.seek(max(0, path.stat().st_size - limit))
            return stream.read().decode("utf-8", "replace")
    except OSError:
        return ""


def process_group_exists(group: int) -> bool:
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    group = process.pid
    previous_handlers = {
        signum: signal.signal(signum, signal.SIG_IGN)
        for signum in (signal.SIGTERM, signal.SIGINT)
    }
    try:
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + TERM_GRACE_SECONDS
        while process_group_exists(group) and time.monotonic() < deadline:
            try:
                process.wait(timeout=0.05)
            except subprocess.TimeoutExpired:
                pass
            time.sleep(0.05)
        if process_group_exists(group):
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait()
    finally:
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        for signum, previous_handler in previous_handlers.items():
            signal.signal(signum, previous_handler)


def run_bounded(
    label: str,
    argv: Sequence[str],
    env: dict[str, str],
    log_path: Path,
    timeout_seconds: int,
    stdin_bytes: bytes | None = None,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    log_path.touch(mode=0o600, exist_ok=False)
    start = time.monotonic()
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.PIPE if stdin_bytes is not None else subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
            close_fds=True,
        )
        try:
            process.communicate(input=stdin_bytes, timeout=timeout_seconds)
            status = process.returncode
            if status is None:
                raise ValidationError(f"{label} exited without a status")
        except subprocess.TimeoutExpired as error:
            terminate_process_group(process)
            raise ValidationError(f"{label} timed out; log={log_path}\n{tail_log(log_path)}") from error
        except BaseException:
            terminate_process_group(process)
            raise
    elapsed = round(time.monotonic() - start, 3)
    print(json.dumps({"label": label, "argv": list(argv), "status": status, "elapsed_seconds": elapsed}))
    if status != 0:
        raise ValidationError(f"{label} failed ({status}); log={log_path}\n{tail_log(log_path)}")
    return status


def signal_to_cancellation(_signum: int, _frame: object) -> None:
    raise CancellationRequested("workflow cancellation requested")


def require_no_symlink_ancestors(path: Path) -> Path:
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError as error:
            raise ValidationError(f"path component does not exist: {current}") from error
        if stat.S_ISLNK(info.st_mode):
            raise ValidationError(f"symlink in path ancestry: {current}")
    return absolute


def validate_runner_directory(path: Path, label: str) -> Path:
    absolute = require_no_symlink_ancestors(path)
    info = absolute.stat(follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        raise ValidationError(f"{label} is not a real directory: {absolute}")
    if info.st_uid != os.getuid():
        raise ValidationError(f"{label} has an unexpected owner: {absolute}")
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise ValidationError(f"{label} is writable by another principal: {absolute}")
    return absolute


def docker_output(
    label: str,
    argv: Sequence[str],
    env: dict[str, str],
    path: Path,
    timeout_seconds: int = COMMAND_TIMEOUT_SECONDS,
) -> str:
    run_bounded(label, argv, env, path, timeout_seconds)
    return path.read_text(encoding="utf-8", errors="replace").strip()


def remove_owned_container(
    docker: Path,
    container_name: str,
    captured_container_id: str | None,
    env: dict[str, str],
    run_root: Path,
) -> str:
    listed = docker_output(
        "find-owned-container",
        [
            str(docker),
            "ps",
            "--all",
            "--no-trunc",
            "--quiet",
            "--filter",
            f"name=^/{container_name}$",
        ],
        env,
        run_root / "cleanup-container-list.log",
    )
    if not listed:
        return "already-absent"
    matches = listed.splitlines()
    if len(matches) != 1:
        raise ValidationError(f"Docker container filter returned unexpected IDs: {matches!r}")
    container_id = validate_container_id(matches[0])
    if captured_container_id is not None and container_id != captured_container_id:
        raise ValidationError("named runtime container no longer has its captured immutable ID")
    run_bounded(
        "remove-owned-container",
        [str(docker), "rm", "--force", container_id],
        env,
        run_root / "cleanup-container.log",
        COMMAND_TIMEOUT_SECONDS,
    )
    return "removed"


def remove_owned_builder(
    docker: Path, builder: str, env: dict[str, str], run_root: Path
) -> str:
    names = list_builders(docker, env, run_root, "cleanup-builders.log")
    if builder not in names:
        return "already-absent"
    run_bounded(
        "remove-owned-buildx-builder",
        make_builder_remove_argv(docker, builder),
        env,
        run_root / "cleanup-builder.log",
        COMMAND_TIMEOUT_SECONDS,
    )
    return "removed-cache-and-daemon"


def list_builders(
    docker: Path, env: dict[str, str], run_root: Path, log_name: str
) -> set[str]:
    listing = docker_output(
        "list-buildx-builders",
        [str(docker), "buildx", "ls", "--format", "{{.Name}}"],
        env,
        run_root / log_name,
    )
    return {line.removesuffix("*") for line in listing.splitlines()}


def find_owned_image(
    docker: Path,
    tag: str,
    env: dict[str, str],
    run_root: Path,
    log_name: str = "cleanup-images.log",
) -> str | None:
    listing = docker_output(
        "find-owned-image",
        [
            str(docker),
            "image",
            "ls",
            "--quiet",
            "--no-trunc",
            "--filter",
            f"reference={tag}",
        ],
        env,
        run_root / log_name,
    )
    if not listing:
        return None
    ids = listing.splitlines()
    if len(ids) != 1:
        raise ValidationError(f"unique image tag resolved to multiple IDs: {ids!r}")
    return validate_image_id(ids[0])


def docker_inspect_image_id(docker: Path, tag: str, env: dict[str, str], run_root: Path) -> str:
    path = run_root / "image-inspect.log"
    run_bounded(
        "inspect-built-image",
        [str(docker), "image", "inspect", "--format", "{{.Id}}", tag],
        env,
        path,
        COMMAND_TIMEOUT_SECONDS,
    )
    image_id = validate_image_id_from_log(path)
    print(f"IMAGE_ID {image_id}")
    return image_id


def cleanup_owned(
    docker: Path,
    env: dict[str, str],
    run_root: Path,
    builder: str,
    container_create_attempted: bool,
    builder_attempted: bool,
    image_build_attempted: bool,
    image_id: str | None,
    tag: str,
    container_name: str,
    container_id: str | None,
) -> list[str]:
    errors: list[str] = []
    if container_create_attempted:
        try:
            outcome = remove_owned_container(
                docker, container_name, container_id, env, run_root
            )
            print(f"CLEANUP container={container_name} id={container_id} status={outcome}")
        except (ValidationError, OSError) as error:
            errors.append(f"container:{error}")
    if builder_attempted:
        try:
            outcome = remove_owned_builder(docker, builder, env, run_root)
            print(f"CLEANUP builder={builder} status={outcome}")
        except (ValidationError, OSError) as error:
            errors.append(f"builder:{error}")
    candidate_id = image_id
    if candidate_id is None and image_build_attempted:
        try:
            candidate_id = find_owned_image(docker, tag, env, run_root)
        except (ValidationError, OSError) as error:
            errors.append(f"image-discovery:{error}")
    if candidate_id is not None:
        try:
            run_bounded(
                "remove-owned-image",
                [str(docker), "image", "rm", "--force", validate_image_id(candidate_id)],
                env,
                run_root / "cleanup-image.log",
                COMMAND_TIMEOUT_SECONDS,
            )
            print(f"CLEANUP image={candidate_id} status=removed")
        except (ValidationError, OSError) as error:
            errors.append(f"image:{error}")
    return errors


def report_cleanup_errors(errors: list[str], original_failure_active: bool) -> None:
    if not errors:
        return
    message = f"owned Docker cleanup failed: {errors}"
    if original_failure_active:
        print(f"ARM_CLEANUP_FAIL: {message}", file=sys.stderr)
        return
    raise ValidationError(message)


def execution_environment_is_isolated() -> bool:
    return set(os.environ) == {
        "PATH",
        "LC_ALL",
        "GITHUB_SHA",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "RUNNER_TEMP",
        "WORKSPACE",
    }


def execute(repo: Path, source_commit: str, runner_temp: Path, run_id: str, attempt: str) -> None:
    builder = make_builder_name(run_id, attempt)
    container_name = make_container_name(run_id, attempt)
    if normalize_arch(os.uname().machine) != "arm64":
        raise ValidationError("task must run on a native ARM64 host")
    repo = validate_runner_directory(repo, "workspace")
    runner_temp = validate_runner_directory(runner_temp, "RUNNER_TEMP")
    run_root = Path(tempfile.mkdtemp(prefix="architect-arm64-image-", dir=runner_temp))
    run_root.chmod(0o700)
    if run_root.stat(follow_symlinks=False).st_uid != os.getuid():
        raise ValidationError("run directory owner differs from current user")
    if stat.S_IMODE(run_root.stat(follow_symlinks=False).st_mode) != 0o700:
        raise ValidationError("run directory is not private")
    git_home = run_root / "git-home"
    private_home = run_root / "docker-home"
    docker_config = private_home / ".docker"
    context = run_root / "context"
    log_dir = run_root / "logs"
    for path in (git_home, private_home, docker_config, log_dir):
        path.mkdir(mode=0o700)
    (docker_config / "config.json").write_text("{}\n", encoding="utf-8")
    (docker_config / "config.json").chmod(0o600)
    commit, tree, object_format = verify_source(repo, source_commit, git_home)
    context_data = materialize_tree_context(repo, tree, object_format, context, git_home)
    validate_dockerfile_contract(context / "Dockerfile")
    print("SOURCE " + json.dumps({"commit": commit, "tree": tree, "context": context_data}, sort_keys=True))

    docker_name = shutil.which("docker", path="/usr/bin:/usr/local/bin:/bin")
    if docker_name is None:
        raise ValidationError("Docker CLI was not found in standard paths")
    docker = Path(docker_name).resolve(strict=True)
    if not docker.is_file() or not os.access(docker, os.X_OK):
        raise ValidationError(f"Docker CLI is not executable: {docker}")
    docker_env = make_docker_env(private_home, docker_config, docker)
    uname_log = run_root / "host-architecture.log"
    run_bounded("host-architecture", ["/usr/bin/uname", "-m"], docker_env, uname_log, COMMAND_TIMEOUT_SECONDS)
    if normalize_arch(uname_log.read_text(encoding="utf-8").strip()) != "arm64":
        raise ValidationError("host architecture command disagrees with process architecture")
    preflight = collect_docker_preflight(docker, docker_env, run_root)
    print("DOCKER_PREFLIGHT " + json.dumps(preflight, sort_keys=True))

    tag = f"architect-arm64:{commit[:12]}-{uuid.uuid4().hex[:10]}"
    container_id: str | None = None
    container_create_attempted = False
    builder_attempted = False
    image_id: str | None = None
    image_build_attempted = False
    success = False
    try:
        existing_containers = docker_output(
            "check-runtime-container-name",
            [
                str(docker),
                "ps",
                "--all",
                "--no-trunc",
                "--quiet",
                "--filter",
                f"name=^/{container_name}$",
            ],
            docker_env,
            run_root / "container-name-preflight.log",
        )
        if existing_containers:
            raise ValidationError(f"task-owned runtime container already exists: {container_name}")
        existing_builders = list_builders(
            docker, docker_env, run_root, "builder-name-preflight.log"
        )
        if builder in existing_builders:
            raise ValidationError(f"task-owned Buildx builder already exists: {builder}")
        existing_image_id = find_owned_image(
            docker, tag, docker_env, run_root, "image-name-preflight.log"
        )
        if existing_image_id is not None:
            raise ValidationError(f"unique task image tag already exists: {tag}")
        builder_attempted = True
        run_bounded(
            "create-owned-buildx-builder",
            make_builder_create_argv(docker, builder),
            docker_env,
            log_dir / "builder-create.log",
            120,
        )
        inspect_builder(docker, builder, docker_env, run_root)
        build_log = log_dir / "docker-build.log"
        image_build_attempted = True
        run_bounded(
            "build-native-arm64-image",
            make_build_argv(docker, builder, tag, context),
            docker_env,
            build_log,
            BUILD_TIMEOUT_SECONDS,
        )
        verify_arm_fallback_build_log(build_log)
        image_id = docker_inspect_image_id(docker, tag, docker_env, run_root)
        probe = make_probe_script()
        probe_path = run_root / "runtime-probe.sh"
        probe_path.write_bytes(probe)
        probe_path.chmod(0o600)
        create_log = log_dir / "runtime-container-create.log"
        container_create_attempted = True
        run_bounded(
            "create-networkless-native-arm64-runtime",
            make_probe_create_argv(docker, image_id, container_name),
            docker_env,
            create_log,
            COMMAND_TIMEOUT_SECONDS,
        )
        container_id = validate_container_id(create_log.read_text(encoding="ascii").strip())
        print(f"RUNTIME_CONTAINER name={container_name} id={container_id}")
        run_bounded(
            "networkless-native-arm64-runtime",
            make_probe_start_argv(docker, container_id),
            docker_env,
            log_dir / "runtime-probe.log",
            PROBE_TIMEOUT_SECONDS,
            probe,
        )
        print("RUNTIME_LOG_TAIL\n" + tail_log(log_dir / "runtime-probe.log"))
        success = True
    finally:
        original_failure_active = sys.exc_info()[0] is not None
        previous_signals = {
            signum: signal.signal(signum, signal.SIG_IGN)
            for signum in (signal.SIGTERM, signal.SIGINT)
        }
        try:
            cleanup_errors = cleanup_owned(
                docker,
                docker_env,
                run_root,
                builder,
                container_create_attempted,
                builder_attempted,
                image_build_attempted,
                image_id,
                tag,
                container_name,
                container_id,
            )
        finally:
            for signum, previous_handler in previous_signals.items():
                signal.signal(signum, previous_handler)
        report_cleanup_errors(cleanup_errors, original_failure_active)
    if success:
        print("IMAGE_VALIDATION PASS native-arm64 build, source fallbacks, runtime and cleanup")
        print(f"IMAGE_EVIDENCE source={commit} tree={tree} image={image_id} run_dir={run_root}")


def collect_docker_preflight(
    docker: Path, env: dict[str, str], run_root: Path
) -> dict[str, object]:
    checks = {
        "docker-version": [str(docker), "--version"],
        "buildx-version": [str(docker), "buildx", "version"],
        "buildx-help": [str(docker), "buildx", "build", "--help"],
        "client-plugins": [str(docker), "info", "--format", "{{json .ClientInfo.Plugins}}"],
        "daemon-architecture": [str(docker), "info", "--format", "{{.Architecture}}"],
    }
    outputs: dict[str, str] = {}
    for name, argv in checks.items():
        path = run_root / f"preflight-{name}.log"
        run_bounded(f"preflight-{name}", argv, env, path, COMMAND_TIMEOUT_SECONDS)
        outputs[name] = path.read_text(encoding="utf-8", errors="replace").strip()
        if not outputs[name]:
            raise ValidationError(f"Docker preflight output is empty: {name}")
    require_buildx_resource_flag(outputs["buildx-help"])
    plugin = parse_buildx_plugin_info(outputs["client-plugins"])
    plugin_path = Path(plugin["path"]).resolve(strict=True)
    if not plugin_path.is_file() or not os.access(plugin_path, os.X_OK):
        raise ValidationError("Docker Buildx plugin target is not an executable file")
    if plugin["version"] not in outputs["buildx-version"]:
        raise ValidationError("Buildx plugin metadata and version command disagree")
    daemon_arch = normalize_arch(outputs["daemon-architecture"])
    if daemon_arch != "arm64":
        raise ValidationError(f"Docker daemon is not native ARM64: {daemon_arch}")
    return {
        "docker": {"path": str(docker), "sha256": sha256_file(docker), "version": outputs["docker-version"]},
        "buildx": {
            "reported_path": plugin["path"],
            "real_path": str(plugin_path),
            "sha256": sha256_file(plugin_path),
            "version": plugin["version"],
        },
        "daemon_architecture": daemon_arch,
        "buildx_resource_option": "present",
    }


def inspect_builder(docker: Path, builder: str, env: dict[str, str], run_root: Path) -> None:
    inspect_log = run_root / "builder-inspect.log"
    run_bounded(
        "inspect-owned-buildx-builder",
        [str(docker), "buildx", "inspect", "--bootstrap", builder],
        env,
        inspect_log,
        120,
    )
    output = inspect_log.read_text(encoding="utf-8", errors="replace")
    require_builder_arm64(output)
    container_name = f"buildx_buildkit_{builder}0"
    container_log = run_root / "builder-container-image.log"
    run_bounded(
        "inspect-buildkit-container-image",
        [str(docker), "inspect", "--format", "{{.Image}}", container_name],
        env,
        container_log,
        COMMAND_TIMEOUT_SECONDS,
    )
    image_id = container_log.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValidationError("BuildKit builder container image ID is not immutable")
    image_arch_log = run_root / "builder-container-architecture.log"
    run_bounded(
        "inspect-buildkit-image-architecture",
        [str(docker), "image", "inspect", "--format", "{{.Architecture}}", image_id],
        env,
        image_arch_log,
        COMMAND_TIMEOUT_SECONDS,
    )
    if normalize_arch(image_arch_log.read_text(encoding="utf-8").strip()) != "arm64":
        raise ValidationError("task-owned BuildKit container image is not ARM64")
    print(f"NATIVE_BUILDKIT builder={builder} image={image_id} arch=arm64")


def main() -> int:
    if not execution_environment_is_isolated():
        raise ValidationError("use the fixed clean environment from arm64-image-validation.sh")
    repo_raw = os.environ.get("WORKSPACE", "")
    commit = os.environ.get("GITHUB_SHA", "")
    temp_raw = os.environ.get("RUNNER_TEMP", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    if not repo_raw or not commit or not temp_raw or not run_id or not attempt:
        raise ValidationError(
            "WORKSPACE, GITHUB_SHA, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, and RUNNER_TEMP are required"
        )
    repo = Path(repo_raw)
    runner_temp = Path(temp_raw)
    if not repo.is_absolute() or not runner_temp.is_absolute():
        raise ValidationError("WORKSPACE and RUNNER_TEMP must be absolute paths")
    execute(repo, commit, runner_temp, run_id, attempt)
    return 0


def _term_handler(signum: int, frame: object) -> None:
    signal_to_cancellation(signum, frame)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _term_handler)
    signal.signal(signal.SIGINT, _term_handler)
    try:
        raise SystemExit(main())
    except (ValidationError, CancellationRequested, OSError, subprocess.SubprocessError) as error:
        print(f"ARM_IMAGE_VALIDATION_FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
