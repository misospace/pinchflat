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

# Run the mix/yarn commands through mise when it is available, so the native
# path uses the LOCKED toolchain instead of whatever the host happens to
# have on PATH. `mise exec` also puts the toolchain's bin directories (and
# the contract's ELIXIR_ERL_OPTIONS) on PATH for the child process.
if command -v mise >/dev/null 2>&1; then
  toolchain() { mise exec -- "$@"; }
else
  echo "==> mise not found: falling back to the host toolchain"
  toolchain() { "$@"; }
  if ! command -v mix >/dev/null 2>&1; then
    echo "ERROR: mix is not on PATH and mise is not available." >&2
    echo "       Run 'mise run bootstrap' first - it installs the locked toolchain (Elixir, OTP, Node, yarn) and the pinned SQLean extensions." >&2
    exit 1
  fi
  if [[ "${MODE}" == "check" ]] && ! command -v yarn >/dev/null 2>&1; then
    echo "ERROR: yarn is not on PATH and mise is not available." >&2
    echo "       Run 'mise run bootstrap' first - it installs the locked toolchain." >&2
    exit 1
  fi
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

# Mirror the Docker wrappers' own flags on the native path: --clean drops the
# compiled artifacts (the Docker path drops its cached volumes), --shell
# drops into an interactive shell (the Docker path opens a shell in the
# container). Both are stripped from the arguments forwarded to mix.
CLEAN=0
SHELL_MODE=0
ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --clean)
      CLEAN=1
      ;;
    --shell)
      SHELL_MODE=1
      ;;
    *)
      ARGS+=("${arg}")
      ;;
  esac
done

if [[ "${SHELL_MODE}" == "1" ]]; then
  echo "==> Opening a shell with the locked toolchain"
  toolchain bash
  exit 0
fi

echo "==> Installing Elixir and JS deps"
toolchain mix local.hex --force >/dev/null
toolchain mix local.rebar --force >/dev/null
toolchain mix deps.get
if [[ "${MODE}" == "check" ]]; then
  toolchain yarn install
  (cd assets && toolchain yarn install)
fi

echo "==> Fetching SQLean extensions"
./tooling/fetch-sqlean.sh

if [[ "${CLEAN}" == "1" ]]; then
  echo "==> Dropping compiled artifacts (native equivalent of the Docker path's --clean)"
  toolchain mix clean
fi

case "${MODE}" in
  check)
    MIX_ENV=test toolchain mix ecto.create
    MIX_ENV=test toolchain mix ecto.migrate
    toolchain mix check --no-fix --no-retry "${ARGS[@]+"${ARGS[@]}"}"
    ;;
  test)
    toolchain mix test "${ARGS[@]+"${ARGS[@]}"}"
    ;;
esac
