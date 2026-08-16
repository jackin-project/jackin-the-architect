# GitHub workflow guidance

- Keep untrusted pull-request workflows isolated in `*-public-unmerged.yml` on
  pinned GitHub-hosted runners with read-only permissions and no secrets.
- Trusted default-branch automation must use pinned actions, least privilege,
  bounded concurrency, measured job timeouts, and credential-free checkout.
- Install project tooling through mise. Never use Homebrew in this repository.
- Keep `ubuntu-26.04` explicit; never use floating runner labels.

