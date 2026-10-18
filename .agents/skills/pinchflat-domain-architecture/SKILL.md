---
name: pinchflat-domain-architecture
description: Review Pinchflat changes to background jobs, yt-dlp integration, indexing, boot, web routes, configuration injection, and domain workflows.
---

# Pinchflat domain architecture

Pinchflat is a Phoenix 1.8 / LiveView 1.2 application written in Elixir, backed by SQLite through ecto_sqlite3 and SQLean. Oban Lite owns background work. The application wraps yt-dlp and integrates ffmpeg, Apprise, and user scripts. This is a detached, community-maintained fork whose schema divergence from upstream must remain deliberate and reversible.

## Review by subsystem

- **Background jobs:** follow the full lifecycle from enqueue through execution and completion. Check retries, uniqueness/idempotency, concurrency, stale work, error reporting, and whether job arguments remain compatible with persisted jobs.
- **yt-dlp integration:** trace argument construction, process invocation, stdout/stderr parsing, exit status, timeouts, and failure handling. Treat media metadata and user-controlled script inputs as untrusted. Avoid shell interpretation and preserve useful diagnostics without leaking credentials.
- **Indexing:** preserve the documented fast-versus-slow distinction. Verify that a change does not turn routine refreshes into expensive scans or cause stale records to survive indefinitely. Check pagination, cancellation, and partial-failure behavior.
- **Domain model and SQLite:** follow schema changes through Ecto changesets, query behavior, constraints, and migrations. Do not assume PostgreSQL features or semantics. Preserve existing user data and account for the SQLite/SQLean deployment.
- **Boot/configuration:** check ordering and failure behavior when optional integrations or configuration are absent. Avoid making the whole application unavailable for an optional subsystem.
- **Web layer:** trace authorization, validation, LiveView or controller state, and the corresponding domain operation. Check for N+1 queries and unintended expensive work on interactive requests.

## Architecture workflow

1. Read CODEBASE.md and the relevant companion documentation for the changed subsystem. Do not load unrelated docs wholesale.
2. Follow the change across the owning context, schema, worker, and web boundary where applicable; review the end-to-end behavior, not just the edited function.
3. Check that the PR preserves the existing detached-fork boundary and does not silently pull in upstream schema or behavior changes.
4. Require tests for normal behavior and meaningful failure paths. Report validation that could not be run as unknown, not as a pass.
