#!/usr/bin/env bash
# Validation entry point behind `mise run check` and `mise run test`.
#
# Preferred path (authoritative): the pinned ci-base image - the same image
# CI runs. tooling/lint_test.sh runs the full `mix check` gate (compiler,
# formatter, hex/mix audit, sobelow, prettier, `mix test --cover`);
# tooling/test.sh is the fast `mix test` loop. Both need a Docker daemon
# and a one-time `docker login ghcr.io` (the image is private).
#
# Fallback path: sandboxes with no usable Docker daemon (no host Docker
# socket, e.g. automation workers). The native toolchain installed by
# `mise run bootstrap` runs the SAME mix commands CI runs, with the same
# pinned Elixir/OTP/Node versions and the same pinned SQLean extensions. It
# cannot provide the ci-base image's yt-dlp/ffmpeg/Deno/Apprise binaries -
# the suite mocks yt-dlp and apprise (config/test.exs), so suite results
# still match CI.
#
# Usage: tooling/validate.sh <check|test> [args...]
#   check  -> tooling/lint_test.sh (Docker) or `mix check --no-fix --no-retry`
#   test   -> tooling/test.sh (Docker) or `mix test`; extra args pass through
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
  echo "usage: $0 <check|test> [args...]" >&2
  exit 2
fi
shift

case "${MODE}" in
  check | test) ;;
  *)
    echo "ERROR: unknown mode '${MODE}' (expected 'check' or 'test')" >&2
    exit 2
    ;;
esac

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is not on PATH." >&2
    echo "       Run 'mise run bootstrap' first - it installs the locked toolchain (Elixir, OTP, Node, yarn) and the pinned SQLean extensions." >&2
    exit 1
  fi
}

# A Docker CLI without a usable daemon (no host socket) must not block the
# sandbox, and it must not silently pretend the authoritative path ran.
# Probe the daemon once and say which path is taken.
docker_usable() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}

if docker_usable; then
  case "${MODE}" in
    check) exec tooling/lint_test.sh "$@" ;;
    test) exec tooling/test.sh "$@" ;;
  esac
fi

echo "==> No usable Docker daemon: running the native toolchain (same mix commands CI runs, no container)"
require_tool mix
if [[ "${MODE}" == "check" ]]; then
  require_tool yarn
fi

# The suite's fixtures hardcode /tmp/test/... paths and CI runs with the
# platform default temp dir. Sandboxes that override TMPDIR/TMP/TEMP
# (automation workers do) would otherwise compile the test config against a
# different root than the fixtures expect, so pin the same temp dir CI
# uses. The suite removes its own scratch dirs on exit.
if [[ "${TMPDIR:-/tmp}" != "/tmp" ]]; then
  echo "==> Pinning TMPDIR/TMP/TEMP to /tmp (CI parity: the suite's fixtures hardcode /tmp/test/... paths)"
fi
export TMPDIR=/tmp
export TMP=/tmp
export TEMP=/tmp

echo "==> Installing Elixir and JS deps"
mix local.hex --force >/dev/null
mix local.rebar --force >/dev/null
mix deps.get
if [[ "${MODE}" == "check" ]]; then
  yarn install
  (cd assets && yarn install)
fi

echo "==> Fetching SQLean extensions"
./tooling/fetch-sqlean.sh

case "${MODE}" in
  check)
    MIX_ENV=test mix ecto.create
    MIX_ENV=test mix ecto.migrate
    exec mix check --no-fix --no-retry "$@"
    ;;
  test)
    exec mix test "$@"
    ;;
esac
