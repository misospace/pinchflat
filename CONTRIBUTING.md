# Contributing to Pinchflat

## Background

Pinchflat was created by [@kieraneglin](https://github.com/kieraneglin) and grew a dedicated community of self-hosters. When the original project became unmaintained, a fork has been created to keep it alive — applying backlogged PRs, fixing bugs, and perhaps continuing development.

This repo is community-run. There is no single owner; contributions from anyone are welcome.

## How to contribute

### Responsible Use

By contributing, you agree not to add features or documentation that encourage:

- Unauthorized copying of copyrighted content
- Circumvention of access controls, DRM, or paywalls
- Misrepresentation of platform affiliation or endorsement

### Reporting bugs and requesting features

Open an issue. Check for duplicates first. For bugs, include your Docker version, logs, and steps to reproduce.

### Submitting code

1. Fork the repo and create a branch from `main`.
2. Make your changes. If you're adding a feature, consider opening an issue first to discuss it.
3. Commit using [Conventional Commits](https://www.conventionalcommits.org/) — this drives automatic versioning:
   - `fix: ...` → patch release
   - `feat: ...` → minor release
   - `chore: ...` / `docs: ...` → no release bump
4. Open a PR against `main`. CI will run tests and build a Docker image tagged `pr-<number>-<sha>` for testing.
5. A maintainer will review and merge.

### Development setup

From a clean checkout, the noninteractive setup entry point is the mise
bootstrap contract: `mise run bootstrap` installs the pinned Node/yarn
toolchain, reports versions and executable paths, and reports whether the
authoritative validation entry points are available. Validation itself stays
with the Docker wrappers — `tooling/test.sh` for fast iteration and
`tooling/lint_test.sh` for the full CI-equivalent `mix check` gate (both need
Docker plus a one-time `docker login ghcr.io`); `mise run check` /
`mise run test` delegate to them. See `DEVELOPMENT.md`
("Reproducible Bootstrap") and `AGENTS.md` for the day-to-day loop.

## Release process

Releases are managed automatically by [release-please](https://github.com/googleapis/release-please). When PRs are merged to `main`, release-please maintains a running Release PR that tracks the next version. Merging that PR cuts a release, publishes a GitHub Release, and pushes versioned Docker images to GHCR.
