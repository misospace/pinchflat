#!/usr/bin/env bash
# Downloads the SQLean SQLite extensions into priv/repo/extensions/ for both
# Linux architectures. These are loaded at runtime by config/runtime.exs (see
# the `load_extensions` config) and back the per-source title filter regex
# (regexp_like). They are NOT committed to git — this script fetches them for
# local dev/test (via `mix setup`) and for the Docker builder stage (before
# `mix release` bundles priv/ into the OTP release).
#
# Version is pinned and tracked by Renovate, and every downloaded zip is
# verified against a committed SHA-256 before it is unpacked (issue #172).
set -euo pipefail

# renovate: datasource=github-releases depName=nalgeon/sqlean
SQLEAN_VERSION="0.22.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="${SCRIPT_DIR}/../priv/repo/extensions"
BASE_URL="https://github.com/nalgeon/sqlean/releases/download/${SQLEAN_VERSION}"

# Triples of "<target dir>:<release asset>:<expected sha256>". The target dir
# name matches `sqlean-linux-#{arch}` in config/runtime.exs. (Avoid associative
# arrays so this runs on macOS's default bash 3.2.)
#
# The digests are the SHA-256 of each release zip. SQLean publishes no checksums
# with its releases, so these were captured from the pinned 0.22.0 assets
# (published 2024-03-13). When bumping SQLEAN_VERSION, fetch the new zips, take
# their sha256, and update this list in the same commit — the fetch below fails
# loudly on mismatch, including when the version was bumped but the digests
# were left stale.
ARCHES="sqlean-linux-x86:sqlean-linux-x86.zip:62c776a64f442e513a865adcf8b430254cdd80f6eca14d4df7d11c770f94eefd
  sqlean-linux-arm:sqlean-linux-arm64.zip:0a265a88c4808ad051539708ee6e4c7bbd032797c2a19d71a5bed835a667613b"

# GNU coreutils on Linux, the Perl wrapper on macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Skip the download when the pinned version is already present (idempotent —
# safe to call from `mix setup` repeatedly). Pass --force to re-fetch.
#
# "Present" means both the version marker AND the actual `sqlean.so` binary
# exist. The marker alone is not enough: it lives inside a gitignored dir, so a
# `docker COPY priv priv` (or a git clean that leaves the marker behind) can
# carry a stale marker into a build with no `.so` files next to it. Trusting the
# marker by itself made the fetch skip, shipping an image whose extension never
# loads — every SQLean function (gen_random_uuid, regexp_like, …) then silently
# goes missing and migrations that use them crash.
FORCE="${1:-}"
VERSION_MARKER=".sqlean-version"

for entry in ${ARCHES}; do
  IFS=: read -r dir asset sha <<<"${entry}"
  target="${EXT_DIR}/${dir}"
  if [[ "${FORCE}" != "--force" && -f "${target}/${VERSION_MARKER}" && -f "${target}/sqlean.so" ]] &&
    [[ "$(cat "${target}/${VERSION_MARKER}")" == "${SQLEAN_VERSION}" ]]; then
    echo "sqlean ${SQLEAN_VERSION} already present in ${dir}, skipping"
    continue
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  echo "Fetching sqlean ${SQLEAN_VERSION} (${asset}) -> ${dir}"
  curl -fsSL "${BASE_URL}/${asset}" -o "${tmp}/sqlean.zip"

  # Verify before unzipping: nothing from the release is unpacked into priv/
  # (and eventually into the OTP release) unless it matches the committed digest.
  actual="$(sha256_of "${tmp}/sqlean.zip")"
  if [[ "${actual}" != "${sha}" ]]; then
    echo "ERROR: sha256 mismatch for ${asset}" >&2
    echo "  expected: ${sha}" >&2
    echo "  actual:   ${actual}" >&2
    echo "If SQLEAN_VERSION was intentionally bumped to ${SQLEAN_VERSION}, update the digests in ARCHES." >&2
    exit 1
  fi

  rm -rf "${target}"
  mkdir -p "${target}"
  unzip -qo "${tmp}/sqlean.zip" -d "${target}"
  echo "${SQLEAN_VERSION}" >"${target}/${VERSION_MARKER}"

  rm -rf "${tmp}"
  trap - EXIT
done

echo "sqlean ${SQLEAN_VERSION} ready"
