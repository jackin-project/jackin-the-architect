# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.37-trixie@sha256:67fc093e1dd9a021e2af66beebbeddbb4d676839dcd0a5371ce8a5d7b2cdcab4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG MISE_VERSION=2026.9.18
ARG MBX_VERSION=1.22.0
ARG CARGO_BINSTALL_VERSION=1.23.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_DENY_VERSION=0.20.2
ARG CARGO_DYLINT_VERSION=6.0.4
ARG CARGO_WATCH_VERSION=8.5.3
ARG CARGO_HACK_VERSION=0.6.45
ARG CARGO_HAKARI_VERSION=0.9.38
ARG CARGO_LLVM_COV_VERSION=0.8.7
ARG LYCHEE_VERSION=0.24.2
ARG BOLTFFI_VERSION=0.30.1
ARG CARGO_FUZZ_VERSION=0.13.2
ARG CARGO_SHEAR_VERSION=1.13.4
ARG CARGO_ZIGBUILD_VERSION=0.23.0
ARG CODEBOOK_LSP_VERSION=0.3.42
ARG SCCACHE_VERSION=0.17.0
ARG DYLINT_LINK_VERSION=6.0.4
ARG CARGO_MUTANTS_VERSION=27.1.0
ARG TARGETARCH
ARG OPENTOFU_VERSION=1.12.6
ARG NODE_TOOLS_VERSION=24.21.0
ARG CARGO_BUILD_JOBS=4
ARG MISE_JOBS=1
# HEADROOM_VERSION.
ARG HEADROOM_VERSION=0.37.0
# UV_VERSION.
ARG UV_VERSION=0.12.15
# RTK_VERSION (aqua).
ARG RTK_VERSION=0.49.0

USER root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    openssl \
    pkg-config \
    cmake \
    xz-utils \
    xxd && \
    apt-get autoremove -y

USER agent

ENV PATH="/home/agent/.local/bin:/home/agent/.local/share/architect-node-tools/node_modules/.bin:/home/agent/.local/share/mise/shims:${PATH}"
ENV MISE_TRUSTED_CONFIG_PATHS=/workspace:/tmp/jackin-mise

COPY --chown=root:root jackin-toolchain/ /tmp/jackin-mise/

RUN set -eu; \
    mkdir -p "${HOME}/.local/bin"; \
    case "${TARGETARCH}" in \
        amd64) mise_arch=x64; mise_sha256=d24fe0bf7e613824ad99f7b8dac3f2b381a37b9f75f84dd250855217095a8de4 ;; \
        arm64) mise_arch=arm64; mise_sha256=2142433ae70decffc5fa24bd160e47931e33f55eb031d128beb97cbae634d168 ;; \
        *) echo "unsupported TARGETARCH for mise: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mise_archive="${HOME}/.local/bin/mise"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${mise_arch}" -o "${mise_archive}"; \
    printf '%s  %s\n' "${mise_sha256}" "${mise_archive}" | sha256sum --check --strict -; \
    chmod 0755 "${mise_archive}"; \
    mise_version="$(MISE_DISABLE_UPDATE_WARNING=1 "${mise_archive}" --version)"; \
    case "${mise_version}" in \
        "${MISE_VERSION} "*) ;; \
        *) echo "unexpected Mise version: ${mise_version}" >&2; exit 1 ;; \
    esac; \
    mkdir -p \
        "${HOME}/.cache/amp" \
        "${HOME}/.cache/mise" \
        "${HOME}/.cargo/bin" \
        "${HOME}/.cargo/registry" \
        "${HOME}/.cargo/git"

# Per-tool RUNs (caching).
RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    MISE_CARGO_BINSTALL_ONLY=1 mise install "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}"

RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    mise trust /tmp/jackin-mise/mise.toml && \
    mkdir -p "${HOME}/.config/mise" && \
    cp /tmp/jackin-mise/mise.toml "${HOME}/.config/mise/config.toml" && \
    : "Keep cargo-binstall pinned before installing Cargo-backed mise tools" && \
    mise use -g --pin "cargo-binstall@${CARGO_BINSTALL_VERSION}" && \
    mise install -C /tmp/jackin-mise rust && \
    mise use -g --pin -C /tmp/jackin-mise rust && \
    mise use -g --pin -C /tmp/jackin-mise --tool-option mr_boxington=true rust "mr-boxington@${MBX_VERSION}"

