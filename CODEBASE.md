# Pinchflat — Codebase & Tooling Overview

## Project Source Directories

| Directory               | Purpose                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------ |
| `lib/pinchflat/`        | Core Elixir business logic — downloading, indexing, media, sources, yt-dlp integration, settings, etc. |
| `lib/pinchflat_web/`    | Phoenix web layer — controllers, LiveView components, helpers                                          |
| `test/`                 | Mirror of `lib/` with test files, plus fixtures, support helpers, and test scripts                     |
| `priv/repo/migrations/` | 80 Ecto database migration files (2024-01 through 2026-06)                                             |
| `priv/gettext/`         | i18n translation templates and English error strings                                                   |
| `priv/static/`          | Static web assets: favicon, Satoshi fonts (44 files), images, robots.txt                               |
| `priv/grafana/`         | 6 Grafana dashboard JSON definitions (BEAM, Ecto, Oban, Phoenix, LiveView, Application)                |
| `assets/js/`            | Frontend JS — Alpine.js app entry, helpers, tabs, topbar vendor lib                                    |
| `assets/css/`           | App CSS + Satoshi font CSS                                                                             |

---

## Technology Stack

### Language & Runtime

| Technology | Version  | Role                                                         |
| ---------- | -------- | ------------------------------------------------------------ |
| Elixir     | 1.20.2   | Primary application language                                 |
| Erlang/OTP | 28.5.0.3 | Runtime VM                                                   |
| Node.js    | 24.x     | Asset pipeline only (esbuild, Tailwind, Yarn) — not a server |

### Web Framework

| Technology           | Role                                                           |
| -------------------- | -------------------------------------------------------------- |
| Phoenix 1.7          | HTTP router, controllers, endpoint                             |
| Phoenix LiveView 1.0 | Real-time server-rendered UI — no custom WebSocket code needed |
| Plug/Cowboy          | HTTP server adapter                                            |

### Database

| Technology                  | Role                                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------------- |
| SQLite (via `ecto_sqlite3`) | Embedded database — no external DB process                                                            |
| Ecto 3.12                   | ORM and query layer                                                                                   |
| SQLean                      | SQLite extension library loaded at runtime per architecture (`sqlean-linux-x86` / `sqlean-linux-arm`) |

### Background Jobs

| Technology | Role                                                                                                  |
| ---------- | ----------------------------------------------------------------------------------------------------- |
| Oban 2.17  | Job queue backed by SQLite — handles all async work (indexing, downloading, retention, notifications) |

### External Tools (runtime dependencies)

