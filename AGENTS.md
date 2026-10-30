# Pinchflat Codebase Guide

You review and write pull requests for a self-hosted Elixir/Phoenix media manager that wraps `yt-dlp`. This is the single entry point for humans and AI agents: what the app is, how to run it, what the code looks like, and what will get a PR rejected.

## What This Repo Is

- A Phoenix 1.8 / LiveView 1.2 application (`lib/pinchflat`, `lib/pinchflat_web`), Elixir `~> 1.17` (`mix.exs`)
- SQLite via `ecto_sqlite3` + the SQLean extension pack — no Postgres, no external services
- Oban (`Oban.Engines.Lite`) for all background work
- A **detached, community-maintained fork** of `kieraneglin/pinchflat`, now in the `misospace` org (`README.md`, `CONTRIBUTING.md`). Upstream is abandoned; this fork deliberately keeps its schema divergence reversible (`lib/pinchflat/release.ex`)
- Shipped as a single Docker container with no external dependencies. `yt-dlp`, `ffmpeg`, `apprise` and user scripts are the only external commands

## Companion Docs

| Question                                              | Read                                                                          |
| ----------------------------------------------------- | ----------------------------------------------------------------------------- |
| Where does file Y live? What is tool Z for?           | `CODEBASE.md` — file-by-file inventory of every config, script, and directory |
| Local dev server, Docker builds, indexing deep-dive   | `DEVELOPMENT.md`                                                              |
| Fork background, responsible-use policy, PR etiquette | `CONTRIBUTING.md`                                                             |

`CLAUDE.md` no longer exists — its contents were absorbed into this file. If a PR changes behaviour documented in `AGENTS.md`, `CODEBASE.md`, or `DEVELOPMENT.md`, the PR must update that doc: new config options, endpoints, or capabilities; changed processing/storage/cleanup behaviour; new or removed limitations; bug fixes that invalidate documented behaviour.

---

## Running It Locally

> **On macOS, run tests through Docker, not natively.** The suite needs Linux-only binaries (the SQLean `.so`, yt-dlp/ffmpeg/Deno/Apprise) that don't exist on the host, so `mix test` / `mix check` will not work directly. Two wrapper scripts run inside the pinned ci-base image and share a warm build cache:

- `tooling/test.sh [args…]` — **fast iteration loop.** Everything passes through to `mix test`; skips the non-test checks and asset builds.
  - `tooling/test.sh test/path/to/file_test.exs` — one file
  - `tooling/test.sh test/path/to/file_test.exs:42` — one test by line
  - `tooling/test.sh --failed` / `--stale` — re-run last failures / affected tests
  - `tooling/test.sh --clean …` — wipe the cached volumes first
  - `tooling/test.sh --shell` — drop into a shell in the container
- `tooling/lint_test.sh` — **pre-commit gate.** Full `mix check` in the same image. Slower; run once before committing, not while iterating. Shares volumes with `test.sh`.