# Install checksum-verified upstream binaries for the pinned Cargo tools.
# cargo-fuzz and cargo-mutants lack ARM64 release assets, so that platform uses
# MBX path installs from locked, checksum-verified crates.io sources.
RUN --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    --mount=type=cache,target=/home/agent/.cache/cargo-target-${TARGETARCH},uid=1000 \
    set -eu; \
    case "${TARGETARCH}" in \
        amd64) \
            sccache_target=x86_64-unknown-linux-musl; \
            sccache_sha256=67c4a96dd237c1f518f6b36083f270f9976d516f1e57fce891755ea782e50006 \
            ;; \
        arm64) \
            sccache_target=aarch64-unknown-linux-musl; \
            sccache_sha256=821a86343191aa1cbab74bd42f9e93c9a63bf85e4742945f40d3ae84193c1c77 \
            ;; \
        *) echo "unsupported TARGETARCH for Rust tool installation: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    sccache_archive="/tmp/sccache-v${SCCACHE_VERSION}-${sccache_target}.tar.gz"; \
    sccache_url="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}"; \
    sccache_asset="sccache-v${SCCACHE_VERSION}-${sccache_target}.tar.gz"; \
    curl -fsSL \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "${sccache_url}/${sccache_asset}" \
        -o "${sccache_archive}"; \
    printf '%s  %s\n' "${sccache_sha256}" "${sccache_archive}" | sha256sum --check --strict -; \
    sccache_unpack="/tmp/sccache-${TARGETARCH}"; \
    mkdir -p "${sccache_unpack}"; \
    tar --extract --gzip --file "${sccache_archive}" --directory "${sccache_unpack}"; \
    sccache_root="${HOME}/.local/share/mise/installs/sccache/${SCCACHE_VERSION}/bin"; \
    mkdir -p "${sccache_root}"; \
    install -m 0755 \
        "${sccache_unpack}/sccache-v${SCCACHE_VERSION}-${sccache_target}/sccache" \
        "${sccache_root}/sccache"; \
    test -x "${sccache_root}/sccache"; \
    rm -rf "${sccache_unpack}" "${sccache_archive}"; \
    install_prebuilt_cargo_tool() { \
        package="$1"; \
        version="$2"; \
        case "${package}@${version}:${TARGETARCH}" in \
            cargo-audit@0.22.2:amd64) \
                asset_repo=rustsec/rustsec; release_path=cargo-audit/v0.22.2; \
                asset_filename=cargo-audit-x86_64-unknown-linux-gnu-v0.22.2.tgz; \
                asset_sha256=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39; \
                executable_member=cargo-audit-x86_64-unknown-linux-gnu-v0.22.2/cargo-audit \
                ;; \
            cargo-audit@0.22.2:arm64) \
                asset_repo=rustsec/rustsec; release_path=cargo-audit/v0.22.2; \
                asset_filename=cargo-audit-aarch64-unknown-linux-gnu-v0.22.2.tgz; \
                asset_sha256=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd; \
                executable_member=cargo-audit-aarch64-unknown-linux-gnu-v0.22.2/cargo-audit \
                ;; \
            cargo-deny@0.20.2:amd64) \
                asset_repo=EmbarkStudios/cargo-deny; release_path=0.20.2; \
                asset_filename=cargo-deny-0.20.2-x86_64-unknown-linux-musl.tar.gz; \
                asset_sha256=9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f; \
                executable_member=cargo-deny-0.20.2-x86_64-unknown-linux-musl/cargo-deny \
                ;; \
            cargo-deny@0.20.2:arm64) \
                asset_repo=EmbarkStudios/cargo-deny; release_path=0.20.2; \
                asset_filename=cargo-deny-0.20.2-aarch64-unknown-linux-musl.tar.gz; \
                asset_sha256=995c82be0defc7a025cae49a2aa2644ce8245c9a3318fc4103907c6a285e8c7d; \
                executable_member=cargo-deny-0.20.2-aarch64-unknown-linux-musl/cargo-deny \
                ;; \
            cargo-dylint@6.0.4:amd64) \
                asset_repo=trailofbits/dylint; release_path=v6.0.4; \
                asset_filename=cargo-dylint-x86_64-unknown-linux-gnu-v6.0.4.tar.gz; \
                asset_sha256=14195423ac6bfe6b055ffa94e0c48e282e1f5997abd98dfb4ea8bdf4633aec5c; \
                executable_member=cargo-dylint-x86_64-unknown-linux-gnu-v6.0.4/cargo-dylint \
                ;; \
            cargo-dylint@6.0.4:arm64) \
                asset_repo=trailofbits/dylint; release_path=v6.0.4; \
                asset_filename=cargo-dylint-aarch64-unknown-linux-gnu-v6.0.4.tar.gz; \
                asset_sha256=76bea6b65babdbc6d1d96b15b89e731c0afba83338999c0f81a34d3dfd8d8508; \
                executable_member=cargo-dylint-aarch64-unknown-linux-gnu-v6.0.4/cargo-dylint \
                ;; \
            cargo-fuzz@0.13.2:amd64) \
                asset_repo=rust-fuzz/cargo-fuzz; release_path=0.13.2; \
                asset_filename=cargo-fuzz-0.13.2-x86_64-unknown-linux-musl.tar.gz; \
                asset_sha256=b5b704018b63e0f151c17a057ac53b5111e1db545d1b9f72fee79f08a545931c; \
                executable_member=cargo-fuzz \
                ;; \
            cargo-hack@0.6.45:amd64) \
                asset_repo=taiki-e/cargo-hack; release_path=v0.6.45; \
                asset_filename=cargo-hack-x86_64-unknown-linux-gnu.tar.gz; \
                asset_sha256=16394b932180a4ae509a22b3b8294fc2525573d8592420133c428457ed676d5d; \
                executable_member=cargo-hack \
                ;; \
            cargo-hack@0.6.45:arm64) \
                asset_repo=taiki-e/cargo-hack; release_path=v0.6.45; \
                asset_filename=cargo-hack-aarch64-unknown-linux-gnu.tar.gz; \
                asset_sha256=821536b7dc4666764d36c09e665affcf98e3d69f5a99b171c03d47d3ec24d0e7; \
                executable_member=cargo-hack \
                ;; \
            cargo-hakari@0.9.38:amd64) \
                asset_repo=guppy-rs/guppy; release_path=cargo-hakari-0.9.38; \
                asset_filename=cargo-hakari-0.9.38-x86_64-unknown-linux-gnu.tar.gz; \
                asset_sha256=19fcbaf488dd51b4b0fe2412d8da37c65ba6aa72349351ba73f6c9f7c1087e04; \
                executable_member=cargo-hakari \
                ;; \
            cargo-hakari@0.9.38:arm64) \
                asset_repo=guppy-rs/guppy; release_path=cargo-hakari-0.9.38; \
                asset_filename=cargo-hakari-0.9.38-aarch64-unknown-linux-gnu.tar.gz; \
                asset_sha256=0076ddafb28c373125b30a8c04d6f4b7e4b59bf141fd51b6f47f89dc66922d34; \
                executable_member=cargo-hakari \
                ;; \
            cargo-llvm-cov@0.8.7:amd64) \
                asset_repo=taiki-e/cargo-llvm-cov; release_path=v0.8.7; \
                asset_filename=cargo-llvm-cov-x86_64-unknown-linux-gnu.tar.gz; \
                asset_sha256=9a75fe29538d3800b3da57f6f6efb64cba5c720a257bf0cb8b51f39d495a9168; \
                executable_member=cargo-llvm-cov \
                ;; \
            cargo-llvm-cov@0.8.7:arm64) \
                asset_repo=taiki-e/cargo-llvm-cov; release_path=v0.8.7; \
                asset_filename=cargo-llvm-cov-aarch64-unknown-linux-gnu.tar.gz; \
                asset_sha256=8f399d84993d13998b63fbe1084377713c719b00655c7d88d5b56c8c29105d90; \
                executable_member=cargo-llvm-cov \
                ;; \
            cargo-mutants@27.1.0:amd64) \
                asset_repo=sourcefrog/cargo-mutants; release_path=v27.1.0; \
                asset_filename=cargo-mutants-x86_64-unknown-linux-gnu.tar.gz; \
                asset_sha256=dfe6dc37d0342c891d2829b5a695aa57c2d0edecef7e7d0399a30cc6e206411e; \
                executable_member=cargo-mutants \
                ;; \
            cargo-shear@1.13.4:amd64) \
                asset_repo=Boshen/cargo-shear; release_path=v1.13.4; \
                asset_filename=cargo-shear-x86_64-unknown-linux-gnu.tar.gz; \
                asset_sha256=b52ad836fb99fb3881862d71bd965b9937b55da363f775d71d846244e580a50c; \
                executable_member=cargo-shear \
                ;; \
            cargo-shear@1.13.4:arm64) \
                asset_repo=Boshen/cargo-shear; release_path=v1.13.4; \
                asset_filename=cargo-shear-aarch64-unknown-linux-gnu.tar.gz; \
                asset_sha256=fadb98dc4f467bb62223d33b7f7b25b219f7df12d34d1a6d7b9486bd8d5c9584; \
                executable_member=cargo-shear \
                ;; \
            cargo-zigbuild@0.23.0:amd64) \
                asset_repo=rust-cross/cargo-zigbuild; release_path=v0.23.0; \
                asset_filename=cargo-zigbuild-x86_64-unknown-linux-gnu.tar.xz; \
                asset_sha256=c636e4f72b6f40a40ddf0414c8c6056f78b87eea3be0edf01f08d65fa028a373; \
                executable_member=cargo-zigbuild-x86_64-unknown-linux-gnu/cargo-zigbuild \
                ;; \
            cargo-zigbuild@0.23.0:arm64) \
                asset_repo=rust-cross/cargo-zigbuild; release_path=v0.23.0; \
                asset_filename=cargo-zigbuild-aarch64-unknown-linux-gnu.tar.xz; \
                asset_sha256=5917d5416884cba0f23c2653016f7f2df2ec04e74eb6b259598fecc066f8c429; \
                executable_member=cargo-zigbuild-aarch64-unknown-linux-gnu/cargo-zigbuild \
                ;; \
            codebook-lsp@0.3.42:amd64) \
                asset_repo=blopker/codebook; release_path=v0.3.42; \
                asset_filename=codebook-lsp-x86_64-unknown-linux-musl.tar.gz; \
                asset_sha256=979b9a92f7a433c8830b51783dd06aab1d2668aee991c22d42560b593d291f9c; \
                executable_member=codebook-lsp \
                ;; \
            codebook-lsp@0.3.42:arm64) \
                asset_repo=blopker/codebook; release_path=v0.3.42; \
                asset_filename=codebook-lsp-aarch64-unknown-linux-musl.tar.gz; \
                asset_sha256=5f1448369447f0f61e407e0082cd72a89f2ea7e47e3c45692b910a9b03adb6fe; \
                executable_member=codebook-lsp \
                ;; \
            dylint-link@6.0.4:amd64) \
                asset_repo=trailofbits/dylint; release_path=v6.0.4; \
                asset_filename=dylint-link-x86_64-unknown-linux-gnu-v6.0.4.tar.gz; \
                asset_sha256=54ce515583ade02b197bc11f6870fd755c30e04b7e44ea015a507726de05fa1d; \
                executable_member=dylint-link-x86_64-unknown-linux-gnu-v6.0.4/dylint-link \
                ;; \
            dylint-link@6.0.4:arm64) \
                asset_repo=trailofbits/dylint; release_path=v6.0.4; \
                asset_filename=dylint-link-aarch64-unknown-linux-gnu-v6.0.4.tar.gz; \
                asset_sha256=dd33dd207272cdafab494089239587f93ab2b6b2af18312281b6754b24a1db13; \
                executable_member=dylint-link-aarch64-unknown-linux-gnu-v6.0.4/dylint-link \
                ;; \
            *) echo "unsupported pinned prebuilt Cargo tool: ${package}@${version}:${TARGETARCH}" >&2; return 1 ;; \
        esac; \
        asset_url="https://github.com/${asset_repo}/releases/download/${release_path}/${asset_filename}"; \
        archive="/tmp/${package}-${version}-${TARGETARCH}.archive"; \
        binary="/tmp/${package}-${version}-${TARGETARCH}"; \
        curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --netrc-file /dev/null "${asset_url}" -o "${archive}"; \
        printf '%s  %s\n' "${asset_sha256}" "${archive}" | sha256sum --check --strict -; \
        case "${asset_url}" in \
            *.tar.xz) tar --extract --xz --file "${archive}" --to-stdout --no-wildcards -- "${executable_member}" > "${binary}" ;; \
            *) tar --extract --gzip --file "${archive}" --to-stdout --no-wildcards -- "${executable_member}" > "${binary}" ;; \
        esac; \
        test -s "${binary}"; \
        install_root="${HOME}/.local/share/mise/installs/${package}/${version}/bin"; \
        mkdir -p "${install_root}"; \
        install -m 0755 "${binary}" "${install_root}/${package}"; \
        test -x "${install_root}/${package}"; \
        rm -f "${binary}" "${archive}"; \
    }; \
    install_mbx_cargo_tool() { \
        package="$1"; \
        version="$2"; \
        case "${package}@${version}" in \
            cargo-fuzz@0.13.2) crate_sha256=5acfd01930e49823e58c30dd8012d3338a620377d7c7d4cc140ca4b2169400e2 ;; \
            cargo-mutants@27.1.0) crate_sha256=07072e7bcdeb425d5e5fdbfd9f15a2c749e23cb2edf5ef40aee5876760ae1cf9 ;; \
            *) echo "unsupported pinned Cargo source: ${package}@${version}" >&2; exit 1 ;; \
        esac; \
        install_root="${HOME}/.local/share/mise/installs/${package}/${version}"; \
        source_archive="/tmp/${package}-${version}.crate"; \
        source_root="/tmp/jackin-cargo-sources/${package}-${version}"; \
        curl -fsSL \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            "https://static.crates.io/crates/${package}/${package}-${version}.crate" \
            -o "${source_archive}"; \
        printf '%s  %s\n' "${crate_sha256}" "${source_archive}" | sha256sum --check --strict -; \
        mkdir -p "${source_root}"; \
        tar --extract --gzip --file "${source_archive}" \
            --directory "${source_root}" --strip-components=1 \
            --no-same-owner --no-same-permissions; \
        test -s "${source_root}/Cargo.toml"; \
        test -s "${source_root}/Cargo.lock"; \
        MISE_EXEC_AUTO_INSTALL=0 \
        CARGO_TARGET_DIR="/home/agent/.cache/cargo-target-${TARGETARCH}" \
            mise exec -C /tmp/jackin-mise -- mbx install \
                --locked --path "${source_root}" --root "${install_root}"; \
        test -x "${install_root}/bin/${package}"; \
        rm -rf "${source_root}" "${source_archive}"; \
    }; \
    install_prebuilt_cargo_tool cargo-audit "${CARGO_AUDIT_VERSION}"; \
    install_prebuilt_cargo_tool cargo-deny "${CARGO_DENY_VERSION}"; \
    install_prebuilt_cargo_tool cargo-dylint "${CARGO_DYLINT_VERSION}"; \
    install_prebuilt_cargo_tool cargo-hack "${CARGO_HACK_VERSION}"; \
    install_prebuilt_cargo_tool cargo-hakari "${CARGO_HAKARI_VERSION}"; \
    install_prebuilt_cargo_tool cargo-llvm-cov "${CARGO_LLVM_COV_VERSION}"; \
    install_prebuilt_cargo_tool cargo-shear "${CARGO_SHEAR_VERSION}"; \
    install_prebuilt_cargo_tool cargo-zigbuild "${CARGO_ZIGBUILD_VERSION}"; \
    install_prebuilt_cargo_tool codebook-lsp "${CODEBOOK_LSP_VERSION}"; \
    install_prebuilt_cargo_tool dylint-link "${DYLINT_LINK_VERSION}"; \
    case "${TARGETARCH}" in \
        amd64) \
            install_prebuilt_cargo_tool cargo-fuzz "${CARGO_FUZZ_VERSION}"; \
            install_prebuilt_cargo_tool cargo-mutants "${CARGO_MUTANTS_VERSION}" \
            ;; \
        arm64) \
            install_mbx_cargo_tool cargo-fuzz "${CARGO_FUZZ_VERSION}"; \
            install_mbx_cargo_tool cargo-mutants "${CARGO_MUTANTS_VERSION}" \
            ;; \
        *) echo "unsupported TARGETARCH for Cargo tool installation: ${TARGETARCH}" >&2; exit 1 ;; \
    esac

