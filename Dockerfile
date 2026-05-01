FROM projectjackin/construct:trixie

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install system packages needed for Rust builds
RUN sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    openssl \
    pkg-config \
    cmake && \
    sudo apt-get autoremove -y && \
    sudo rm -rf /var/lib/apt/* \
               /var/cache/apt/* \
               /tmp/*

USER claude

ENV MISE_TRUSTED_CONFIG_PATHS=/workspace

# Toolchain installs.
#
# - Rust is pinned to 1.95.0; keep in sync with the `rust:<version>-trixie`
#   pin in the construct base image (jackin/docker/construct/Dockerfile)
#   and with `rust-toolchain.toml` in the jackin/ repo, so all three
#   layers agree on the toolchain operators get at runtime.
# - Node.js tracks upstream LTS; mise `--pin` snapshots the resolved
#   version into the global config at build time.
# - OpenTofu is pinned to 1.11.6 — bumped explicitly via PR.
#
# Combined into a single RUN per docker:S7031 / hadolint DL3059 (one
# layer instead of four). The `. ~/.profile` line activates mise so the
# subsequent `rustup` and `cargo` calls resolve via the shims set up by
# the preceding `mise use -g --pin rust@1.95.0`.
RUN mise install rust@1.95.0 && \
    mise use -g --pin rust@1.95.0 && \
    . ~/.profile && \
    rustup component add clippy rustfmt rust-analyzer && \
    cargo install --locked cargo-nextest cargo-watch && \
    mise install node@lts && \
    mise use -g --pin node@lts && \
    mise install opentofu@1.11.6 && \
    mise use -g --pin opentofu@1.11.6
