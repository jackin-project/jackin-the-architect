# The Architect

The Architect is the jackin role for developing [jackin](https://github.com/jackin-project/jackin) itself. It is a Codex role. It gives Codex the Rust toolchain and the tools that the jackin gates need, in an OpenShell sandbox with a default-deny network policy. Codex is the only agent.

Jackin builds the image and creates the sandbox. This repository does not publish an image. The role holds no secret.

## What the image contains

The `Dockerfile` ends in a stage that starts `FROM construct`. It adds these parts, all with a pinned version and a checksum:

- git 2.56.0, built from the source archive with https support. It replaces `/usr/bin/git`, because the construct image has git 2.43.0.
- mise, from a release archive. The build checks the archive against the `SHASUMS256.txt` of the release, and checks that file against a pinned digest.
- `rustup-init` 1.29.3 from `static.rust-lang.org`, run with `--default-toolchain none` and with `auto-self-update` disabled.
- The tools of `toolchain/mise.toml`, installed with `mise install --locked` at build time. A sandbox starts the gate without a download.
- `build-essential`, `cmake`, and `pkg-config` from apt.

Jackin adds Codex and `jackin-start` when it derives the final image (decision D05).

### Toolchain

`toolchain/mise.toml` holds the same `[tools]` pins as `mise.toml` in jackin: Rust 1.99.1 with `mr_boxington = true`, mr-boxington 1.29.2, cargo-nextest 0.9.151, and the other tools of the jackin gates. The `Dockerfile` copies it to `/etc/mise/config.toml`, and copies `toolchain/mise.lock` and `toolchain/.mise/` next to it.

The lock covers linux arm64 and amd64. It gives a URL and a SHA-256 checksum for each download of each tool. Rust is the exception: rustup downloads it and checks it against the SHA-256 values of the channel manifest. `cargo-shear` comes from the `github:Boshen/cargo-shear` backend, which the lock pins by the checksum of its release archive.

The tools live in root-owned directories: mise in `/usr/local/share/mise`, the Rust toolchains in `/usr/local/rustup`, and the rustup proxies (`cargo`, `rustc`, and the others) in `/usr/local/cargo/bin`. The image sets `ENV MISE_DATA_DIR=/usr/local/share/mise`, so mise reads its installs from there instead of from `/sandbox/.local/share/mise`, which the sandbox user owns.

`CARGO_HOME` is `/usr/local/cargo` (`rust.cargo_home` in `toolchain/mise.toml`). mise puts `$CARGO_HOME/bin` first among the Rust paths and sets `CARGO_HOME` for `mise exec` (`list_bin_paths` and `exec_env` of the rust plugin in mise 2026.11.0), so the proxy directory cannot be separate from `CARGO_HOME`. Cargo needs a writable registry cache, so `/usr/local/cargo/registry`, `git`, `.package-cache`, and `.package-cache-mutate` are symbolic links into `/sandbox/.cargo`, which the sandbox user owns. The policy makes `/usr` read-only, so a symbolic link is the only way to put a writable cache under a root-owned `CARGO_HOME`. Build outputs go to the target directory of the workspace. Cargo ignores the `.global-cache` database it cannot create. `cargo install` into `CARGO_HOME/bin` fails by design.

`mr_boxington = true` adds a second directory. Under `mise exec`, mise puts `$MISE_DATA_DIR/command-wrappers/bin` at the front of `PATH` and runs `cargo` through the wrapper there (`apply_command_wrapper_paths` in `src/toolset/toolset_paths.rs` and `COMMAND_WRAPPERS` in `crates/mise-util/src/dirs.rs`, mise 2026.11.0). The build runs `mise exec -- true` as root, which creates that directory (`ensure_command_wrapper_shims` in `src/shims.rs`), before it removes group and other write permission. If the data directory were the default one, the sandbox user could replace `cargo` there.

A read-only data directory has one runtime cost. Each `mise exec` opens `command-wrappers/bin.lock` for writing (`write_bootstrap_shims` in `src/shims.rs` and `LockFile::at` in `crates/mise-util/src/lock_file.rs`), and `mise exec` fails with "Permission denied" when that file is read-only. `bin.lock` is therefore a symbolic link to `/tmp/mise-command-wrappers.lock`, which the sandbox user creates on first use. Everything else that mise writes goes under `$HOME` (`/sandbox`): the cache in `~/.cache/mise` and the state in `~/.local/state/mise`. The build proves this by running `mbx`, `cargo-nextest`, and `cargo generate-lockfile --offline` as the sandbox user against the read-only trees.

The build checks these properties with `scripts/verify-toolchain.sh`:

- As root, nothing in `/usr/local/cargo`, `/usr/local/rustup`, `/usr/local/share/mise`, `/etc/mise`, `/usr/lib/git-core`, `/usr/local/bin/mise`, or `/usr/bin/git`, other than a symbolic link, is owned by another user or writable by a group or by others.
- As root, the only symbolic links that resolve outside those trees are `/usr/local/cargo/{registry,git,.package-cache,.package-cache-mutate}` to `/sandbox/.cargo/<name>` and `bin.lock` to `/tmp/mise-command-wrappers.lock`.
- As the sandbox user, it cannot write to a proxy or a wrapper, add a file to `/usr/local/cargo`, or rename `/usr/local/cargo/bin` or the wrapper directory.
- As the sandbox user, every `PATH` entry that `mise exec` puts ahead of `/usr/local/cargo/bin` is an absolute directory, and it and all its parents are owned by root and closed to group and other writes. `cargo` and `rustc` under `mise exec` resolve to files with the same properties.

Any failed check fails the build.

### What the sandbox user can still shadow

The promise is that the sandbox user cannot replace the root-owned tools. It can always run its own binaries for itself. These routes remain, and each affects only commands that the sandbox user starts:

- `~/.config/mise/config.toml` and any `mise.toml` it trusts. `[env] _.path` puts a directory ahead of the root-owned ones under `mise exec`, and a command wrapper that the file declares replaces the `cargo` wrapper.
- `MISE_DATA_DIR`. A process that unsets or changes it makes mise use another data directory.
- `/sandbox/.cargo/config.toml` and the `.cargo/config.toml` of any parent directory of the workspace. Cargo reads them under the root-owned proxy, and they can set `build.rustc-wrapper` and `target.<triple>.runner`, which run the sandbox user's program in place of `rustc` and in place of a test binary.
- The caches. It can fill or empty `/sandbox/.cargo` and the lock file in `/tmp`.
- A plain shell. The image `PATH` is the Ubuntu default, and a profile or the user can add `~/.local/bin` or `~/bin` ahead of it. The rustup proxies apply only under `mise exec`.

### Plain shell

The image `ENV` sets `MISE_DATA_DIR` and nothing else. It sets neither `PATH`, `CARGO_HOME`, nor `RUSTUP_HOME`, so a plain shell finds no `cargo`. This is deliberate. The jackin rules run every Rust command through `mise exec -- mbx`, which uses the wrapper and the pinned toolchain. A `cargo` on the plain `PATH` would skip `mr-boxington`, and without `RUSTUP_HOME` the proxy would look for toolchains in `~/.rustup` and try to download one, which the policy denies. A sandbox process that does not inherit the image `ENV` has no `MISE_DATA_DIR`, finds none of the tools, and fails instead of falling back to a writable copy.

### Pins

`toolchain/jackin-pins.toml` is a verbatim copy of the `[tools]` table of `mise.toml` in jackin `feature/openshell-native`. To change a pin:

1. Copy the table from jackin into `toolchain/jackin-pins.toml` and `toolchain/mise.toml`.
2. Set `jackin_ref` in `scripts/check-jackin-pins.sh` to the jackin commit you copied from.
3. Run `mise run lock:toolchain`.
4. Commit the two pin files, the script, and the new lock together.

`scripts/check-jackin-pins.sh` runs in `mise run test`. It fails when the `[tools]` tables of the two files differ, or when the `Dockerfile` selects a Rust other than the pinned one. `mise run check:jackin-pins` first asks the GitHub compare API whether `jackin_ref` is an ancestor of `feature/openshell-native` or `main` in jackin, so a commit that exists only in a fork fails. It then fetches `mise.toml` from jackin at `jackin_ref` and fails when its `[tools]` table differs from `toolchain/jackin-pins.toml`. `jackin_ref` is a full commit hash, because the jackin rewrite has no tag and its branch moves. After the jackin pull request merges, set `jackin_ref` to a commit on `main`.

### Renovate

`renovate.json` has a rule for each of `MISE_VERSION`, `GIT_VERSION`, and `RUSTUP_VERSION` in the `Dockerfile`. Two of them update the digest with the version, because a datasource supplies it:

| Argument | Datasource | Digest |
|---|---|---|
| `MISE_VERSION`, `MISE_SHASUMS256` | `github-release-attachments` for `jdx/mise` | Renovate computes the digest of the `SHASUMS256.txt` asset of the new release. One digest covers both architectures, so the two edits cannot overlap. |
| `GIT_VERSION`, `GIT_SHA256` | custom datasource `git-source`, the `sha256sums.asc` file at kernel.org | The digest of `git-<version>.tar.xz` from that file. |
| `RUSTUP_VERSION` | `github-tags` for `rust-lang/rustup` | None. `static.rust-lang.org` publishes one checksum file per version and architecture, and no datasource lists them. |

A Renovate pull request for `RUSTUP_VERSION` changes only the version, so the build fails at the `ADD --checksum` of `rustup-init` until you replace `RUSTUP_SHA256_ARM64` and `RUSTUP_SHA256_AMD64` by hand with the contents of `rustup-init.sha256` from `static.rust-lang.org/rustup/archive/<version>/<triple>/`. The Renovate digests come from the same hosts as the files, so review each pull request as a change to what the build downloads.

## Egress policy

`policy.yaml` is a native OpenShell policy that jackin sends without change. The network is deny by default. The role allows two groups of requests. OpenShell adds the rule of the Codex provider, and the policy names no Codex host.

| Rule | Host | Requests |
|---|---|---|
| `crates_io` | `index.crates.io`, `static.crates.io` | Read-only: `GET`, `HEAD`, `OPTIONS` |
| `github` | `github.com` | `GET` of `/<owner>/<repo>/info/refs?service=git-upload-pack` and `POST` of `/<owner>/<repo>/git-upload-pack` |

No rule allows a push. The role allows no tool download host, because the image carries the toolchain. The policy names no repository, because jackin gains git dependencies over time and an allowlist of repositories would break the role at each one.

The egress boundary is the host, the method, and the path. The `binaries` list of a rule is not a security boundary. OpenShell matches a process or any of its ancestors, a process can start through another matched binary, and `/sandbox` is writable. The lists name only root-owned paths, so they narrow the rules to the toolchain and git without promising more.

The sandbox can still fetch any public repository and any crate. A process that holds a secret can send it out at a low rate in the owner and repository name of a `github.com` URL, in the path or query of a crates.io request, or in the body of a `git-upload-pack` request to a repository that the attacker controls. Fetched content can also steer the agent. Review every widening of the policy with both in mind. Add a host only when the G-FAST gate in a sandbox of this role proves it is needed.

The filesystem rules:

- `/bin`, `/sbin`, `/usr`, `/lib`, `/etc`, `/proc`, `/dev/urandom`, `/dev/zero`, and `/var/log` are read-only.
- `/sandbox`, `/tmp`, `/dev/null`, `/dev/shm`, `/dev/ptmx`, and `/dev/pts` are writable.
- `landlock.compatibility` is `hard_requirement`, so the sandbox fails to start where Landlock is unavailable.

`/dev/ptmx` and `/dev/pts` are writable because the jackin tests and the tool terminals of Codex open pseudo-terminals. A process in the sandbox can open the slave side of another pseudo-terminal that the sandbox owns, read what the other session writes, and inject keystrokes or terminal escape sequences into it. Only sessions of the same sandbox are affected.

The Docker capability is off (`[docker] enabled = false`).

## Environment and hooks

The manifest has no `[env]` entry and no hook.

## Use the role

Build jackin in the jackin repository. Check the role from this directory with that binary:

```sh
jackin role check .
```

Register the role, then load it with a project directory:

```sh
jackin role add the-architect .
jackin load the-architect <project>
```

Run the jackin gate in the sandbox:

```sh
mise exec -- mbx +1.99.1 xtask ci --fast
```

### Resources

The gate needs a gateway VM with enough memory and disk for a debug build of jackin and its tests. Set `vcpus`, `mem_mib`, and `overlay_disk_mib` in the `[openshell.drivers.vm]` section of the gateway config. The gate was tested in a sandbox with 8 vCPUs, 16 GiB of memory, and a 32 GiB disk. The role sets no Cargo variable.

## Repository checks

`mise run test` runs `prek run --all-files`: gitleaks, hadolint, and the pin check.

`velnor-actions` generates `.github/` and `config/fleet/` from `.velnor/config.toml`. Do not edit them by hand.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
