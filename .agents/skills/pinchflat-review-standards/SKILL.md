---
name: pinchflat-review-standards
description: Apply Pinchflat's CI gates, Elixir/Phoenix conventions, test expectations, external-process boundaries, SQLite migration rules, reversible fork divergence, and security review requirements.
---

# Pinchflat review standards

## Blocking validation

The protected-branch CI gate runs the configured check suite, and external automation separately checks formatting, static analysis, compilation with warnings treated as failures, and the test suite. Do not call a change verified unless the relevant checks actually ran and passed. The test environment requires the repository's SQLean setup step before tests on a fresh checkout.

Every behavior change needs a test. Use the repository's database-aware and web-aware test cases for their respective boundaries, keep SQLite-backed tests serialized where required, use the established fixture factories, and mock external integrations through the existing Mox behaviors rather than relying on live services. Tests must not assume a fixed checkout path.

## Elixir and Phoenix conventions

- Keep domain code in its owning context directory. Put substantial query pipelines in the established query modules rather than controllers or LiveViews.
- Schema changesets must use the explicit allowed-field list. A newly added column omitted from that list may appear in the database but remain unwritable through the application.
- Background workers must preserve the repository's task-linkage and deduplication path; do not bypass the established task creation helper with an ad hoc enqueue.
- Worker queue names must match the configured queues. A typo can leave a job permanently unprocessed.
- Keep LiveViews with their resource/controller area and use verified routes rather than hand-built paths.
- Follow the repository's formatter and Credo configuration. Avoid new TODO/FIXME markers, debug leftovers, missing module docs, deep nesting, and compiler warnings. Tooling configuration files outside the formatter's declared inputs should not be reformatted as ordinary Elixir source.

## External-process boundary

External integrations such as yt-dlp, Apprise, HTTP clients, and user scripts must go through the existing behavior interfaces and runtime-selected implementations. Do not add a new direct process-launch path or construct command text from user-controlled values.

- Resolve the yt-dlp runner at runtime through `Application.get_env(:pinchflat, :yt_dlp_runner)`; never use a compile-time module reference (`lib/pinchflat/yt_dlp/media.ex`).
- Invoke commands through `Pinchflat.Utils.CliUtils.wrap_cmd/4`. It wraps `System.cmd/3` in `priv/cmd_wrapper.sh` so the child process dies when stdin closes (job cancellation). Build argv with `Pinchflat.Utils.CliUtils.parse_options/1`; never build a shell string.
- Only four modules may call `System.cmd/3` directly: `lib/pinchflat/utils/cli_utils.ex`, `lib/pinchflat/yt_dlp/command_runner.ex`, `lib/pinchflat/lifecycle/notifications/command_runner.ex`, and `lib/pinchflat/lifecycle/user_scripts/command_runner.ex`. Any fifth call site is a review flag.

Review stdout/stderr parsing, exit status, timeout/cancellation, failure reporting, and credential redaction. Add tests around the boundary, not only the happy-path caller.

## SQLite and migrations

- This project uses SQLite. Do not introduce PostgreSQL-only column types, alteration syntax, array types, JSONB, unsupported index syntax, or database-specific cascade assumptions.
- Keep migrations in the repository's migration style and ensure new columns are added to the corresponding schema's allowed-field list.
- A fork-only schema addition must preserve the reversible-upstream contract. Update the migration, the release module's fork-only column inventory, its migration-version inventory, the matching literal drop clause, and coverage together. A partial update can leave a database unable to return to the upstream schema.
- Treat data preservation and migration ordering as correctness requirements, not cleanup details.

## Security and fork discipline

- Trace untrusted media metadata, filenames, user scripts, and external responses through validation and execution boundaries.
- Avoid logging secrets or returning sensitive process output to clients.
- Preserve the deliberate divergence from upstream and its reversibility; do not copy upstream schema or behavior changes without checking the fork's compatibility contract.
- Report concrete exploit or data-loss paths with the changed location and evidence. Do not turn speculative hardening preferences into blockers.

## Review decisions and known exceptions

### Flag

- Any new compiler warning, formatting failure, static-analysis regression, or behavior change without a test.
- Debugging leftovers, missing module documentation, newly introduced TODO/FIXME markers, or line lengths that violate the configured limit.
- A worker that bypasses the established task-linkage/deduplication path or names a queue that is not configured.
- A new direct process-launch path outside the repository's sanctioned boundary, or command construction that interpolates untrusted values.
- Tests that assume a fixed checkout directory, run SQLite-backed cases concurrently, or skip the required extension setup.
- A fork-only schema addition that omits any part of the reversible-upstream inventory, a migration using unsupported database-specific syntax, or a new security-analysis suppression.
- Regression of the documented indexing behavior, treating the special yt-dlp unavailable-media status as success, or behavior changes without accompanying documentation updates.

### Approve

- Changes localized to the owning context with matching tests.
- New external integrations that use a behavior interface, runtime configuration, and a test mock.
- Additive, SQLite-safe migrations that preserve the reversible-fork contract.
- Tests using the existing fixture factories and metadata helpers.
- Conventional, user-facing commit subjects and documentation updated alongside behavior.

### Skip

- Dependency-only Renovate bumps limited to lockfiles, the pinned SQLean version, or action SHAs.
- Release-please PRs that only update generated release metadata and changelog files.
- The generated ERD image when it is not part of a behavioral change.
- Documentation-only PRs after checking required formatting.

### Known stale artifact

The legacy version-bump script and task still emit a date-shaped version; release-please and version.txt are the current versioning path. Flag this only when a PR touches that area, and do not file a drive-by cleanup.