**Clean-checkout / automation bootstrap.** `.mise/config.toml` + the committed `.mise/mise.lock` are the repository development-bootstrap contract (misospace/courier#414): `mise run bootstrap` idempotently installs the locked toolchain — Node, yarn, OTP `28.5.0.4` and Elixir `1.20.2` (the same releases `docker/ci-base.Dockerfile` ships) — plus the pinned SQLean extensions, then reports versions and executable paths. `mise run check` / `mise run test` take the authoritative Docker path (`tooling/lint_test.sh` / `tooling/test.sh` — the same image CI runs) whenever a Docker daemon is usable, and fall back to the same mix commands on the native toolchain where it is not (automation sandboxes have no host Docker socket). `mise` itself is the one prerequisite the contract cannot install. Details: `DEVELOPMENT.md`.

Dev server: `docker compose up` (app on `http://localhost:4008`). On a Linux box or inside `--shell`, the bare Mix tasks work directly:

```bash
mix setup               # deps.get + fetch-sqlean + DB create/migrate/seed + asset setup/build
iex -S mix phx.server   # dev server, port 4008

mix test                                # all tests (alias creates + migrates the test DB first)
mix test test/path/to/file_test.exs:42  # single test by line

mix check                               # full quality gate — what CI runs
                                        # (ex_unit runs `mix test --cover`; CI fails below the
                                        # coverage threshold pinned in mix.exs `test_coverage`)
mix credo                               # Elixir style (tooling/.credo.exs)
mix sobelow --config                    # security scan
yarn run lint:check                     # Prettier
yarn run lint:fix                       # Prettier auto-fix

mix ecto.migrate                        # migrate (also regenerates priv/repo/erd.png in dev)
mix ecto.rollback                       # rollback one migration
mix ecto.reset                          # drop + recreate + migrate + seed

mix assets.build                        # Tailwind + esbuild (dev)
mix assets.deploy                       # minified + digested (prod)
```

---

## Architecture

The subsystem map and domain invariants live in [pinchflat-domain-architecture](.agents/skills/pinchflat-domain-architecture/SKILL.md). Load it for background jobs, yt-dlp, indexing, boot, web, or configuration changes.

## Review Standards

The detailed review gates, testing rules, security boundaries, and migration requirements live in [pinchflat-review-standards](.agents/skills/pinchflat-review-standards/SKILL.md). Load this skill for code changes and PR reviews.

## Commits, Releases, and Docs

### Conventional Commits

Use [Conventional Commits](https://www.conventionalcommits.org/). Only `fix:`, `feat:`, and `!` / `BREAKING CHANGE:` bump the version:

- `fix:` → patch · `feat:` → minor · `!` / `BREAKING CHANGE:` → major
- `chore:` / `docs:` / `perf:` / `revert:` / `style:` / `refactor:` / `test:` / `ci:` → no bump

All of the above are recognised by release-please (`changelog-sections` in `release-please-config.json`) and sorted into the changelog; `test:` and `ci:` are hidden. Prefer `chore(deps):` for dependency bumps — the legacy `deps:` type still maps to Chores but is being phased out. Prefer `chore(ci):` over a bare `ci:` for pipeline changes, so they surface in Chores instead of being hidden.

### Write user-facing subjects for users

When a `fix:` or `feat:` changes something a user can see or feel — UI, download/indexing behaviour, settings, notifications, feeds — the **subject line** must describe the user-visible effect, not the internal mechanics. These flow into the release notes. Put the module/why/how in the commit **body**.

- Prefer `fix: correct pending count for sources with no downloaded media` over `fix: adjust MediaQuery pending clause for null download states`
- Prefer `feat: let sources skip livestreams still in progress` over `feat: add live_status check to indexing filter`
- Prefer `fix: stop re-downloading videos after a title change` over `fix: use media_id instead of title in download archive`

For `chore` / `refactor` / `test` / `ci` / internal `perf`, keep writing normal developer subjects — there's no user effect to lead with.

### Before you commit

1. While iterating, use `tooling/test.sh <path>` for fast feedback.
2. `yarn run lint:fix` — auto-fix Prettier so the CI prettier check can't fail.
3. `tooling/lint_test.sh` — reproduces CI's "Lint and Test" job in the same pinned ci-base image. Green here means green in CI. Requires Docker.
4. `bash tooling/test_selfhosted_image.sh` — asserts the selfhosted image's yt-dlp path/permission contract (Docker-free; CI runs the same suite plus the image-level checks against the built image).
5. If you're on `main`, branch first. **Never push unless explicitly asked.** Prefer amending when the work belongs to the same feature or fix.

### Releases

Automated via release-please; the current version lives in `version.txt` (and, mirrored, in `mix.exs` between the `x-release-please-*` markers). Merging the release PR cuts a release and publishes Docker images. `mix version.bump` / `tooling/version_bump.sh` still emit a legacy date-based `YYYY.M.D` version and predate release-please — don't use them.

---

## Review decisions and exceptions

Flag/approve/skip criteria and known stale artifacts are maintained in [pinchflat-review-standards](.agents/skills/pinchflat-review-standards/SKILL.md), so the review checklist has one source of truth.

## Filing issues for the autonomous loop

Issues here are picked up by an autonomous coding loop (dispatch → foreman), and two
parts of the body feed deterministic reviewer rails. Agents filing issues in this repo
must include both.

**1. State the ask in one imperative sentence.** The reviewer quotes it verbatim to
prove it actually read the issue. If it can only paraphrase, its GO is demoted to NO-GO
unless the rail below vouches — costing a revision cycle and an escalation review.

**2. Name the concrete file paths the fix is expected to touch** (backticks are fine).
The scope-overlap rail vouches for a diff that touches a named file, and that vouch is
what survives a paraphrased ask.

Name only paths you are confident about. An issue that names files the diff does _not_
touch is read as scope drift and also gets the change rejected — so when unsure, name
none rather than guessing.
