---
name: pinchflat-domain-architecture
description: Review Pinchflat changes to background jobs, yt-dlp integration, indexing, boot, web routes, configuration injection, and domain workflows.
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
3. The recurring cron run **re-asserts** the held version for `pinned`, `nightly_frozen`, and a still-holding `nightly_until_stable` rather than no-op'ing — yt-dlp lives on the container's ephemeral filesystem, so an image swap reverts it to the baked-in build. The boot run only re-asserts for those held/pinned policies too, but skips `stable` and `nightly` so a container restart doesn't fire a GitHub API call at random and defeat the staggered cron's jitter.
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
- `http/` — small mockable HTTP client behaviour (`http_behaviour.ex` / `http_client.ex`) for RSS, YouTube API, and GitHub release fetches. Follows 301/302/303/307/308 redirects manually (up to a configurable `max_redirects`, default 5, read from `config :pinchflat, Pinchflat.HTTP.HTTPClient`) rather than using `:httpc`'s `autoredirect`, which has no hop-count knob and surfaces raw 3xx responses; relative/absolute `Location` values are merged via `URI.merge/2`, and a missing/unusable `Location` falls through to the standard non-2xx error tuple. Request headers are re-sent on every hop, so callers must not pass credential-bearing headers.
- `diagnostics/` — `QueueDiagnostics` powers the Oban queue diagnostics page. Queue cards expand to list current jobs (capped at 50, `get_jobs_for_queue/2`); Queue Health is an embedded LiveView (`QueueHealthLive`) so Refresh re-fetches in place. Discarded jobs can be reset or deleted; `describe_job/2` resolves job args to the Source/MediaItem/MediaProfile they target. Executing and retryable jobs can be **requeued** (`requeue_job/1`) — cancel the current run (killing its yt-dlp process) and enqueue a fresh copy at the back of the queue, re-linked via `Tasks.create_job_with_task/2`. This replaced a bare cancel that silently dropped work, which mattered for `YT_DLP_WORKER_CONCURRENCY=1` setups where one slow index holds the only slot.

### Boot sequence (`lib/pinchflat/boot/`)

Three GenServers, all `restart: :temporary` so they run once and exit:

1. `PreJobStartupTasks` — before Oban starts: reset stuck `executing` jobs to `retryable`, ensure the tmpfile directory and blank cookie/yt-dlp-config/user-script files exist, record installed yt-dlp/Apprise versions, run the `app_init` user script.
2. `PostJobStartupTasks` — after Oban starts: revive indexing chains whose jobs were discarded, without double-scheduling live ones.
3. `PostBootStartupTasks` — once everything is ready: trigger the yt-dlp self-update.

### Web layer

Standard Phoenix + LiveView. Routes in `lib/pinchflat_web/router.ex`; controllers organised by resource under `lib/pinchflat_web/controllers/` (sources, media_items, media_profiles, settings, podcasts, searches, pages); shared UI in `lib/pinchflat_web/components/`. Routing details that look like bugs but aren't:

- Public feed authorization is intentionally asymmetric across two independent controls. `GET /sources/opml` always requires the installation's `route_token` query param (constant-time compare) as the OPML-only access key, regardless of basic auth. `GET /sources/:uuid/feed`, `/sources/:uuid/feed_image`, `/media/:uuid/episode_image`, and `/media/:uuid/stream` take no token: they are gated solely by `maybe_basic_auth` (`lib/pinchflat_web/plugs.ex`), so when `expose_feed_endpoints` is true they are anonymously reachable by anyone who knows the UUID — podcast clients fetch enclosure/artwork URLs independently of the feed and cannot carry a query-param token. When it is false they require basic auth only if credentials are configured, and remain anonymous when none are set. `route_token` does not protect feed/stream/image data; see CODEBASE.md's "Public Feed Authorization Model"
- `/healthcheck` bypasses auth and CSRF
- `/dev/dashboard` is gated by a dedicated `:dev_dashboard` pipeline (`PinchflatWeb.Plugs.dev_dashboard_basic_auth/2`) that 401s when no basic auth credentials are configured — the default. With `BASIC_AUTH_USERNAME`/`BASIC_AUTH_PASSWORD` set, it delegates to `Plug.BasicAuth`, so configured installs still reach the LiveDashboard
- The `strip_trailing_extension` plug in `endpoint.ex` allows media streaming URLs with extensions
- 404/500 pages render through a dedicated standalone layout (`components/layouts/error.html.heex`, set as `render_errors` `root_layout`), deliberately free of flash, LiveView, and `Settings.get!` DB calls so error rendering can't crash mid-render
- `Plug.Static` pairs `only:` with `only_matching: ~w(favicon apple-touch-icon)` because `~p` emits digested filenames in prod that a literal `only:` match would reject
- The `/live` websocket explicitly sets `check_csrf: true` (Phoenix's existing default) and retains session `connect_info`; keep both settings visible. The development-only `/phoenix/live_reload/socket` checks origin against its request connection, which may reject a TLS-terminating dev proxy unless it forwards the public host, scheme, and port. Production's global `check_origin: false` remains unchanged for reverse-proxy deployments where the public host differs from the app's configured host

### Configuration injection

Executables and pluggable backends live in application config and are read **at runtime**, never hardcoded — that's what makes `config/test.exs` overrides work. New external tools and swappable backends must follow this pattern. See the [external-process boundary in the review standards](../pinchflat-review-standards/SKILL.md#external-process-boundary).

---

## Focused review procedure

- Use this map to identify the domain owner and follow the full path across contexts, schemas, workers, and UI rather than reviewing a changed function in isolation.
- Check lifecycle, retries, deduplication, concurrency, and error classification where background work or external processes change.
- Preserve the fast/slow indexing distinction and the separate per-tab channel indexing behavior described above.
- Review auth, public feed access, media serving, and routing according to the intentional distinctions documented above; do not infer that a missing token is a bug without checking the route's contract.
- Read CODEBASE.md and the relevant companion documentation when the change crosses subsystems. Require tests for normal behavior and meaningful failure paths, and report validation that could not be run as unknown.
