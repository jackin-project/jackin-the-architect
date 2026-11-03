# The Architect

The Architect is the jackin role for developing [jackin](https://github.com/jackin-project/jackin) itself. It is a Codex role. It gives Codex the Rust toolchain and the tools that the jackin gates need, in an OpenShell sandbox with a default-deny network policy.

Jackin builds the image and creates the sandbox. This repository does not publish an image. The role holds no secret.

## Files

| File | Purpose |
|---|---|
| `jackin.role.toml` | The role manifest (schema 1). It names the `Dockerfile` and the policy. The Docker capability is off. |
| `Dockerfile` | The final stage starts `FROM construct`. It builds git from a checksum-pinned source archive, installs mise and `rustup-init` from checksum-pinned release files, and installs the locked toolchain. |
| `toolchain/mise.toml` | The tool pins and the mise settings of the image. The `Dockerfile` copies it to `/etc/mise/config.toml`. |
| `toolchain/mise.lock`, `toolchain/.mise/` | The lock of `toolchain/mise.toml` for linux arm64 and amd64, with a checksum for every download. The `Dockerfile` copies them next to `/etc/mise/config.toml`. |
| `toolchain/jackin-pins.toml` | A verbatim copy of the `[tools]` table of `mise.toml` in jackin `feature/openshell-native`. |
| `policy.yaml` | A native OpenShell policy. Landlock is a hard requirement. The network is deny by default. Writes are allowed to `/sandbox`, `/tmp`, `/dev/null`, `/dev/shm`, `/dev/ptmx`, and `/dev/pts`. |
| `scripts/check-jackin-pins.sh`, `scripts/lock-toolchain.sh` | The pin check and the lock generator. |

## Toolchain

`toolchain/mise.toml` holds the same `[tools]` pins as `mise.toml` in jackin: Rust 1.99.1 with the `mr_boxington = true` option, mr-boxington 1.29.1, cargo-nextest 0.9.151, and the other tools of the jackin gates. The image installs them with `mise install --locked` at build time, so a sandbox starts the gate without a download. The lock gives a URL and a SHA-256 checksum for each download of each tool, with one exception: Rust, which rustup downloads over HTTPS and checks against the SHA-256 values of the channel manifest. `cargo-shear` comes from the `github:Boshen/cargo-shear` backend, which the lock pins by the checksum of its release archive for each architecture.

The `Dockerfile` installs rustup itself before mise runs. It takes `rustup-init` 1.29.2 from `static.rust-lang.org` with `ADD --checksum` for each architecture, runs it with `--default-toolchain none`, and sets `auto-self-update` to `disable`. When `RUSTUP_HOME/settings.toml` and `CARGO_HOME/bin` exist, mise skips its own bootstrap, which downloads and runs the unpinned script from `sh.rustup.rs`. mise then installs the pinned Rust toolchain with this rustup.

The tools live in root-owned directories: mise installs in `/usr/local/share/mise` and the Rust toolchains in `/usr/local/rustup`. The build fails when anything in those two directories, other than a symbolic link, is not owned by root or is writable by a group or by others. Only `CARGO_HOME` (`/sandbox/.cargo`) and the caches are writable. `CARGO_HOME/bin` holds the rustup proxies, so code in the sandbox can replace `cargo` and `rustc` there. It cannot change the toolchains themselves.

The image also replaces `/usr/bin/git` with git 2.56.0, built with https support. The jackin tests run the first `git` in `/usr/bin`, and jackin refuses a host git older than 2.45.4. The construct image has git 2.43.0.

The pins follow jackin. `scripts/check-jackin-pins.sh` runs in `mise run test`. It fails when the `[tools]` table of `toolchain/mise.toml` differs from `toolchain/jackin-pins.toml`, or when the `Dockerfile` selects a Rust other than the pinned one. The CI task `jackin-pins` (`mise run check:jackin-pins`) fetches `mise.toml` from jackin `feature/openshell-native` and fails when its `[tools]` table differs from `toolchain/jackin-pins.toml`. To change a pin, copy the table from jackin into both files in one commit, then run `mise run lock:toolchain` and commit the lock.

`MISE_VERSION`, `RUSTUP_VERSION`, and `GIT_VERSION` in the `Dockerfile` have Renovate rules. Renovate cannot compute the SHA-256 `ARG` values, so a Renovate pull request for any of them fails the build at the checksum until you replace the hashes by hand.

Run the jackin gate in a sandbox of this role:

```sh
mise exec -- mbx +1.99.1 xtask ci --fast
```

## Resources

Give the sandbox enough disk and memory for a debug build of jackin with its tests. The default OpenShell VM driver gives 2 vCPUs, 2 GiB of memory, and a 4 GiB disk (`vcpus`, `mem_mib`, and `overlay_disk_mib` in the gateway config), which is too small: the build needs about 3.5 GiB of disk even without incremental state, and two parallel links ran out of memory. Raise those values in the gateway config. The gate was tested in a sandbox with 8 vCPUs, 16 GiB of memory, and a 32 GiB disk. The role sets no Cargo variable.

## Policy

The filesystem policy makes the system directories read-only and allows writes to `/sandbox`, `/tmp`, and a few device paths. The role names no Codex host. OpenShell adds the rule of the Codex provider.

The egress boundary is the host, the method, and the path (`GET` and `POST` rules with an optional query match). The `binaries` list of a rule is not a security boundary: OpenShell matches a process or any of its ancestors, a process can start through another matched binary, and `/sandbox` is writable. The lists name only root-owned paths, so they narrow the rules to the toolchain and git without promising more.

| Rule | Host | Requests |
|---|---|---|
| `crates_io` | `index.crates.io`, `static.crates.io` | `GET`, `HEAD`, `OPTIONS` |
| `github` | `github.com` | `GET` of `/<owner>/<repo>/info/refs?service=git-upload-pack`, `POST` of `/<owner>/<repo>/git-upload-pack` |

The role allows nothing else; OpenShell adds the rule of the Codex provider. No rule allows a push. The two `github.com` paths have exactly two segments before `info/refs` and `git-upload-pack`, as every path that the gate uses has. The policy names no repository, because a role user adds git dependencies to jackin over time (jackin will soon add `tailrocks/terminal-components-baseline`) and an allowlist of repositories would break the role at each one.

The open path stays: the sandbox can fetch any public repository and any crate. A process that holds a secret can send it out at a low rate in the owner and repository name of a `github.com` URL, in the path or query of a crates.io request, or in the body of a `git-upload-pack` request to a repository that the attacker controls. Fetched content can also steer the agent. Review every widening of the `github` and `crates_io` rules with both in mind. The G-FAST gate passes with only these hosts, and the policy keeps a host only when a live G-FAST needs it. Review every new host as a new path for content from a prompt injection.

`/dev/ptmx` and `/dev/pts` are writable because the jackin tests and the tool terminals of Codex open pseudo-terminals. The cost: a process in the sandbox can open the slave side of another pseudo-terminal that the sandbox owns, read what the other session writes, and inject keystrokes or terminal escape sequences into it. Only sessions of the same sandbox are affected.

## Check and use the role

The repository gate is `mise run test`. It runs `prek run --all-files`: gitleaks, hadolint, and the pin check.

Build jackin in the jackin repository. The role gate runs the binary `jackin/target/debug/jackin` from this directory:

```sh
jackin role check .
```

Register the role, then load it with a project directory:

```sh
jackin role add the-architect .
jackin load the-architect <project>
```

## CI

`.github/` and `config/fleet/` are generated by `velnor-actions generate` from `.velnor/config.toml`. Do not edit them by hand.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
