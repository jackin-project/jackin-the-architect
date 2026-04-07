# the-architect

`the-architect` is the jackin agent for developing [jackin](https://github.com/donbeave/jackin) itself.

> "I am the Architect. I created the Matrix."

It provides the Rust development environment needed to build and test the jackin CLI.

## Usage

```sh
jackin load the-architect
```

## Contract

- Final Dockerfile stage must literally be `FROM projectjackin/construct:trixie`
- Plugins are declared in `jackin.agent.toml`

## Environment

- **Rust** (latest stable via mise) with clippy and rustfmt
- **cargo-nextest** — fast test runner
- **cargo-watch** — file watcher for continuous builds/tests
- **Node.js** LTS (via mise)
- System build tools (`build-essential`, `libssl-dev`, `pkg-config`, `cmake`)

Shared shell/runtime tools come from `projectjackin/construct:trixie`.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
