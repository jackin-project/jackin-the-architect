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
if SPEC is None:
    raise RuntimeError("cannot load ARM image validation helper")
if SPEC.loader is None:
    raise RuntimeError("ARM image validation helper has no loader")
validation = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validation
SPEC.loader.exec_module(validation)


class NativeArmContractTests(unittest.TestCase):
    def test_closed_architecture_and_builder_identity(self) -> None:
        self.assertEqual(validation.normalize_arch("aarch64"), "arm64")
        self.assertEqual(validation.normalize_arch("ARM64"), "arm64")
        with self.assertRaises(validation.ValidationError):
            validation.normalize_arch("x86_64")
        token = "f" * 32
        self.assertEqual(
            validation.make_builder_name("123456789", "2", token),
            f"vlnr-123456789-2-arm64-{token[:24]}",
        )
        self.assertEqual(
            validation.make_container_name("123456789", "2", token),
            f"architect-123456789-2-architect-arm64-image-{token}",
        )
        for run_id, attempt in (
            ("0", "1"),
            ("1;touch", "1"),
            ("١", "1"),
            ("1", "0"),
            ("1", "1/2"),
        ):
            with self.subTest(run_id=run_id, attempt=attempt):
                with self.assertRaises(validation.ValidationError):
                    validation.make_builder_name(run_id, attempt, token)
        longest_builder = validation.make_builder_name(
            "12345678901234567890", "123456", "f" * 32
        )
        self.assertEqual(len(longest_builder), 63)
        self.assertTrue(longest_builder.endswith("f" * 24))
        with self.assertRaises(validation.ValidationError):
            validation.make_builder_name("123", "1", "bad-token")
        validation.require_builder_arm64("Platforms: linux/amd64, linux/arm64*\n")
        validation.require_builder_arm64("Platforms: linux/amd64, linux/arm64\n")
        with self.assertRaises(validation.ValidationError):
            validation.require_builder_arm64("Platforms: linux/amd64\n")

    def test_invocations_are_bounded_and_execute_the_inspected_image_id(self) -> None:
        docker = Path("/usr/bin/docker")
        context = Path("/private/context")
        token = "a" * 32
        create_builder = validation.make_builder_create_argv(docker, "builder-1", token)
        self.assertIn(f"env.{validation.OWNER_ENV_KEY}={token}", create_builder)
        build = validation.make_build_argv(docker, "builder-1", "private-tag", context, token)
        self.assertIn("linux/arm64", build)
        self.assertIn("--no-cache", build)
        self.assertIn("--pull", build)
        self.assertIn("--load", build)
        self.assertIn("memory=6g", build)
        self.assertIn("cpu-quota=200000", build)
        self.assertIn("CARGO_BUILD_JOBS=2", build)
        self.assertIn("MISE_JOBS=1", build)
        self.assertIn(f"{validation.OWNER_LABEL_KEY}={token}", build)
        self.assertNotIn("--secret", build)
        self.assertFalse(any("GITHUB_TOKEN" in item or "GH_TOKEN" in item for item in build))

        image_id = "sha256:" + "a" * 64
        container_name = validation.make_container_name("123456789", "1", token)
        create = validation.make_probe_create_argv(docker, image_id, container_name, token)
        self.assertEqual(create[create.index("--entrypoint=/bin/bash") + 1], image_id)
        self.assertIn("--name", create)
        self.assertIn(container_name, create)
        self.assertIn(f"{validation.OWNER_LABEL_KEY}={token}", create)
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
            validation.make_probe_create_argv(docker, "architect:latest", container_name, token)
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
        self.assertIn('RUNTIME_HOME="/home/agent"', script_text)
        self.assertIn('MBX_CACHE_DIR="$PROBE_ROOT/wrapper-mbx-store"', script_text)
        self.assertIn("cold wrapper compile had no MBX miss or unconsulted action", script_text)
        self.assertIn("MBX_COLD_COMPILE PASS", script_text)
        self.assertIn("MBX ignored the private cache root", script_text)
        self.assertIn("MBX_WARM_CACHE_HIT PASS", script_text)

    def test_binary_fixture_function_works_under_nounset(self) -> None:
        generated = validation.make_probe_script().decode("utf-8")
        start = generated.index("write_bin_fixture() {")
        end = generated.index("\n}\nwrite_lib_fixture", start) + 2
        fixture_function = generated[start:end]
        with tempfile.TemporaryDirectory(prefix="architect-fixture-function-") as temporary:
            root = Path(temporary)
            completed = subprocess.run(
                ["/bin/bash", "-eu", "-c", f'PROBE_ROOT="{root}"\n{fixture_function}\nwrite_bin_fixture fixture_name fixture_message'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn('name = "fixture_name"', (root / "fixture_name/Cargo.toml").read_text())
            self.assertIn('println!("fixture_message")', (root / "fixture_name/src/main.rs").read_text())

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

    def test_natural_leader_exit_reaps_term_ignoring_grandchild(self) -> None:
        with tempfile.TemporaryDirectory(prefix="architect-natural-exit-") as temporary:
            root = Path(temporary)
            env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
            ready = root / "grandchild-ready"
            child_code = (
                "import os,signal,sys,time; "
                "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "open(sys.argv[1],'w').write(str(os.getpid())); "
                "time.sleep(60)"
            )
            parent_code = (
                "import os,subprocess,sys,time\n"
                "subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[3]], "
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
                "deadline=time.monotonic()+3\n"
                "while not os.path.exists(sys.argv[3]) and time.monotonic()<deadline:\n"
                "    time.sleep(.01)\n"
                "raise SystemExit(int(sys.argv[2]))\n"
            )
            for exit_status in (0, 7):
                ready.unlink(missing_ok=True)
                log = root / f"leader-{exit_status}.log"
                started = time.monotonic()
                with contextlib.redirect_stdout(io.StringIO()):
                    if exit_status == 0:
                        status = validation.run_bounded(
                            "fixture-natural-leader-exit",
                            [sys.executable, "-c", parent_code, child_code, str(exit_status), str(ready)],
                            env,
                            log,
                            5,
                        )
                        self.assertEqual(status, 0)
                    else:
                        with self.assertRaises(validation.ValidationError):
                            validation.run_bounded(
                                "fixture-natural-leader-failure",
                                [sys.executable, "-c", parent_code, child_code, str(exit_status), str(ready)],
                                env,
                                log,
                                5,
                            )
                self.assertLess(time.monotonic() - started, 5)
                self.assertTrue(ready.exists())
                child_pid = int(ready.read_text())
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
                    self.fail(f"grandchild {child_pid} survived leader exit {exit_status}")

    def test_term_cancellation_reaps_only_the_owned_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="architect-signal-cancel-") as temporary:
            root = Path(temporary)
            ready = root / "grandchild-ready"
            log = root / "nested-command.log"
            harness = (
                "import importlib.util,signal,sys\nfrom pathlib import Path\n"
                f"spec=importlib.util.spec_from_file_location('validation', {str(SCRIPT)!r})\n"
                "validation=importlib.util.module_from_spec(spec); sys.modules['validation']=validation; spec.loader.exec_module(validation)\n"
                "signal.signal(signal.SIGTERM, validation._term_handler)\n"
                "child_code=\"import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(60)\"\n"
                "parent_code=\"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]], "
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(60)\"\n"
                f"env={{'PATH':'/usr/bin:/bin','LC_ALL':'C'}}\n"
                f"try: validation.run_bounded('fixture-cancel',[sys.executable,'-c',parent_code,child_code,{str(ready)!r}],env,Path({str(log)!r}),30)\n"
                "except validation.CancellationRequested: print('CANCELLED',flush=True)\n"
            )
            process = subprocess.Popen(
                [sys.executable, "-c", harness],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not ready.exists():
                    if process.poll() is not None:
                        break
                    time.sleep(0.02)
                if not ready.exists():
                    stdout, stderr = process.communicate(timeout=3)
                    self.fail(
                        "nested child did not reach readiness: "
                        f"status={process.returncode} stdout={stdout!r} stderr={stderr!r}"
                    )
                os.kill(process.pid, signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertIn("CANCELLED", stdout)
                child_pid = int(ready.read_text())
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
                    self.fail(f"TERM-cancelled grandchild {child_pid} survived")
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate(timeout=3)

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
            "  expected=a[a.index('--filter')+1].removeprefix('name=^/').removesuffix('$')\n"
            "  if expected==s['container_name']:\n"
            "    print(s['container_id'] if s['container'] else '')\n"
            "  elif expected==s['builder_container_name']:\n"
            "    print(s['builder_container_id'] if s['builder_container'] else '')\n"
            "  else: raise SystemExit('unexpected container name '+expected)\n"
            "elif a[0]=='inspect' and '{{json .}}' in a:\n"
            "  target=a[-1]\n"
            "  if target in (s['container_id'],s['container_name']):\n"
            "    obj={'Id':s['container_id'],'Name':'/'+s['container_name'],'Config':{'Labels':{s['owner_label']:s['container_owner_token']},'Env':[]},'Mounts':[]}\n"
            "  elif target in (s['builder_container_id'],s['builder_container_name']):\n"
            "    obj={'Id':s['builder_container_id'],'Name':'/'+s['builder_container_name'],'Config':{'Labels':{},'Env':[s['owner_env']+'='+s['builder_owner_token']]},'Mounts':s['builder_mounts']}\n"
            "  else: raise SystemExit('unexpected inspect target '+target)\n"
            "  print(json.dumps(obj))\n"
            "elif a[:2]==['rm','--force']:\n"
            "  if a[2]==s['container_id']:\n"
            "    s['container']=False\n"
            "  elif a[2]==s['builder_container_id']:\n"
            "    s['builder_container']=False\n"
            "  else: raise SystemExit('unexpected container removal '+a[2])\n"
            "  save(); print(a[2])\n"
            "elif a[:2]==['buildx','ls']:\n"
            "  print(s['builder'] if s['builder_present'] else '')\n"
            "elif a[:2]==['buildx','inspect']:\n"
            "  assert a[-1]==s['builder'], repr(a)\n"
            "  print('Name: '+s['builder'])\n"
            "  print('Driver: docker-container')\n"
            "  print('Nodes:')\n"
            "  print('Name: '+s['builder']+'0')\n"
            "  print('Driver Options: env.'+s['owner_env']+'='+s['builder_record_owner_token'])\n"
            "elif a[:2]==['buildx','rm']:\n"
            "  assert a[-1]==s['builder']; s['builder_present']=False; s['builder_container']=False; s['volume']=False; save(); print(a[-1])\n"
            "elif a[:3]==['volume','ls','--format']:\n"
            "  print(s['builder_volume'] if s['volume'] else '')\n"
            "elif a[:2]==['volume','rm']:\n"
            "  assert a[2]==s['builder_volume']; s['volume']=False; save(); print(a[2])\n"
            "elif a[:2]==['image','ls']:\n"
            "  assert 'reference='+s['image_tag'] in a, repr(a)\n"
            "  print(s['image_id'] if s['image_tag_present'] else '')\n"
            "elif a[:2]==['image','inspect'] and '{{json .}}' in a:\n"
            "  assert a[-1]==s['image_tag'], repr(a)\n"
            "  print(json.dumps({'Id':s['image_id'],'Config':{'Labels':{s['owner_label']:s['image_owner_token']}}}))\n"
            "elif a[:2]==['image','rm']:\n"
            "  assert len(a)==3 and a[2]==s['image_tag'], repr(a)\n"
            "  s['image_tag_present']=False\n"
            "  if not s['foreign_image_tag_present']: s['image']=False\n"
            "  save(); print(a[2])\n"
            "else: raise SystemExit('unexpected Docker argv: '+repr(a))\n",
            encoding="utf-8",
        )
        self.docker.chmod(0o700)
        self.env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "FAKE_STATE": str(self.state_path)}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _state(self, **changes: object) -> dict[str, object]:
        token = "e" * 32
        builder = f"vlnr-123-1-arm64-{token[:24]}"
        builder_container_name = f"buildx_buildkit_{builder}0"
        state: dict[str, object] = {
            "container_id": "a" * 64,
            "container": True,
            "container_name": f"architect-123-1-{validation.NATIVE_IMAGE_TASK_ID}-{token}",
            "builder": builder,
            "builder_present": True,
            "builder_container_id": "d" * 64,
            "builder_container_name": builder_container_name,
            "builder_container": True,
            "builder_mounts": [{"Type": "volume", "Name": f"{builder_container_name}_state"}],
            "builder_volume": f"{builder_container_name}_state",
            "volume": True,
            "image_id": "sha256:" + "b" * 64,
            "image": True,
            "image_tag": "private-tag",
            "image_tag_present": True,
            "foreign_image_tag_present": True,
            "owner_token": token,
            "owner_label": validation.OWNER_LABEL_KEY,
            "owner_env": validation.OWNER_ENV_KEY,
            "builder_owner_token": token,
            "builder_record_owner_token": token,
            "container_owner_token": token,
            "image_owner_token": token,
        }
        state.update(changes)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        return state

    def _resources(self, state: dict[str, object], **changes: object) -> validation.OwnedDockerResources:
        resources = validation.OwnedDockerResources(
            owner_token=str(state["owner_token"]),
            builder=str(state["builder"]),
            container_name=str(state["container_name"]),
            image_tag=str(state["image_tag"]),
            builder_creation_attempted=True,
            builder_container_id=str(state["builder_container_id"]),
            runtime_creation_attempted=True,
            runtime_container_id=str(state["container_id"]),
            image_build_attempted=True,
            image_id=str(state["image_id"]),
        )
        for name, value in changes.items():
            setattr(resources, name, value)
        return resources

    def test_cleanup_removes_only_captured_container_builder_and_image(self) -> None:
        state = self._state()
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(
                self.docker, self.env, self.root, self._resources(state)
            )
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["container"])
        self.assertFalse(after["builder_present"])
        self.assertFalse(after["image_tag_present"])
        self.assertTrue(after["foreign_image_tag_present"])
        self.assertTrue(after["image"])
        self.assertFalse(any("prune" in path.name for path in self.root.iterdir()))

    def test_cleanup_recovers_resources_after_create_or_load_timeout(self) -> None:
        state = self._state()
        resources = self._resources(
            state,
            builder_container_id=None,
            runtime_container_id=None,
            image_id=None,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["container"])
        self.assertFalse(after["builder_present"])
        self.assertFalse(after["image_tag_present"])
        self.assertFalse(after["volume"])

    def test_partial_builder_create_failure_cleans_nonce_owned_objects(self) -> None:
        state = self._state(
            builder_present=False,
            builder_container=False,
            volume=False,
            container=False,
            image=False,
            image_tag_present=False,
        )
        resources = self._resources(
            state,
            builder_creation_attempted=False,
            builder_container_id=None,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_build_attempted=False,
            image_id=None,
        )

        def create_then_timeout() -> int:
            self.assertTrue(resources.builder_creation_attempted)
            state["builder_present"] = True
            state["builder_container"] = True
            state["volume"] = True
            self.state_path.write_text(json.dumps(state), encoding="utf-8")
            raise validation.ValidationError("simulated timeout after Buildx persisted its builder")

        with self.assertRaisesRegex(validation.ValidationError, "simulated timeout"):
            validation.attempt_owned_creation(resources, "builder", create_then_timeout)
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["builder_present"])
        self.assertFalse(after["builder_container"])
        self.assertFalse(after["volume"])

    def test_partial_buildkit_volume_creation_is_recovered_by_nonce_name(self) -> None:
        state = self._state(
            builder_present=False,
            builder_container=False,
            volume=False,
            container=False,
            image=False,
            image_tag_present=False,
        )
        resources = self._resources(
            state,
            builder_creation_attempted=False,
            builder_container_id=None,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_build_attempted=False,
            image_id=None,
        )

        def create_volume_then_timeout() -> int:
            self.assertTrue(resources.builder_creation_attempted)
            state["volume"] = True
            self.state_path.write_text(json.dumps(state), encoding="utf-8")
            raise validation.ValidationError("simulated timeout after BuildKit cache volume creation")

        with self.assertRaisesRegex(validation.ValidationError, "cache volume creation"):
            validation.attempt_owned_creation(resources, "builder", create_volume_then_timeout)
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        self.assertFalse(json.loads(self.state_path.read_text())["volume"])

    def test_runtime_create_cancellation_recovers_container_before_id_capture(self) -> None:
        state = self._state(
            builder_present=False,
            builder_container=False,
            volume=False,
            image=False,
            image_tag_present=False,
        )
        resources = self._resources(
            state,
            builder_creation_attempted=False,
            builder_container_id=None,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_build_attempted=False,
            image_id=None,
        )

        def create_then_cancel() -> int:
            self.assertTrue(resources.runtime_creation_attempted)
            state["container"] = True
            self.state_path.write_text(json.dumps(state), encoding="utf-8")
            raise validation.CancellationRequested("simulated cancellation after create")

        with self.assertRaises(validation.CancellationRequested):
            validation.attempt_owned_creation(resources, "runtime", create_then_cancel)
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        self.assertFalse(json.loads(self.state_path.read_text())["container"])

    def test_loaded_image_inspection_failure_recovers_before_id_capture(self) -> None:
        state = self._state(
            container=False,
            builder_present=False,
            builder_container=False,
            volume=False,
            image_id="sha256:" + "b" * 64,
        )
        resources = self._resources(
            state,
            builder_creation_attempted=False,
            builder_container_id=None,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_build_attempted=False,
            image_id=None,
        )

        def load_then_inspect_failure() -> int:
            self.assertTrue(resources.image_build_attempted)
            state["image"] = True
            state["image_tag_present"] = True
            self.state_path.write_text(json.dumps(state), encoding="utf-8")
            raise validation.ValidationError("simulated inspect failure after --load")

        with self.assertRaisesRegex(validation.ValidationError, "after --load"):
            validation.attempt_owned_creation(
                resources, "image", load_then_inspect_failure
            )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["image_tag_present"])
        self.assertTrue(after["foreign_image_tag_present"])

    def test_cleanup_recovers_builder_after_create_then_platform_validation_failure(self) -> None:
        state = self._state(container=False, image_tag_present=False)
        resources = self._resources(
            state,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_build_attempted=False,
            image_id=None,
            builder_container_id=None,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["builder_present"])
        self.assertFalse(after["builder_container"])
        self.assertFalse(after["volume"])

    def test_cleanup_recovers_loaded_image_after_inspect_failure(self) -> None:
        state = self._state(container=False, builder_present=False, builder_container=False)
        resources = self._resources(
            state,
            builder_creation_attempted=False,
            builder_container_id=None,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_id=None,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertFalse(after["image_tag_present"])
        self.assertTrue(after["foreign_image_tag_present"])

    def test_cleanup_accepts_already_absent_owned_resources(self) -> None:
        state = self._state(
            container=False,
            builder_present=False,
            builder_container=False,
            volume=False,
            image=False,
            image_tag_present=False,
            foreign_image_tag_present=False,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(
                self.docker, self.env, self.root, self._resources(state)
            )
        self.assertEqual(errors, [])

    def test_cleanup_never_touches_preexisting_unowned_resources(self) -> None:
        state = self._state()
        resources = self._resources(
            state,
            builder_creation_attempted=False,
            builder_container_id=None,
            runtime_creation_attempted=False,
            runtime_container_id=None,
            image_build_attempted=False,
            image_id=None,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(errors, [])
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["container"])
        self.assertTrue(after["builder_present"])
        self.assertTrue(after["image"])

    def test_cleanup_rejects_tag_reassignment_and_preserves_foreign_image(self) -> None:
        state = self._state(image_id="sha256:" + "c" * 64)
        resources = self._resources(state, image_id="sha256:" + "b" * 64)
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(validation.ValidationError):
                validation.remove_owned_image(
                    self.docker,
                    resources,
                    self.env,
                    self.root,
                )
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["image_tag_present"])
        self.assertTrue(after["foreign_image_tag_present"])

    def test_cleanup_rejects_reassigned_container_name(self) -> None:
        state = self._state()
        captured_id = str(state["container_id"])
        state["container_id"] = "c" * 64
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(validation.ValidationError):
                validation.remove_owned_container(
                    self.docker,
                    self._resources(state, runtime_container_id=captured_id),
                    self.env,
                    self.root,
                )
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["container"])

    def test_cleanup_rejects_reassigned_builder_name(self) -> None:
        state = self._state(builder_container_id="e" * 64)
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(validation.ValidationError):
                validation.remove_owned_builder(
                    self.docker,
                    self._resources(state, builder_container_id="d" * 64),
                    self.env,
                    self.root,
                )
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["builder_present"])

    def test_cleanup_preserves_builder_without_matching_driver_owner_option(self) -> None:
        state = self._state(builder_record_owner_token="f" * 32)
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(validation.ValidationError, "ownership"):
                validation.remove_owned_builder(
                    self.docker, self._resources(state), self.env, self.root
                )
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["builder_present"])
        self.assertTrue(after["builder_container"])
        self.assertTrue(after["volume"])

    def test_cleanup_preserves_resources_with_another_owner_token(self) -> None:
        state = self._state(
            builder_owner_token="f" * 32,
            container_owner_token="f" * 32,
            image_owner_token="f" * 32,
        )
        resources = self._resources(
            state,
            builder_container_id=None,
            runtime_container_id=None,
            image_id=None,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            errors = validation.cleanup_owned(self.docker, self.env, self.root, resources)
        self.assertEqual(len(errors), 3)
        after = json.loads(self.state_path.read_text())
        self.assertTrue(after["container"])
        self.assertTrue(after["builder_present"])
        self.assertTrue(after["image_tag_present"])

    def test_cleanup_error_does_not_replace_primary_failure(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            validation.report_cleanup_errors(["builder: daemon unavailable"], True)
        self.assertIn("ARM_CLEANUP_FAIL", output.getvalue())
        with self.assertRaises(validation.ValidationError):
            validation.report_cleanup_errors(["builder: daemon unavailable"], False)


if __name__ == "__main__":
    unittest.main()