# BoltFFI publishes verified x64 and ARM64 release binaries with custom names.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) boltffi_arch=x86_64; boltffi_sha256=342af5abf855dcea1b88b1f2fd8b72ba09083f0d8eab7a0930b954539defce4a ;; \
        arm64) boltffi_arch=aarch64; boltffi_sha256=ec4d6a94cd5c032e8a381a824deddf97c724e7e3f43d86050e4df9f86e2e7b41 ;; \
        *) echo "unsupported TARGETARCH for BoltFFI: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    boltffi_root="${HOME}/.local/share/mise/installs/boltffi-cli/${BOLTFFI_VERSION}"; \
    mkdir -p "${boltffi_root}/bin"; \
    boltffi_archive="/tmp/boltffi-linux-${boltffi_arch}.tar.gz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/boltffi/boltffi/releases/download/v${BOLTFFI_VERSION}/boltffi-linux-${boltffi_arch}.tar.gz" -o "${boltffi_archive}"; \
    printf '%s  %s\n' "${boltffi_sha256}" "${boltffi_archive}" | sha256sum --check --strict -; \
    tar --extract --gzip --file "${boltffi_archive}" --directory "${boltffi_root}/bin"; \
    test -x "${boltffi_root}/bin/boltffi"; \
    rm -f "${boltffi_archive}"

RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/agent/.cargo/git,uid=1000 \
    MISE_CARGO_BINSTALL_ONLY=1 mise install && \
    mise exec -- rustup component add rust-analyzer

# Checksum-pinned upstream helper binaries avoid a direct, unpinned Cargo install.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) \
            release_target=x86_64-unknown-linux-gnu; \
            cargo_watch_sha512=2b6e28821aea9642d79f24290b18f58be615ff6b52da5e1536c0ad9a1eda834af713c78183a356273047cd63c43bc6ebcb372bccbecccc1e45246cffbe043320; \
            lychee_sha256=1f4e0ef7f6554a6ed33dd7ac144fb2e1bbed98598e7af973042fc5cd43951c9a \
            ;; \
        arm64) \
            release_target=aarch64-unknown-linux-gnu; \
            cargo_watch_sha512=e1d29699863de701e57568b26e5ff2b2c8c6b93ee7a3a66209228a6ee40c60ea3c2cdd7b3840071b58e18bf4cb022c09ad43b329fab5f4f8a1d196bd4985bc85; \
            lychee_sha256=91a7bd65685da41b90ccb9bc867a3d649a7818042dae04ff405e55a25bddee4c \
            ;; \
        *) echo "unsupported TARGETARCH for helper binaries: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cargo_watch_archive="/tmp/cargo-watch-v${CARGO_WATCH_VERSION}-${release_target}.tar.xz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/watchexec/cargo-watch/releases/download/v${CARGO_WATCH_VERSION}/cargo-watch-v${CARGO_WATCH_VERSION}-${release_target}.tar.xz" -o "${cargo_watch_archive}"; \
    printf '%s  %s\n' "${cargo_watch_sha512}" "${cargo_watch_archive}" | sha512sum --check --strict -; \
    mkdir -p /tmp/cargo-watch; \
    tar --extract --xz --file "${cargo_watch_archive}" --directory /tmp/cargo-watch --strip-components=1; \
    install -m 0755 /tmp/cargo-watch/cargo-watch "${HOME}/.local/bin/cargo-watch"; \
    lychee_archive="/tmp/lychee-${release_target}.tar.gz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-${release_target}.tar.gz" -o "${lychee_archive}"; \
    printf '%s  %s\n' "${lychee_sha256}" "${lychee_archive}" | sha256sum --check --strict -; \
    mkdir -p /tmp/lychee; \
    tar --extract --gzip --file "${lychee_archive}" --directory /tmp/lychee --strip-components=1; \
    install -m 0755 /tmp/lychee/lychee "${HOME}/.local/bin/lychee"; \
    rm -rf /tmp/cargo-watch /tmp/lychee "${cargo_watch_archive}" "${lychee_archive}"

RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    mise install "opentofu@${OPENTOFU_VERSION}" && \
    mise use -g --pin "opentofu@${OPENTOFU_VERSION}"

# The package lock pins both Node CLIs and every npm tarball they install.
COPY --chown=agent:agent maintained-image-build/skills-cli/package.json maintained-image-build/skills-cli/package-lock.json /home/agent/.local/share/architect-node-tools/

# Pinned sources avoid moving-branch lookups, Git credential fallbacks, and adapter drift.
RUN . ~/.profile && set -eu; \
    node_bin="${HOME}/.local/share/mise/installs/node/${NODE_TOOLS_VERSION}/bin"; \
    npm_home=/tmp/architect-npm-home; \
    npm_config_dir=/tmp/architect-npm-config; \
    source_root=/tmp/architect-sources; \
    git_home=/tmp/architect-git-home; \
    rm -rf "${npm_home}" "${npm_config_dir}" "${source_root}" /tmp/architect-npm-cache "${git_home}"; \
    mkdir -p "${npm_home}" "${npm_config_dir}" "${source_root}/git-template"; \
    : > "${npm_config_dir}/user.npmrc"; \
    : > "${npm_config_dir}/global.npmrc"; \
    export PATH="${node_bin}:${PATH}"; \
    test "$("${node_bin}/node" --version)" = "v${NODE_TOOLS_VERSION}"; \
    test "$("${node_bin}/npm" --version)" = "11.19.0"; \
    cd /tmp; \
    env -i HOME="${npm_home}" PATH="${node_bin}:/usr/bin:/bin" \
        NPM_CONFIG_USERCONFIG="${npm_config_dir}/user.npmrc" \
        NPM_CONFIG_GLOBALCONFIG="${npm_config_dir}/global.npmrc" \
        NPM_CONFIG_REGISTRY=https://registry.npmjs.org/ \
        NPM_CONFIG_CACHE=/tmp/architect-npm-cache \
        NPM_CONFIG_IGNORE_SCRIPTS=true NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false \
        "${node_bin}/npm" ci --prefix "${HOME}/.local/share/architect-node-tools" \
            --ignore-scripts --no-audit --no-fund; \
    mkdir -p "${git_home}"; \
    git_clean() { \
        env -i HOME="${git_home}" PATH=/usr/bin:/bin \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https GIT_LFS_SKIP_SMUDGE=1 \
            /usr/bin/git "$@"; \
    }; \
    acquire_source() { \
        source_name="$1"; \
        repository="$2"; \
        commit_sha="$3"; \
        tree_sha="$4"; \
        archive_sha="$5"; \
        source_dir="${source_root}/${source_name}"; \
        git_dir="${source_root}/${source_name}.git"; \
        archive_path="${source_root}/${source_name}.tar"; \
        mkdir -p "${source_dir}"; \
        git_clean init --template="${source_root}/git-template" --quiet "${git_dir}"; \
        git_clean -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "${git_dir}" \
            fetch --quiet --depth=1 "https://github.com/${repository}.git" "${commit_sha}"; \
        test "$(git_clean -C "${git_dir}" rev-parse FETCH_HEAD)" = "${commit_sha}"; \
        test "$(git_clean -C "${git_dir}" rev-parse 'FETCH_HEAD^{tree}')" = "${tree_sha}"; \
        git_clean -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "${git_dir}" \
            archive --format=tar --output="${archive_path}" FETCH_HEAD; \
        printf '%s  %s\n' "${archive_sha}" "${archive_path}" | sha256sum --check --strict -; \
        tar --extract --file "${archive_path}" --directory "${source_dir}" --no-same-owner; \
        rm -rf "${git_dir}" "${archive_path}"; \
    }; \
    acquire_source caveman JuliusBrussee/caveman \
        8b0c1d3699b8d83e87fe4605b378da20c41555e0 \
        4e8aa5e191457ba9ebd34b4a7eee6a7bd246ccff \
        954909b361634fad64bd299642ca3d5d5f6320d8b9fb6760efc51a4e83eea718; \
    acquire_source jackin-dev jackin-project/jackin-dev \
        a01b342162bc56cdf1e8bbaab793e73d31c1d621 \
        df2808b2fd551d0466036352579571b20efb0933 \
        97972af0add734cdeee560dba3c3861d8da8084f04b688aabfbcfe6c900fd0e1; \
    acquire_source shadcn-improve shadcn/improve \
        cac56e1ebd3c279aa9153616cfeac7b174ab90f9 \
        b8195551ac5dae1830e0eaed20079a4ee555a20b \
        9aa4067c152f18270a220b01dce8d83da9e5a8f30cd264f3a2ad30eedc1d14b1; \
    skills_cli="${HOME}/.local/share/architect-node-tools/node_modules/.bin/skills"; \
    test -x "${skills_cli}" && test -x "${HOME}/.local/share/architect-node-tools/node_modules/.bin/ctx7"; \
    caveman_source="${source_root}/caveman"; \
    "${node_bin}/node" "${caveman_source}/bin/install.js" --only opencode --no-mcp-shrink; \
    test -f "${HOME}/.config/opencode/plugins/caveman/plugin.js"; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${caveman_source}" -a codex --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${caveman_source}" -a amp --yes --global; \
    test -f "${HOME}/.agents/skills/caveman/SKILL.md"; \
    jackin_source="${source_root}/jackin-dev"; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${jackin_source}" -s '*' -a codex --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${jackin_source}" -s '*' -a amp --yes --global; \
    test -f "${HOME}/.agents/skills/jackin-propose/SKILL.md"; \
    test -f "${HOME}/.agents/skills/jackin-merge-pr/SKILL.md"; \
    shadcn_source="${source_root}/shadcn-improve"; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a claude-code --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a codex --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a amp --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a opencode --yes --global; \
    DO_NOT_TRACK=1 "${skills_cli}" add "${shadcn_source}" -a kimi-code-cli --yes --global; \
    test -f "${HOME}/.claude/skills/improve/SKILL.md"; \
    test -f "${HOME}/.agents/skills/improve/SKILL.md"; \
    rm -rf "${source_root}" "${npm_home}" "${npm_config_dir}" /tmp/architect-npm-cache /tmp/architect-git-home; \
    mkdir -p \
        /home/agent/.config/caveman \
        /home/agent/.claude \
        /home/agent/.codex \
        /home/agent/.config/amp \
        /home/agent/.kimi-code \
        /home/agent/.grok

