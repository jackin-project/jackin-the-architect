FROM donbeave/jackin-construct:trixie

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

# Rust toolchain
RUN mise install rust@latest && \
    mise use -g --pin rust@latest

# Rust dev tools
RUN . ~/.profile && \
    rustup component add clippy rustfmt rust-analyzer && \
    cargo install --locked cargo-nextest cargo-watch

# Node.js for tooling
RUN mise install node@lts && \
    mise use -g --pin node@lts
