from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "maintained-image-build/arm64-image-validation.py"
ENTRYPOINT = ROOT / "maintained-image-build/arm64-image-validation.sh"
SPEC = importlib.util.spec_from_file_location("arm64_image_validation", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)


class NativeArmContractTests(unittest.TestCase):
    def test_closed_architecture_and_builder_identity(self) -> None:
        self.assertEqual(validation.normalize_arch("aarch64"), "arm64")
        self.assertEqual(validation.normalize_arch("ARM64"), "arm64")
        with self.assertRaises(validation.ValidationError):
            validation.normalize_arch("x86_64")
        self.assertEqual(
            validation.make_builder_name("123456789", "2"),
            "vlnr-123456789-2-architect-arm64-image",
        )
        for run_id, attempt in (("0", "1"), ("1;touch", "1"), ("1", "0"), ("1", "1/2")):
            with self.subTest(run_id=run_id, attempt=attempt):
                with self.assertRaises(validation.ValidationError):
                    validation.make_builder_name(run_id, attempt)

    def test_invocations_are_bounded_and_execute_the_inspected_image_id(self) -> None:
        docker = Path("/usr/bin/docker")
        context = Path("/private/context")
        build = validation.make_build_argv(docker, "builder-1", "private-tag", context)
        self.assertIn("linux/arm64", build)
        self.assertIn("--no-cache", build)
        self.assertIn("--pull", build)
        self.assertIn("--load", build)
        self.assertIn("memory=6g", build)
        self.assertIn("cpu-quota=200000", build)
        self.assertIn("CARGO_BUILD_JOBS=2", build)
        self.assertIn("MISE_JOBS=1", build)
        self.assertFalse(any("secret" in item.lower() or "token" in item.lower() for item in build))

        image_id = "sha256:" + "a" * 64
        container_name = validation.make_container_name("123456789", "1")
        create = validation.make_probe_create_argv(docker, image_id, container_name)
        self.assertEqual(create[create.index("--entrypoint=/bin/bash") + 1], image_id)
        self.assertIn("--name", create)
        self.assertIn(container_name, create)
        self.assertIn("--network=none", create)
        self.assertIn("--cpus=1", create)
        self.assertIn("--memory=4g", create)
        self.assertIn("--pids-limit=128", create)
        self.assertIn("--cap-drop=ALL", create)
        self.assertIn(validation.RUNTIME_TMPFS, create)
        self.assertNotIn("--mount", create)
        self.assertNotIn("--privileged", create)
        container_id = "a" * 64
        self.assertEqual(
            validation.make_probe_start_argv(docker, container_id),
            [str(docker), "start", "--attach", "--interactive", container_id],
        )
        with self.assertRaises(validation.ValidationError):
            validation.make_probe_create_argv(docker, "architect:latest", container_name)
        with self.assertRaises(validation.ValidationError):
            validation.make_probe_start_argv(docker, "short-id")

    def test_plugin_metadata_requires_one_absolute_buildx_entry(self) -> None:
        parsed = validation.parse_buildx_plugin_info(
            'notice\n[{"Name":"buildx","Path":"/usr/libexec/docker/cli-plugins/docker-buildx",'
            '"Version":"v0.37.1"}]\n'
        )
        self.assertEqual(parsed["version"], "v0.37.1")
        for malformed in (
            "[]",
            '[{"Name":"other","Path":"/x","Version":"v1"}]',
            '[{"Name":"buildx","Path":"relative","Version":"v1"}]',
            '[{"Name":"buildx","Path":"/x","Version":"v1"},'
            '{"Name":"buildx","Path":"/y","Version":"v1"}]',
        ):
            with self.subTest(malformed=malformed):
                with self.assertRaises(validation.ValidationError):
                    validation.parse_buildx_plugin_info(malformed)

    def test_context_uses_raw_commit_blobs_and_omits_worktree_inputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="architect-raw-context-") as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            git_home = root / "git-home"
            git_home.mkdir(mode=0o700)
            env = validation.clean_git_env(git_home)
            env.update(
                {
                    "GIT_AUTHOR_NAME": "fixture",
                    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "fixture",
                    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
                }
            )

            def git(*args: str, input_bytes: bytes | None = None) -> str:
                completed = subprocess.run(
                    ["/usr/bin/git", "-C", str(repo), *args],
                    input=input_bytes,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
                return completed.stdout.decode("utf-8").strip()

            git("init", "--quiet", "--initial-branch=main")
            contents = {
                ".dockerignore": b".git\n",
                "Dockerfile": b"FROM scratch\n",
                "caveman-config.json": b"{}\n",
                "maintained-image-build/skills-cli/package.json": b"{}\n",
                "maintained-image-build/skills-cli/package-lock.json": b"{}\n",
                "AGENTS.md.d/caveman.md": b"source evidence\n",
                "AGENTS.md.d/token-tools.md": b"source evidence\n",
                "jackin-toolchain/mise.toml": b"[tools]\n",
                "jackin-toolchain/rust-toolchain.toml": b"[toolchain]\nchannel='1.98.1'\n",
            }
            for relative, content in contents.items():
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            git("add", "--all")
            git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
            commit, tree, object_format = validation.verify_source(
                repo, git("rev-parse", "HEAD"), git_home
            )

            original_blob = git("rev-parse", "HEAD:Dockerfile")
            replacement_blob = git(
                "hash-object", "-w", "--stdin", input_bytes=b"FROM busybox\n"
            )
            git("replace", original_blob, replacement_blob)
            (repo / "untracked-secret.txt").write_text("must not enter context", encoding="utf-8")
            (repo / ".git/info/attributes").write_text("Dockerfile filter=host-filter\n", encoding="utf-8")

            context = root / "context"
            manifest = validation.materialize_tree_context(
                repo, tree, object_format, context, git_home
            )
            self.assertEqual(commit, git("rev-parse", "HEAD"))
            self.assertEqual((context / "Dockerfile").read_bytes(), contents["Dockerfile"])
            listed = {entry["path"] for entry in manifest["files"]}
            self.assertEqual(listed, set(contents))
            self.assertNotIn("untracked-secret.txt", listed)
            self.assertFalse((context / ".git").exists())
            self.assertFalse((context / "untracked-secret.txt").exists())
            self.assertEqual(stat.S_IMODE((context / "Dockerfile").stat().st_mode), 0o644)

    def test_dockerfile_source_fallback_contract_and_generated_probe_syntax(self) -> None:
        validation.validate_dockerfile_contract(ROOT / "Dockerfile")
        generated = validation.make_probe_script()
        checked = subprocess.run(
            ["/bin/bash", "-n"], input=generated, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.assertEqual(checked.returncode, 0, checked.stderr.decode("utf-8", "replace"))
        script_text = generated.decode("utf-8")
        self.assertNotIn("GITHUB_RUN_ID", script_text)
        self.assertIn("MBX_WARM_CACHE_HIT PASS", script_text)

    def test_runner_directory_rejects_symlink_ancestor(self) -> None:
        with tempfile.TemporaryDirectory(prefix="architect-path-guard-") as temporary:
            root = Path(temporary)
            target = root / "real"
            target.mkdir()
            link = root / "alias"
            link.symlink_to(target, target_is_directory=True)
            with self.assertRaises(validation.ValidationError):
                validation.require_no_symlink_ancestors(link / "child")
            with self.assertRaises(validation.ValidationError):
                validation.validate_runner_directory(link, "fixture")

    def test_context_paths_reject_controls_and_nonportable_components(self) -> None:
        for path in (
            "jackin-toolchain/../outside",
            "jackin-toolchain/contains space.toml",
            "jackin-toolchain/line\nbreak",
            "jackin-toolchain/name\\with-backslash",
            "jackin-toolchain//empty-component",
        ):
            with self.subTest(path=path):
                self.assertFalse(validation.path_is_allowed(path))
        self.assertTrue(validation.path_is_allowed("jackin-toolchain/mise.toml"))

    def test_shell_entrypoint_is_clean_and_stops_before_docker_on_non_arm(self) -> None:
        syntax = subprocess.run(
            ["/bin/bash", "-n", str(ENTRYPOINT)], stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode("utf-8", "replace"))
        self.assertEqual(stat.S_IMODE(ENTRYPOINT.stat().st_mode), 0o755)
        with tempfile.TemporaryDirectory(prefix="architect-entrypoint-") as temporary:
            root = Path(temporary)
            workspace = root / "checkout with spaces"
            runner_temp = root / "runner temp"
            helper_dir = workspace / "maintained-image-build"
            helper_dir.mkdir(parents=True)
            runner_temp.mkdir()
            shutil.copyfile(SCRIPT, helper_dir / SCRIPT.name)
            env = {
                "GITHUB_SHA": "818ea17a727ec1ace911be44d78b13995e3f6571",
                "GITHUB_RUN_ID": "123456789",
                "GITHUB_RUN_ATTEMPT": "1",
                "RUNNER_TEMP": str(runner_temp),
                "GITHUB_WORKSPACE": str(workspace),
                "PATH": "/usr/bin:/bin",
                "HOME": "/attacker-controlled-home",
                "GITHUB_TOKEN": "must-not-enter-the-runner",
                "AWS_ACCESS_KEY_ID": "must-not-enter-the-runner",
            }
            completed = subprocess.run(
                ["/bin/bash", str(ENTRYPOINT)],
                cwd=ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
            )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("native ARM64 host required", completed.stderr)
        self.assertNotIn("DOCKER_PREFLIGHT", completed.stdout)
        self.assertNotIn("must-not-enter-the-runner", completed.stdout + completed.stderr)


class BoundedProcessTests(unittest.TestCase):
    def test_run_bounded_forwards_stdin_and_reports_status(self) -> None:
        with tempfile.TemporaryDirectory(prefix="architect-process-") as temporary:
            root = Path(temporary)
            env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
            log = root / "success.log"
            payload = b"argv and input are byte-preserving\n"
            with contextlib.redirect_stdout(io.StringIO()):
                status = validation.run_bounded(
                    "fixture-stdin",
                    [
                        sys.executable,
                        "-c",
                        "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())",
                    ],
                    env,
                    log,
                    5,
                    payload,
                )
            self.assertEqual(status, 0)
            self.assertEqual(log.read_bytes(), payload)

            failed_log = root / "failed.log"
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(validation.ValidationError) as raised:
                    validation.run_bounded(
                        "fixture-status",
                        [sys.executable, "-c", "raise SystemExit(7)"],
                        env,
                        failed_log,
                        5,
                    )
            self.assertIn("fixture-status failed (7)", str(raised.exception))

    def test_timeout_covers_blocked_stdin_and_kills_term_ignoring_child(self) -> None:
        with tempfile.TemporaryDirectory(prefix="architect-process-timeout-") as temporary:
            root = Path(temporary)
            env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
            child_pid_file = root / "grandchild.pid"
            child_code = (
                "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
            )
            parent_code = (
                "import subprocess,sys,time; "
                "child=subprocess.Popen([sys.executable,'-c',sys.argv[1]]); "
                "open(sys.argv[2],'w').write(str(child.pid)); "
                "print('ready',flush=True); time.sleep(60)"
            )
            log = root / "blocked.log"
            started = time.monotonic()
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(validation.ValidationError):
                    validation.run_bounded(
                        "fixture-blocked-reader",
                        [sys.executable, "-c", parent_code, child_code, str(child_pid_file)],
                        env,
                        log,
                        0.3,
                        b"x" * (1024 * 1024),
                    )
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 5)
            self.assertTrue(child_pid_file.exists())
            child_pid = int(child_pid_file.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    stat_line = Path(f"/proc/{child_pid}/stat").read_text()
                except FileNotFoundError:
                    break
                state = stat_line[stat_line.rfind(")") + 2 :].split()[0]
                if state == "Z":
                    break
                time.sleep(0.05)
            else:
                self.fail(f"TERM-ignoring child {child_pid} survived bounded cleanup")


class OwnedDockerCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="architect-fake-docker-")
        self.root = Path(self.temporary.name)
        self.state_path = self.root / "state.json"
        self.docker = self.root / "docker"
        self.docker.write_text(
            "#!/usr/bin/python3\n"
            "import json,os,sys\n"
            "p=os.environ['FAKE_STATE']; s=json.load(open(p)); a=sys.argv[1:]\n"
            "def save(): json.dump(s,open(p,'w'))\n"
            "if a[0]=='ps':\n"
            "  expected='name=^/'+s['container_name']+'$'\n"
            "  assert expected in a, repr(a)\n"
            "  print(s['container_id'] if s['container'] else '')\n"
            "elif a[:2]==['rm','--force']:\n"
            "  assert a[2]==s['container_id']; s['container']=False; save(); print(a[2])\n"
            "elif a[:2]==['buildx','ls']:\n"
            "  print(s['builder'] if s['builder_present'] else '')\n"
            "elif a[:2]==['buildx','rm']:\n"
            "  assert a[-1]==s['builder']; s['builder_present']=False; save(); print(a[-1])\n"
            "elif a[:2]==['image','ls']:\n"
            "  print(s['image_id'] if s['image'] else '')\n"
            "elif a[:2]==['image','rm']:\n"
            "  assert a[-1]==s['image_id']; s['image']=False; save(); print(a[-1])\n"
            "else: raise SystemExit('unexpected Docker argv: '+repr(a))\n",
            encoding="utf-8",
        )
        self.docker.chmod(0o700)
        self.env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "FAKE_STATE": str(self.state_path)}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _state(self, **changes: object) -> dict[str, object]:
        state: dict[str, object] = {
            "container_id": "a" * 64,
            "container": True,
            "container_name": "architect-123-1-architect-arm64-image",
            "builder": "vlnr-123-1-architect-arm64-image",
            "builder_present": True,
            "image_id": "sha256:" + "b" * 64,
            "image": True,
        }
        state.update(changes)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        return state

    def test_cleanup_removes_only_captured_container_builder_and_image(self) -> None:
        state = self._state()
        container_name = "architect-123-1-architect-arm64-image"
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(
                self.docker,
                self.env,
                self.root,
                str(state["builder"]),
                True,
                True,
                True,
                str(state["image_id"]),
                "private-tag",
                container_name,
                str(state["container_id"]),
            )
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["container"])
        self.assertFalse(after["builder_present"])
        self.assertFalse(after["image"])
        self.assertFalse(any("prune" in p.name for p in self.root.iterdir()))

    def test_cleanup_accepts_already_absent_owned_resources(self) -> None:
        state = self._state(container=False, builder_present=False, image=False)
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(
                self.docker,
                self.env,
                self.root,
                str(state["builder"]),
                True,
                True,
                True,
                None,
                "private-tag",
                "architect-123-1-architect-arm64-image",
                None,
            )
        self.assertEqual(errors, [])

    def test_cleanup_never_touches_preexisting_unowned_resources(self) -> None:
        state = self._state()
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(
                self.docker,
                self.env,
                self.root,
                str(state["builder"]),
                False,
                False,
                False,
                None,
                "unused-tag",
                str(state["container_name"]),
                None,
            )
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["container"])
        self.assertTrue(after["builder_present"])
        self.assertTrue(after["image"])

    def test_cleanup_rejects_reassigned_container_name(self) -> None:
        state = self._state()
        captured_id = str(state["container_id"])
        state["container_id"] = "c" * 64
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(validation.ValidationError):
                validation.remove_owned_container(
                    self.docker,
                    str(state["container_name"]),
                    captured_id,
                    self.env,
                    self.root,
                )
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["container"])

    def test_cleanup_error_does_not_replace_primary_failure(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            validation.report_cleanup_errors(["builder: daemon unavailable"], True)
        self.assertIn("ARM_CLEANUP_FAIL", output.getvalue())
        with self.assertRaises(validation.ValidationError):
            validation.report_cleanup_errors(["builder: daemon unavailable"], False)


if __name__ == "__main__":
    unittest.main()
