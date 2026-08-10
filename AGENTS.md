# Pinchflat — AI Review Standards & Codebase Guide

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

Dev server: `docker compose up` (app on `http://localhost:4008`). On a Linux box or inside `--shell`, the bare Mix tasks work directly:

```bash
mix setup               # deps.get + fetch-sqlean + DB create/migrate/seed + asset setup/build
iex -S mix phx.server   # dev server, port 4008

mix test                                # all tests (alias creates + migrates the test DB first)
mix test test/path/to/file_test.exs:42  # single test by line

mix check                               # full quality gate — what CI runs
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

### Core domain model

Three entities drive everything:

- **`Source`** (`lib/pinchflat/sources/`) — a YouTube channel or playlist to track. Points at a `MediaProfile`.
- **`MediaItem`** (`lib/pinchflat/media/`) — one video/audio item belonging to a Source. Tracks download state, file paths, metadata.
- **`MediaProfile`** (`lib/pinchflat/profiles/`) — reusable download rules: format, quality, naming, Shorts/livestream handling, SponsorBlock, retention.

### Background jobs

All async work goes through **Oban**. A thin `Task` wrapper (`lib/pinchflat/tasks/`) links an `Oban.Job` to a `Source` or `MediaItem`. **Always schedule via `Tasks.create_job_with_task/2`** — it does deduplication and the task record atomically.

| Worker                          | Lives in         | Does                                                    |
| ------------------------------- | ---------------- | ------------------------------------------------------- |
| `FastIndexingWorker`            | `fast_indexing/` | Polls YouTube RSS to spot new videos cheaply            |
| `MediaCollectionIndexingWorker` | `slow_indexing/` | Full yt-dlp metadata fetch for a Source                 |
| `MediaDownloadWorker`           | `downloading/`   | Downloads one MediaItem via yt-dlp                      |
| `MediaQualityUpgradeWorker`     | `downloading/`   | Re-downloads after a delay for better quality           |
| `MediaRetentionWorker`          | `downloading/`   | Deletes old media per retention settings                |
| `SourceMetadataStorageWorker`   | `metadata/`      | Fetches/stores source-level metadata, images, NFO       |
| `FileSyncingWorker`             | `media/`         | Reconciles MediaItem records against files on disk      |
| `SourceDeletionWorker`          | `sources/`       | Cascading Source deletion                               |
| `MediaProfileDeletionWorker`    | `profiles/`      | Cascading MediaProfile deletion                         |
| `UpdateWorker`                  | `yt_dlp/`        | Keeps the yt-dlp binary on the configured update policy |

### yt-dlp integration (`lib/pinchflat/yt_dlp/`)

The executable path and runner module are injected via application config (`yt_dlp_executable`, `yt_dlp_runner`), so tests swap them out cleanly. In test, `config/test.exs` points both `yt_dlp_executable` and `apprise_executable` at `test/support/scripts/yt-dlp-mocks/`.

- **`ResponseDecoder`** decodes yt-dlp JSON output, logs the raw response, and returns `{:error, binary()}` on unparseable output (empty/truncated after an extractor change) so workers retry instead of crashing on `Jason.DecodeError`. Used by both `Media` and `MediaCollection`.
- **`UnavailableMedia`** classifies errors for media that can _never_ download (members-only, private, removed). Kept deliberately separate from the cookie-recoverable errors in `Downloading.MediaDownloader` so the cookie-retry path always runs first. With the `ignore_unavailable_media` setting on, both paths treat these as permanently unavailable rather than retrying.

**yt-dlp update policy** — logic in `UpdateManager` (`update_manager.ex`), DB-backed settings `yt_dlp_update_policy` / `yt_dlp_pinned_version` / `yt_dlp_nightly_baseline`, edited in the Settings UI. Policies: `stable`, `nightly`, `nightly_frozen`, `pinned`, `nightly_until_stable`. Non-obvious behaviour that is load-bearing — don't "simplify" it away:

1. `stable` resolves the exact latest stable version via `ReleaseLookup` (GitHub API) and targets `yt-dlp/yt-dlp@<version>`, **not** the `stable` channel, because a plain `--update` refuses to move backwards and would strand a user on a newer nightly. Falls back to the channel update if the lookup fails.
2. An exact nightly pins via the **channel alias** `nightly@<version>`; a `yt-dlp/yt-dlp_nightly@<tag>` repo path does not resolve.
3. The recurring cron/boot run **re-asserts** the held version for `pinned`, `nightly_frozen`, and a still-holding `nightly_until_stable` rather than no-op'ing — yt-dlp lives on the container's ephemeral filesystem, so an image swap reverts it to the baked-in build.
4. yt-dlp's exit codes are counterintuitive: a no-URL update exits `0` both when it updated and when already current, and exits `100` from its _error_ handler (bad tag, network failure, unwritable binary). `CommandRunner.update/1` therefore treats **only `0`** as success.
5. A settings change fires a one-shot `UpdateWorker.kickoff_apply/0` (`%{"apply_policy" => true}`), distinct from the recurring run.

### Indexing: fast vs slow

1. **Fast** (`fast_indexing/`) — parses YouTube's RSS feed to detect new video IDs cheaply and frequently, then schedules individual downloads.
2. **Slow** (`slow_indexing/`) — full yt-dlp collection fetches on a longer schedule to catch what RSS misses and refresh metadata. **YouTube channels are indexed one content tab at a time** (`/videos`, `/shorts`, `/streams`, canonical URLs built from `collection_id`) as separate yt-dlp invocations, each with its own download archive filtered to that tab's content type. This is required: `--break-on-existing` aborts the whole yt-dlp process, so one bare-channel-URL run would stop at the first known video and never reach shorts/streams (issue #59). A channel URL that already names a tab is used as-is; playlists and non-YouTube sources are never split. A tab that errors (no shorts tab, say) is skipped; the run only fails if every tab fails.

Both chains are **self-perpetuating** — each run schedules its successor — so a job that exhausts its retries kills the chain until the next boot reconciliation (see below).

### Other domain areas

- `metadata/` — parses and persists yt-dlp metadata, NFO files (Jellyfin/Kodi), source images. Source-level NFOs/artwork go to the source's "series directory", resolved from a simulated yt-dlp render of the output template. A `{{ series_root }}` marker in the template names that root explicitly (it expands to nothing in real renders; a sentinel is swapped in during resolution), with a fallback that detects a season-style folder (`Season 1`, `s2024`) and uses its parent. The marker handles flat and `/Channel/Videos/…` layouts the season heuristic can't (issue #141). Placement rules — one marker, attached to a directory name, not the filename — are enforced by `MediaProfile.validate_series_root_marker/2`, shared with `Source` for template overrides.
- `podcasts/` — podcast RSS and OPML feeds so Sources can be consumed by podcast apps.
- `lifecycle/` — media-lifecycle side effects: Apprise `notifications` and user-defined `user_scripts`, both via command runners.
- `http/` — small mockable HTTP client behaviour (`http_behaviour.ex` / `http_client.ex`) for RSS fetches.
- `diagnostics/` — `QueueDiagnostics` powers the Oban queue diagnostics page. Queue cards expand to list current jobs (capped at 50, `get_jobs_for_queue/2`); Queue Health is an embedded LiveView (`QueueHealthLive`) so Refresh re-fetches in place. Discarded jobs can be reset or deleted; `describe_job/2` resolves job args to the Source/MediaItem/MediaProfile they target. Executing and retryable jobs can be **requeued** (`requeue_job/1`) — cancel the current run (killing its yt-dlp process) and enqueue a fresh copy at the back of the queue, re-linked via `Tasks.create_job_with_task/2`. This replaced a bare cancel that silently dropped work, which mattered for `YT_DLP_WORKER_CONCURRENCY=1` setups where one slow index holds the only slot.

### Boot sequence (`lib/pinchflat/boot/`)

Three GenServers, all `restart: :temporary` so they run once and exit:

1. `PreJobStartupTasks` — before Oban starts: reset stuck `executing` jobs to `retryable`, ensure the tmpfile directory and blank cookie/yt-dlp-config/user-script files exist, record installed yt-dlp/Apprise versions, run the `app_init` user script.
2. `PostJobStartupTasks` — after Oban starts: revive indexing chains whose jobs were discarded, without double-scheduling live ones.
3. `PostBootStartupTasks` — once everything is ready: trigger the yt-dlp self-update.

### Web layer

Standard Phoenix + LiveView. Routes in `lib/pinchflat_web/router.ex`; controllers organised by resource under `lib/pinchflat_web/controllers/` (sources, media_items, media_profiles, settings, podcasts, searches, pages); shared UI in `lib/pinchflat_web/components/`. Routing details that look like bugs but aren't:

- Podcast RSS/OPML endpoints bypass basic auth intentionally (podcast apps can't authenticate)
- `/healthcheck` bypasses auth and CSRF
- The `strip_trailing_extension` plug in `endpoint.ex` allows media streaming URLs with extensions
- 404/500 pages render through a dedicated standalone layout (`components/layouts/error.html.heex`, set as `render_errors` `root_layout`), deliberately free of flash, LiveView, and `Settings.get!` DB calls so error rendering can't crash mid-render
- `Plug.Static` pairs `only:` with `only_matching: ~w(favicon apple-touch-icon)` because `~p` emits digested filenames in prod that a literal `only:` match would reject

### Configuration injection

Executables and pluggable backends live in application config and are read **at runtime**, never hardcoded — that's what makes `config/test.exs` overrides work. New external tools and swappable backends must follow this pattern. See §6.

---

## Review Standards

### 1. Gates That Will Reject a PR

CI is `.github/workflows/ci.yml`, job name **"Lint and Test"** — the only required check on the protected `main` branch (0 approvals required, so the gate _is_ the review). It runs inside `ghcr.io/misospace/pinchflat-ci-base:latest` with `MIX_ENV=test`:

```
mix check --no-fix --no-retry
```

`mix check` is aliased to `check --config=tooling/.check.exs` (`mix.exs`), which enables, in order: `compiler`, `formatter`, `mix_audit` (`mix deps.audit`), `sobelow`, `prettier_formatting` (`yarn run lint:check`), and `ex_unit` with `EX_CHECK=1`.

The external automation gate runs these four separately from a clone at `/work`, in a container, as a non-root uid. **All four are green today (1208 tests, 0 failures) — a PR that breaks one is the PR's fault, not flake:**

```
mix deps.get && mix format --check-formatted
mix deps.get && mix credo
mix deps.get && mix compile --warnings-as-errors
mix deps.get && ./tooling/fetch-sqlean.sh && mix test
```

Each must exit 0. Note the last one: `./tooling/fetch-sqlean.sh` is **required before `mix test`** (see §5.7).

`EX_CHECK=1` flips `elixirc_options: [warnings_as_errors: ...]` in `mix.exs`, and the gate passes `--warnings-as-errors` directly. **Any new compiler warning is a hard failure** — unused variables, unused aliases, deprecated calls, missing `@impl`.

### 2. Formatting

Two formatters, both blocking.

**Elixir** — `mix format --check-formatted`, config in `.formatter.exs`:

- `line_length: 120` (not the Elixir default of 98)
- `plugins: [Phoenix.LiveView.HTMLFormatter]` — `.heex` files and `~H` sigils are formatted too
- `import_deps: [:ecto, :ecto_sql, :phoenix]`
- `inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]`
- `subdirectories: ["priv/*/migrations"]` — migrations use `priv/repo/migrations/.formatter.exs` (`import_deps: [:ecto_sql]`), **not** the root config

Files under `tooling/` (`.check.exs`, `.credo.exs`) are outside `inputs` and are not Elixir-formatted. Don't "fix" them into the root formatter's style.

**Everything else** — Prettier 3.9.6 via `yarn run lint:check` (`package.json`). `.prettierignore` only excludes `assets/vendor/`, `CHANGELOG.md`, and `renovate.json`, plus `.gitignore` entries. That means **`.github/workflows/*.yml`, `*.md`, `*.json`, `*.js`, `*.css` are all Prettier-checked**. `.prettierrc.js`:

- `printWidth: 100`, `tabWidth: 2`, `useTabs: false`
- **`singleQuote: true`** — YAML and JS string literals use `'`, e.g. `branches: ['main']` in `ci.yml`
- `semi: false`, `trailingComma: 'none'`, `bracketSpacing: true`, `arrowParens: 'always'`, `endOfLine: 'lf'`

Editing a workflow file without running Prettier is the most common avoidable CI failure here (commit `7ae48da` exists solely to fix it). Run `yarn run lint:fix` before committing.

### 3. Credo (`tooling/.credo.exs`, run via `mix credo`)

Credo analyses `lib/`, `src/`, `test/`, `web/` only. Enabled checks that reject code people actually write:

1. **No `TODO` / `FIXME` comments.** `Credo.Check.Design.TagTODO` is configured with `exit_status: 2`, and `TagFIXME` is enabled. There are currently **zero** in `lib/` and `test/`. Track the follow-up in an issue, not a comment.
2. **Every module needs a `@moduledoc`.** `@moduledoc false` is the accepted answer for workers and internals (`lib/pinchflat/downloading/media_download_worker.ex`).
3. **Max line length 120** (`Credo.Check.Readability.MaxLineLength`).
4. **Alias nested modules.** `Credo.Check.Design.AliasUsage` with `if_nested_deeper_than: 2, if_called_more_often_than: 0` — a single call to `Pinchflat.Utils.FilesystemUtils.foo/1` must be aliased. This is why context modules carry long alias blocks.
5. **No debugging leftovers**: `Warning.IoInspect`, `Warning.Dbg`, `Warning.IExPry` are all enabled.
6. **`Warning.UnsafeExec`** is enabled — reinforces §6.
7. **Module name must match filename** (`CredoNaming.Check.Consistency.ModuleFilename`), excluding `test/support`, `priv`, `lib/pinchflat_web`, `test/pinchflat_web`.
8. `Refactor.Nesting` (max 4) and `Refactor.FunctionArity` are on — deeply nested `case`/`with` pyramids will fail.

House style Credo does not enforce but the codebase follows uniformly: **alias blocks are ordered shortest-to-longest**, not alphabetically (`lib/pinchflat/sources/sources.ex`). Don't reorder existing alias blocks alphabetically in an unrelated PR.

### 4. Elixir / Phoenix Conventions

1. **Contexts live in their own directory.** `Pinchflat.Sources` is `lib/pinchflat/sources/sources.ex`; its schema `Pinchflat.Sources.Source` is `lib/pinchflat/sources/source.ex`. Same for `media/`, `profiles/`, `settings/`, `tasks/`. New domain code goes in an existing context directory or a new one — not a bare file at `lib/pinchflat/`.
2. **Query logic goes in `*_query.ex`.** `media/media_query.ex`, `sources/sources_query.ex`, pulled in with `use Pinchflat.Media.MediaQuery`. Don't inline large `Ecto.Query` pipelines into controllers or LiveViews.
3. **Changesets live on the schema module** with an explicit `@allowed_fields` list (`lib/pinchflat/media/media_item.ex`). A new column not added to that list is silently unwritable.
4. **Oban workers** declare `use Oban.Worker, queue:, priority:, unique:, tags:` and expose a `kickoff_with_task/2,3` ending in `Tasks.create_job_with_task/2` (`media_download_worker.ex`). Never `Oban.insert/1` directly — the `Task` linkage and dedup are lost.
5. **Queue names must already exist** in `config/runtime.exs`: `default`, `fast_indexing`, `media_collection_indexing`, `media_fetching`, `remote_metadata`, `local_data`. A worker naming any other queue never runs.
6. **LiveViews are colocated** with their controller as `*_live.ex` under `lib/pinchflat_web/controllers/<resource>/` (e.g. `sources/source_live/`, `settings/setting_html/cookie_file_live.ex`), not in a separate `live/` tree. Routes use verified routes (`~p`, 116 call sites) — never a hand-built path string.
7. Shared UI belongs in `lib/pinchflat_web/components/` (`core_components.ex`, `custom_components/`).

### 5. Testing

**Every behaviour change needs a test.** 87 test files, 1208 tests, currently 0 failures.

1. **Pick the right case module.** `use Pinchflat.DataCase` for anything touching the DB (58 files), `use PinchflatWeb.ConnCase` for controllers/LiveViews (21 files). Both set up the Ecto sandbox, create the platform temp directories, `import Mox`, and `setup :verify_on_exit!`.
2. **Do not add `async: true` to a DataCase/ConnCase test.** SQLite can't run the sandbox concurrently; the only `async: true` tests are plain `use ExUnit.Case` pure-function tests (`utils/version_utils_test.exs`, `yt_dlp/unavailable_media_test.exs`). Five files pin `async: false` explicitly where global state is touched.
3. **Use the fixture factories** in `test/support/fixtures/` (`media_fixtures.ex`, `sources_fixtures.ex`, `profiles_fixtures.ex`, `job_fixtures.ex`, `tasks_fixtures.ex`). They use `Faker`; don't hand-roll `Repo.insert!`.
4. **Use `render_metadata/1` and `render_parsed_metadata/1`** (auto-imported from `test/support/testing_helper_methods.ex`) to load yt-dlp metadata fixtures from `test/support/files/*.json`. Those fixtures intentionally contain **yt-dlp-style absolute paths** captured on a `/app` checkout; the helper rebases `"/app/"` onto `File.cwd!()`. Reading the JSON with a bare `File.read!` reintroduces the bug fixed in `6a0140a` / `edf5fe4`.
5. **Never assume the checkout lives at a particular path.** CI symlinks `/app` → `$GITHUB_WORKSPACE` as a safety net (`ci.yml`), but the external gate runs from `/work` as a non-root uid. Any new absolute path in a fixture or test must go through the `render_metadata` rebase or `File.cwd!()`.
6. **Mock external boundaries with Mox, not by shelling out.** Mocks are declared in `test/test_helper.exs`: `YtDlpRunnerMock`, `AppriseRunnerMock`, `HTTPClientMock`, `UserScriptRunnerMock`, `YoutubeApiMock`. Use `expect(YtDlpRunnerMock, :run, ...)`. A new external dependency needs a behaviour + app-config key + mock, per §6.
7. **`mix test` cannot run without SQLean.** `config/runtime.exs` sets `config :pinchflat, Pinchflat.Repo, load_extensions: [...]` **outside** the `if config_env() == :prod` guard, so the test env loads it too. The `.so` files are gitignored (`.gitignore` lines 49–52). Run `./tooling/fetch-sqlean.sh` before `mix test` on a fresh clone — `mix setup` does this; a bare `mix test` does not. Migrations use `gen_random_uuid()` and queries use `regexp_like()`, both from SQLean.

### 6. External Commands (yt-dlp / Apprise / user scripts)

The security-sensitive boundary. It has exactly one shape:

1. Define a **behaviour** (`Pinchflat.YtDlp.YtDlpCommandRunner`, `Pinchflat.HTTP.HTTPBehaviour`, `Pinchflat.Lifecycle.UserScripts.UserScriptCommandRunner`, `Pinchflat.FastIndexing.YoutubeBehaviour`).
2. Resolve the implementation at **runtime** via `Application.get_env(:pinchflat, :yt_dlp_runner)` — never a compile-time module reference (`lib/pinchflat/yt_dlp/media.ex:167`).
3. Invoke through `Pinchflat.Utils.CliUtils.wrap_cmd/4`, which wraps `System.cmd/3` in `priv/cmd_wrapper.sh` so the child process dies when stdin closes (job cancellation). Build argv with `CliUtils.parse_options/1`; **never build a shell string**.
4. Only four modules may call `System.cmd` directly: `utils/cli_utils.ex`, `yt_dlp/command_runner.ex`, `lifecycle/notifications/command_runner.ex`, `lifecycle/user_scripts/command_runner.ex`. A fifth is a review flag.

### 7. Migrations & SQLite

1. `ecto_sqlite3` only. **No Postgres-isms** — no `ALTER COLUMN`, no `USING`, no arrays, no `jsonb`, no partial-index syntax SQLite lacks, no `CASCADE`.
2. Migrations are `alter table(...) do add ... end` inside `def change` (see `20260629120000_add_yt_dlp_update_policy_to_settings.exs`).
3. They're formatted by `priv/repo/migrations/.formatter.exs`, reachable through `subdirectories:` in the root `.formatter.exs`. `mix format` from the repo root covers them; a standalone `mix format priv/repo/migrations/foo.exs` does not use the right config.
4. Non-obvious columns get an inline comment naming the allowed values (see the `yt_dlp_update_policy` migration). This is the one place inline comments are the norm.
5. New columns must also be added to the schema's `@allowed_fields` (§4.3).

### 8. Fork Divergence Discipline

This fork's schema additions are **reversible by contract**. `lib/pinchflat/release.ex` implements `prep_for_upstream/0`, letting a user point their DB back at an upstream image with a byte-identical schema. **A PR adding a fork-only column must touch four places or it silently breaks that contract:**

1. the migration in `priv/repo/migrations/`
2. `@fork_only_columns` in `lib/pinchflat/release.ex`
3. `@fork_migration_versions` in the same file (the migration timestamp, underscore-separated integer)
4. a matching `execute_drop!/2` clause — a **literal** `ALTER TABLE ... DROP COLUMN` statement, because SQLite can't parameterize identifiers and the code deliberately avoids interpolation

...plus coverage in `test/pinchflat/release_test.exs`.

Also: prefer additive changes over rewriting upstream-shared modules. The wider the diff against upstream, the harder every future backport.

### 9. Security

1. **Sobelow runs inside `mix check`** with `.sobelow-conf` (`exit: :medium`, `threshold: :low`). Its `ignore` list is scoped to a single-user self-hosted threat model (`Traversal.*`, `Config.HTTPS`, `Config.CSP`, `XSS.ContentType`, `CI.System`). **Do not add entries to that list to silence a finding** — that's a rejection unless the PR argues the case explicitly.
2. **No raw SQL string interpolation.** The only `Ecto.Adapters.SQL.query!` call sites are in `lib/pinchflat/release.ex` and `lib/pinchflat/sources/source.ex:168`; every one binds parameters (`?`) or is a compile-time constant literal. New raw SQL is a flag.
3. `Ecto.Query.fragment/1` is fine and used (`fragment("? COLLATE NOCASE", ...)`) — it's parameterized. Interpolating a variable _into_ the fragment string is not.
4. `raw/1` in HEEx appears once, on hardcoded markup (`search_html.ex:22-23`). `raw/1` on anything derived from user input or yt-dlp output is a flag.
5. No secrets in config, workflows, or fixtures.

---

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
4. If you're on `main`, branch first. **Never push unless explicitly asked.** Prefer amending when the work belongs to the same feature or fix.

### Releases

Automated via release-please; the current version lives in `version.txt` (and, mirrored, in `mix.exs` between the `x-release-please-*` markers). Merging the release PR cuts a release and publishes Docker images. `mix version.bump` / `tooling/version_bump.sh` still emit a legacy date-based `YYYY.M.D` version and predate release-please — don't use them.

---

## What to Flag

- A new compiler warning of any kind (`--warnings-as-errors` is on)
- `TODO` / `FIXME` in `lib/` or `test/`, a module without `@moduledoc`, a line over 120 chars
- `IO.inspect`, `dbg`, `IEx.pry` left in `lib/`
- Any workflow/YAML/Markdown edit that wasn't Prettier-formatted (double quotes in YAML are the tell)
- `Oban.insert` bypassing `Tasks.create_job_with_task/2`, or a worker on an unconfigured queue
- `System.cmd` outside the four sanctioned modules; any shell-string command construction
- A hardcoded `/app` (or any absolute checkout path) in a test or fixture
- `async: true` on a `DataCase`/`ConnCase` test
- A behaviour change with no test
- A new fork-only column not registered in `Pinchflat.Release`
- New entries added to `.sobelow-conf`'s `ignore` list
- Postgres-only SQL in a migration
- Collapsing per-tab slow indexing back to a single channel URL, or treating a yt-dlp exit `100` as success
- Behaviour changes that don't update `AGENTS.md` / `CODEBASE.md` / `DEVELOPMENT.md`

## What to Approve

- Changes confined to a context directory with a matching test file
- New external tooling introduced as behaviour + app-config key + Mox mock
- Migrations that are additive, SQLite-safe, and registered in `Pinchflat.Release` when fork-only
- Tests that use the `test/support/fixtures/` factories and `render_metadata/1`
- Conventional Commit subjects where user-facing `fix:`/`feat:` lead with the user-visible effect
- Doc updates that accompany behaviour changes

## Skip Review For

- Renovate dependency bumps that only move versions in `mix.lock`, `yarn.lock`, `assets/yarn.lock`, or the pinned `SQLEAN_VERSION` / action SHAs
- release-please PRs (branch prefix `release-please`) — `CHANGELOG.md`, `version.txt`, `.release-please-manifest.json` are generated
- `priv/repo/erd.png` (regenerated by `yarn run create-erd` on migrate)
- Documentation-only PRs, beyond checking Prettier formatting

## Known Stale Artifacts — Do Not "Fix" Blindly

Real inconsistencies in the tree. Flag them if a PR touches the area; don't file drive-by cleanups.

| Artifact                                                                                      | Reality                                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CONTRIBUTING.md` says branch from and PR against `master`                                    | The default and protected branch is **`main`**; `ci.yml` and `ai-pr-review.yaml` both trigger on `branches: ['main']`                                                                                                                                    |
| `CODEBASE.md` and `DEVELOPMENT.md` reference `test/files/` and `test/scripts/yt-dlp-mocks/`   | They live at `test/support/files/` and `test/support/scripts/yt-dlp-mocks/`                                                                                                                                                                              |
| `ROLLBACK.md` and `rollback.sh` claim 18 migrations from `20260618215000` to `20260805120000` | Only the first **three** exist in this repo. Both files were inherited from a different downstream ("Tubeless") during the rehome and do **not** describe this fork's schema. `Pinchflat.Release.prep_for_upstream/0` is the authoritative rollback path |
| `DEVELOPMENT.md:65` builds `selfhosted.og.Dockerfile`                                         | No such file exists — the only Dockerfiles are under `docker/`                                                                                                                                                                                           |
| `tooling/version_bump.sh` / `mix version.bump` emit a `YYYY.M.D` version                      | Legacy, predates release-please. Versioning is release-please + `version.txt`                                                                                                                                                                            |

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

Name only paths you are confident about. An issue that names files the diff does *not*
touch is read as scope drift and also gets the change rejected — so when unsure, name
none rather than guessing.