# ── Token-optimisation stack ──────────────────────────────────────────────────

# AGENTS.md setup.
ENV CAVEMAN_DEFAULT_MODE=ultra
COPY --chown=root:agent --chmod=440 caveman-config.json /home/agent/.config/caveman/config.json
COPY --chown=agent:agent --chmod=644 AGENTS.md.d/ /tmp/AGENTS.md.d/
RUN find /tmp/AGENTS.md.d -maxdepth 1 -type f -name '*.md' | sort | \
    while IFS= read -r file; do cat "${file}"; printf '\n'; done > /tmp/AGENTS.md && \
    install -m 0644 /tmp/AGENTS.md /home/agent/AGENTS.md && \
    install -m 0644 /tmp/AGENTS.md /home/agent/CLAUDE.md && \
    ln -sf /home/agent/CLAUDE.md /home/agent/.claude/CLAUDE.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.codex/AGENTS.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.config/amp/AGENTS.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.kimi-code/AGENTS.md && \
    ln -sf /home/agent/AGENTS.md /home/agent/.grok/AGENTS.md

# Headroom.
RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    mise install "uv@${UV_VERSION}" && \
    mise use -g --pin "uv@${UV_VERSION}"

RUN . ~/.profile && uv tool install --no-build "headroom-ai[mcp]==${HEADROOM_VERSION}"

# RTK.
RUN --mount=type=cache,target=/home/agent/.cache/mise,uid=1000 \
    mise install "rtk@${RTK_VERSION}" && \
    mise use -g --pin "rtk@${RTK_VERSION}" && \
    mise exec -- rtk --version

ENV RTK_TELEMETRY_DISABLED=1

# opencode RTK.
RUN . ~/.profile && \
    rtk init -g --opencode && \
    test -f /home/agent/.config/opencode/plugins/rtk.ts