| Technology       | Role                                                                |
| ---------------- | ------------------------------------------------------------------- |
| yt-dlp           | Core downloader — wraps YouTube and other platform downloads        |
| ffmpeg / ffprobe | Media processing and probing                                        |
| Deno             | Required by yt-dlp for certain YouTube downloads (see yt-dlp#14404) |
| Apprise          | Multi-platform notification dispatch                                |

### Frontend

| Technology   | Role                                                                |
| ------------ | ------------------------------------------------------------------- |
| Alpine.js 3  | Lightweight client-side reactivity (tabs, dropdowns, etc.)          |
| Tailwind CSS | Utility-first CSS framework with dark mode and custom design tokens |
| esbuild      | JavaScript bundler                                                  |
| Heroicons    | Icon set (SVG, via Tailwind plugin)                                 |
| Simple Icons | Brand/logo icons (SVG, via Tailwind plugin)                         |
| Satoshi      | Custom typeface (self-hosted in `priv/static/`)                     |

### Observability

| Technology                                     | Role                                                                                         |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------- |
| PromEx                                         | Prometheus metrics exporter for the BEAM, Ecto, Oban, Phoenix, and LiveView                  |
| Telemetry / TelemetryMetrics / TelemetryPoller | Instrumentation and metric aggregation                                                       |
| Phoenix LiveDashboard                          | Built-in runtime dashboard (process info, memory, etc.)                                      |
| Grafana                                        | 6 pre-built dashboards in `priv/grafana/` (BEAM, Ecto, Oban, Phoenix, LiveView, Application) |

### Elixir Libraries (notable)

| Library             | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NimbleParsec        | Parser combinators — used to parse yt-dlp output formats                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Timex               | Date/time utilities                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Jason               | JSON encoding/decoding                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Gettext             | i18n — English error strings in `priv/gettext/`                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Finch               | HTTP client (used by Swoosh and internal HTTP calls)                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `:httpc` / `:inets` | Erlang's built-in HTTP client — used by `Pinchflat.HTTP.HTTPClient` to fetch RSS feeds, YouTube Data API pages, and GitHub release JSON; responses are streamed and aborted when the configurable `max_body_length` cap is exceeded, and 301/302/303/307/308 redirects are followed manually (up to the configurable `max_redirects` cap, default 5) because `:httpc`'s own `autoredirect` has no hop-count knob and surfaces raw 3xx responses or crashes on unusable `Location` headers |
| Swoosh              | Email library (wired up but not a primary feature)                                                                                                                                                                                                                                                                                                                                                                                                                                        |

### Code Quality & Testing

| Technology           | Used in   | Role                                                           |
| -------------------- | --------- | -------------------------------------------------------------- |
| Credo + credo_naming | dev/test  | Elixir static analysis and naming conventions                  |
| Sobelow              | dev/test  | Security vulnerability scanner                                 |
| mix_audit            | dev/test  | Dependency vulnerability scanner (`mix deps.audit`)            |
| ex_check             | dev/test  | Unified check runner (`mix check`) — orchestrates all tools    |
| Mox                  | test      | Mock library for behaviour-based test doubles                  |
| LazyHTML             | test      | HTML parser for controller/LiveView test assertions            |
| Faker                | test      | Fake data generation in test fixtures                          |
| Prettier             | dev/CI    | Formatter for JS, CSS, JSON, YAML, Markdown                    |
| sqleton              | local dev | ERD generation from the live SQLite DB (`yarn run create-erd`) |

### CI/CD & Tooling

| Technology              | Role                                                                             |
| ----------------------- | -------------------------------------------------------------------------------- |
| GitHub Actions          | CI/CD platform — PR checks, releases, Docker image builds                        |
| Docker / Docker Compose | Containerization for both dev and production                                     |
| Docker Buildx + QEMU    | Multi-architecture builds (`linux/amd64` + `linux/arm64`)                        |
| GHCR                    | GitHub Container Registry — hosts PR, RC, release, and CI base images            |
| release-please          | Automated semantic versioning and changelog generation from Conventional Commits |
| Renovate                | Automated dependency update PRs                                                  |

---

## Public Feed Authorization Model

Public podcast endpoints are gated by two independent controls, and the split is intentional.
`route_token` is the **OPML-only** access key — it is not a global "unauthenticated endpoints"
key. `expose_feed_endpoints` (env var `EXPOSE_FEED_ENDPOINTS`) is the separate switch for the
per-source endpoints.

| Endpoint                         | `route_token`   | Basic auth         | Anonymous when                |
| -------------------------------- | --------------- | ------------------ | ----------------------------- |
| `GET /sources/opml`              | Always required | `maybe_basic_auth` | Never — token is mandatory    |
| `GET /sources/:uuid/feed`        | Not used        | `maybe_basic_auth` | `expose_feed_endpoints` is on |
| `GET /sources/:uuid/feed_image`  | Not used        | `maybe_basic_auth` | `expose_feed_endpoints` is on |
| `GET /media/:uuid/episode_image` | Not used        | `maybe_basic_auth` | `expose_feed_endpoints` is on |
| `GET /media/:uuid/stream`        | Not used        | `maybe_basic_auth` | `expose_feed_endpoints` is on |

`maybe_basic_auth/2` (`lib/pinchflat_web/plugs.ex`) is a no-op when `expose_feed_endpoints` is
true; otherwise it enforces basic auth only when `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD`
are both set. So with no credentials configured and `EXPOSE_FEED_ENDPOINTS` unset, the feed
endpoints are still anonymous — `route_token` does not change that.

Feed, image, and stream endpoints deliberately do not accept `route_token`: podcast clients
fetch enclosure and artwork URLs independently of the feed and cannot carry a query-param token,
so requiring one would break playback. UUIDs are unguessable, but they are capabilities, not
authorization — treat `EXPOSE_FEED_ENDPOINTS` as the public-exposure switch and keep basic auth
(or a reverse-proxy boundary) for private hosting.

Note: `config/runtime.exs` enables `expose_feed_endpoints` when `EXPOSE_FEED_ENDPOINTS` is set to
**any** non-empty value (`String.length(System.get_env("EXPOSE_FEED_ENDPOINTS", "")) > 0`),
including the literal string `"false"`. Leave the variable unset to keep the endpoints
basic-auth gated.

---

## Build & Asset Pipeline

Used in both local dev and CI/CD.

| File                        | Used in    | Purpose                                                                                                                         |
| --------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `mix.exs`                   | both       | Elixir project definition — deps, Mix aliases (`setup`, `test`, `assets.build`, `assets.deploy`, `check`, `version.bump`, etc.) |
| `mix.lock`                  | both       | Locked Elixir dependency versions                                                                                               |
| `assets/tailwind.config.js` | both       | Tailwind config — dark mode, custom font/color/spacing tokens, Heroicons + Simple Icons SVG plugins, Phoenix/LiveView variants  |
| `assets/package.json`       | both       | Frontend JS deps (Alpine.js)                                                                                                    |
| `assets/yarn.lock`          | both       | Locked frontend JS deps                                                                                                         |
| `package.json`              | local only | Root JS tooling — Prettier, sqleton (ERD generation via `yarn run create-erd`)                                                  |
| `yarn.lock`                 | local only | Locked root tooling deps                                                                                                        |

esbuild and Tailwind are driven through Mix aliases defined in `mix.exs`, not standalone config files.

---

## Docker

| File                              | Used in    | Purpose                                                                                                                                                                                                                                                                                    |
| --------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `docker/ci-base.Dockerfile`       | CI/release | Shared base image (`ghcr.io/misospace/pinchflat-ci-base`) — provides Elixir, OTP, Node, FFmpeg, yt-dlp, Deno, Apprise; Deno and yt-dlp are fetched only after verifying committed SHA-256 digests. Both dev and selfhosted images build FROM it so toolchain versions live in one place    |
| `docker/ci-base.requirements.txt` | CI/release | Pinned pip requirements (e.g. Apprise) installed into the ci-base image, managed by Renovate                                                                                                                                                                                               |
| `docker/dev.Dockerfile`           | local only | Dev image — builds FROM `pinchflat-ci-base`, then installs dev extras (oh-my-zsh, dev deps)                                                                                                                                                                                                |
| `docker/selfhosted.Dockerfile`    | CI/release | Production multi-stage build — builder stage runs on `pinchflat-ci-base` and compiles the OTP release; minimal runtime image with only production deps (ffmpeg/yt-dlp copied from the builder, Deno fetched only after verifying committed SHA-256 digests). yt-dlp lives in `/opt/yt-dlp` |
| `docker/docker-run.dev.sh`        | local only | Dev container startup script — installs deps, migrates DB, starts IEX Phoenix server                                                                                                                                                                                                       |
| `docker-compose.yml`              | local only | Local dev environment (builds `dev.Dockerfile`, mounts working dir, exposes port 4008)                                                                                                                                                                                                     |

---

## Release & Versioning

| File                                      | Used in    | Purpose                                                                                                                                 |
| ----------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `version.txt`                             | CI/release | Single source of truth for current version, semver (read by CI for Docker image tags)                                                   |
| `release-please-config.json`              | CI/release | Release-Please config — "simple" release type managing root package                                                                     |
| `.release-please-manifest.json`           | CI/release | Release-Please version tracking manifest                                                                                                |
| `CHANGELOG.md`                            | CI/release | Auto-generated release notes                                                                                                            |
| `tooling/version_bump.sh`                 | local only | Legacy bash script to bump version (YYYY.M.D date format) in `mix.exs` — predates release-please semver; prefer the release-please flow |
| `rel/overlays/bin/docker_start`           | CI/release | OTP release entrypoint — runs `check_file_permissions`, sets umask, runs `migrate`, starts server                                       |
| `rel/overlays/bin/migrate`                | CI/release | Runs `Pinchflat.Release.migrate` in OTP release context                                                                                 |
| `rel/overlays/bin/check_file_permissions` | CI/release | Runs `Pinchflat.Release.check_file_permissions` in OTP release context                                                                  |

---

## CI/CD (`.github/workflows/`)

All workflows are CI/release only — they are never run locally.

| File                   | Purpose                                                                                                                                                                                   |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci-base.yml`          | CI Base Image — builds and pushes the shared `pinchflat-ci-base` toolchain image (amd64 + arm64) to GHCR                                                                                  |
| `ci.yml`               | PR pipeline — linting + tests, asserts the selfhosted image layout contract, builds the PR image (saved as an artifact) and the RC image (pushed to GHCR)                                 |
| `pr-image-publish.yml` | Publish PR Image — validates the `pr-image` artifact metadata against trusted GitHub run/PR data before pushing the PR image built by `ci.yml` to GHCR from the trusted base-repo context |
| `release-image.yml`    | Release Image — builds and pushes the selfhosted release image to GHCR (auto after the CI base, or manually for an explicit ref)                                                          |
| `release-please.yml`   | Release Please — runs tests, invokes Release-Please, builds and pushes the multi-arch release image to GHCR                                                                               |
| `image-cleanup.yml`    | Dev Image Cleanup — deletes old dev images (dispatch-only in this snapshot repo)                                                                                                          |
| `ai-pr-review.yaml`    | AI PR Review — automated AI review of pull requests                                                                                                                                       |

---

## Code Quality & Linting

All linting config files are used in both local dev and CI (CI runs `mix check` which invokes them all).

| File                 | Used in | Purpose                                                                                                                                                                                     |
| -------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.formatter.exs`     | both    | Elixir formatter config (120-char line length, LiveView HTML formatter)                                                                                                                     |
| `tooling/.credo.exs` | both    | Credo static analysis config                                                                                                                                                                |
| `tooling/.check.exs` | both    | `ex_check` runner config — orchestrates compiler, formatter, mix_audit, Sobelow, Prettier, ExUnit (warnings-as-errors in CI; `--cover` enforces the coverage threshold pinned in `mix.exs`) |
| `.sobelow-conf`      | both    | Sobelow security scanner config (suppresses single-user/self-hosted warnings)                                                                                                               |
| `.prettierrc.js`     | both    | Prettier config (100-char width, single quotes, LF line endings, trailing comma off)                                                                                                        |
| `.prettierignore`    | both    | Prettier ignore patterns                                                                                                                                                                    |

Run everything with `mix check`. Individual tools: `mix credo`, `mix sobelow`, `yarn run lint:check`.

---

## Dev Experience

| File                              | Used in          | Purpose                                                                                                                                                                                                                                                                                   |
| --------------------------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.iex.exs`                        | local only       | IEx shell startup — imports common aliases for interactive development                                                                                                                                                                                                                    |
| `.devcontainer/devcontainer.json` | local only       | VS Code Dev Container config — uses `docker-compose.yml`, recommends ElixirLS + Prettier extensions                                                                                                                                                                                       |
| `.mise/config.toml`               | local/automation | Repository development-bootstrap contract (misospace/courier#414) — pins Node/yarn and defines `bootstrap`/`check`/`test`; `check`/`test` delegate to `tooling/lint_test.sh`/`tooling/test.sh`, the authoritative toolchain stays `docker/ci-base.Dockerfile` (CI itself never runs mise) |
| `.mise/mise.lock`                 | local/automation | Committed lockfile generated by `mise lock` — exact pinned versions plus download URLs/checksums; part of the bootstrap contract, review diffs like dependency bumps                                                                                                                      |
| `config/config.exs`               | both             | Base app config (Repo, Endpoint, Oban, Gettext, Telemetry)                                                                                                                                                                                                                                |
| `config/dev.exs`                  | local only       | Dev env config — local tmp dirs, SQLite at `priv/repo/pinchflat_dev.db`, port 4008, esbuild/Tailwind file watchers                                                                                                                                                                        |
| `config/test.exs`                 | both             | Test env config — mocked yt-dlp/apprise executables, SQLite at `priv/repo/pinchflat_test.db`, Oban in manual mode                                                                                                                                                                         |
| `config/prod.exs`                 | CI/release       | Production config (asset digest manifest, Swoosh via Finch, info-level logging)                                                                                                                                                                                                           |
| `config/runtime.exs`              | CI/release       | Runtime config — reads env vars (PHX_SERVER, auth, YT_DLP_WORKER_CONCURRENCY), loads SQLean extensions per arch, configures Oban cron                                                                                                                                                     |

---

## Test Infrastructure

All test infrastructure is used in both local dev and CI.

| File/Dir                             | Purpose                                                                                                        |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `test/support/`                      | `conn_case.ex`, `data_case.ex`, `testing_helper_methods.ex` — Phoenix + Ecto test helpers                      |
| `test/support/fixtures/`             | Factory modules for jobs, media, profiles, sources, tasks                                                      |
| `test/support/files/`                | Static test data — channel/media photos, metadata JSON, info.json, test video (media.mkv), subtitle, thumbnail |
| `test/support/scripts/yt-dlp-mocks/` | Mock executables — `repeater.sh` (echo mock for yt-dlp/apprise), `101_exit_code.sh` (error code mock)          |

---

## Misc

| File/Dir                                 | Used in    | Purpose                                                                                                                                                                                                                                |
| ---------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `priv/repo/extensions/sqlean-linux-arm/` | CI/release | SQLean SQLite extensions (ARM64) — fetched by `tooling/fetch-sqlean.sh`, not committed (gitignored)                                                                                                                                    |
| `priv/repo/extensions/sqlean-linux-x86/` | CI/release | SQLean SQLite extensions (x86-64) — fetched by `tooling/fetch-sqlean.sh`, not committed (gitignored)                                                                                                                                   |
| `tooling/fetch-sqlean.sh`                | both       | Downloads the pinned SQLean release (`SQLEAN_VERSION`, Renovate-tracked) into `priv/repo/extensions/`, verifying each zip against a committed SHA-256 before unpacking; run by `mix setup` and the Docker builder before `mix release` |
| `tooling/pr_identity_resolver.sh`        | CI/release | Fail-closed resolver gating `pr-image-publish.yml`: resolves the trusted PR number/head SHA from `workflow_run` data, refusing ambiguous or superseded identity (issue #143)                                                           |
| `tooling/test_pr_identity_resolver.sh`   | CI/release | Regression suite for the identity resolver, run by `ci.yml` next to the metadata validator suite                                                                                                                                       |
| `tooling/pr_image_metadata.sh`           | CI/release | Fail-closed validator gating `pr-image-publish.yml`: rejects `pr-image` artifact metadata (`meta/pr`, `meta/sha`) that doesn't match the trusted PR number/head SHA from GitHub run/PR data (issue #139)                               |
| `tooling/test_pr_image_metadata.sh`      | CI/release | Regression suite for the metadata validator, run by `ci.yml`'s test job so a broken validator fails the ordinary PR gate, not the publisher                                                                                            |
| `tooling/selfhosted_image_checks.sh`     | CI/release | Image-level assertions for the selfhosted image's yt-dlp path/permission contract — permissions, symlink resolution, updater preconditions, in-place replacement, NUL-byte paths; owns the contract                                    |
| `tooling/test_selfhosted_image.sh`       | CI/release | Regression suite for the selfhosted image layout contract — asserts `docker/selfhosted.Dockerfile` contract without Docker, runs the in-image checks in a built image, asserts non-downgrading updates                                 |
| `priv/repo/seeds.exs`                    | local only | Database seed script                                                                                                                                                                                                                   |
| `priv/repo/erd.png`                      | local only | Entity-Relationship Diagram (generated via `yarn run create-erd`)                                                                                                                                                                      |
| `priv/cmd_wrapper.sh`                    | CI/release | Shell wrapper used around external commands (yt-dlp, apprise) at runtime                                                                                                                                                               |
| `.dockerignore`                          | CI/release | Docker build ignore list                                                                                                                                                                                                               |
| `.gitignore`                             | local only | Git ignore list                                                                                                                                                                                                                        |
| `CONTRIBUTING.md`                        | —          | Contribution guidelines                                                                                                                                                                                                                |
| `LICENSE`                                | —          | Project license                                                                                                                                                                                                                        |
| `.github/ISSUE_TEMPLATE/`                | —          | Bug report, feature request, and other issue templates                                                                                                                                                                                 |
| `.github/pull_request_template.md`       | —          | PR description template with license acknowledgment                                                                                                                                                                                    |
