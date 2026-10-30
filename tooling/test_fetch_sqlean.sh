#!/usr/bin/env bash
# Regression suite for tooling/fetch-sqlean.sh (issue #165 review) — the pinned
# SQLean fetcher shared by `mix setup`, the Docker builder, CI and the
# `mise run bootstrap` contract. CI only exercises the curl+unzip path with
# the real release assets; this suite covers what CI otherwise would not: the
# mise-http fallback used by rootless sandboxes (no curl/unzip), the ambient
# locked-mode escape, the staging swap that keeps a failed fetch from
# destroying a working installation, and the expected failure modes.
#
# The script under test is a copy in a scratch tree, invoked with a PATH
# containing ONLY the shim directory (symlinks to the coreutils it needs plus
# fake curl / unzip / mise), so "absent" really means absent regardless of
# the host. For the happy-path cases the copy's pinned digests are rewritten
# to the sha256 of a local fixture zip so the REAL verification logic runs
# end to end (the upstream 0.22.0 assets cannot be fetched offline); the
# mismatch cases keep the pinned digests and prove they are enforced.
# Exits 0 only when every case passes. Needs GNU coreutils (`env -i`,
# `sha256sum`, GNU `sed`), like the ci-base container it mirrors: Linux dev
# boxes and CI, not macOS.
set -uo pipefail

FETCH_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetch-sqlean.sh"
SQLEAN_VERSION="$(sed -n 's/^SQLEAN_VERSION="\(.*\)"/\1/p' "$FETCH_SRC")"
REAL_CP="$(command -v cp)"

# sha_of_asset <asset> — the digest the script pins for that asset in ARCHES.
# Expectations derive from here so a Renovate version bump (which updates the
# table in the same commit) does not require editing this suite too.
sha_of_asset() {
  sed -n "s/.*${1}:\([0-9a-f]\{64\}\).*/\1/p" "$FETCH_SRC" | head -1
}

passed=0
failed=0
tmp_dirs=()

cleanup() {
  local dir
  for dir in ${tmp_dirs[@]+"${tmp_dirs[@]}"}; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

report() {
  if [[ "$2" == "ok" ]]; then
    passed=$((passed + 1))
    echo "ok - $1"
  else
    failed=$((failed + 1))
    echo "FAIL - $1"
  fi
}

# new_case builds:
#   $CASE/tooling/fetch-sqlean.sh  copy of the script under test
#   $CASE/payload/                 the files a successful unpack yields
#   $CASE/fixture.zip              the bytes a download "returns"
#   $CASE/bin                      the ONLY directory on the invoked PATH
#   $CASE/shim.log                 where the shims record invocations
# After new_case, BIN contains just the coreutils the script needs; each case
# adds the curl / unzip / mise shims it wants present.
new_case() {
  CASE=$(mktemp -d)
  tmp_dirs+=("$CASE")
  BIN="$CASE/bin"
  LOG="$CASE/shim.log"
  : >"$LOG"
  # Case-scoped env switches must not leak between cases: the shell keeps
  # `VAR=x func` assignments after the function returns.
  unset CASE_MISE_LOCKED CASE_MISE_INSTALL_DIR
  mkdir -p "$CASE/tooling" "$CASE/payload" "$BIN"
  cp "$FETCH_SRC" "$CASE/tooling/fetch-sqlean.sh"

  # A fake asset: arbitrary bytes whose digest the happy-path cases pin.
  head -c 512 /dev/urandom >"$CASE/fixture.zip"
  FIXTURE_SHA="$(sha256sum "$CASE/fixture.zip" | cut -d' ' -f1)"
  # What either release asset unpacks to: the entry point plus one satellite.
  printf 'fake sqlean %s\n' "$FIXTURE_SHA" >"$CASE/payload/sqlean.so"
  printf 'fake regexp\n' >"$CASE/payload/regexp_ext.so"

  # Coreutils the script invokes (find also needs cp via -exec; the shims
  # additionally use grep/sed).
  local util
  for util in bash env dirname sha256sum mktemp rm mkdir cp cat find cut grep sed; do
    ln -s "$(command -v "$util")" "$BIN/$util"
  done
}

# use_pinned_fixture_digests rewrites the copy's ARCHES digests to the local
# fixture's sha256 so the curl path's verification succeeds offline.
use_pinned_fixture_digests() {
  sed -i "s/[0-9a-f]\{64\}/${FIXTURE_SHA}/g" "$CASE/tooling/fetch-sqlean.sh"
}

install_curl_shim() {
  cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$SHIM_LOG"
# the script calls curl with -fsSL <url> -o <out>: the last argument is <out>
eval "out=\${$#}"
cp "$FIXTURE_ZIP" "$out"
EOF
  chmod +x "$BIN/curl"
}

install_unzip_shim() {
  cat >"$BIN/unzip" <<'EOF'
#!/usr/bin/env bash
echo "unzip $*" >>"$SHIM_LOG"
# unzip -qo <zip> -d <dir>
dest=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-d" ]]; then dest="$a"; fi
  prev="$a"
done
cp -R "$PAYLOAD_DIR/." "$dest/"
EOF
  chmod +x "$BIN/unzip"
}

# The mise shim emulates the http backend used by the rootless-sandbox path:
# `mise -C <dir> install` records the generated throwaway config and the tool
# key it installs; `mise -C <dir> where <ref>` resolves ONLY a previously
# installed tool, like real mise. That refusal is what guards the per-asset
# tool keying: a shared key would make the second architecture resolve the
# first one's files (see the comment in fetch_with_mise).
install_mise_shim() {
  cat >"$BIN/mise" <<'EOF'
#!/usr/bin/env bash
echo "mise $* | MISE_LOCKED=${MISE_LOCKED-<unset>}" >>"$SHIM_LOG"
work="" sub="" next_is=""
for a in "$@"; do
  if [[ "$next_is" == "-C" ]]; then work="$a"; next_is=""; continue; fi
  [[ "$a" == "-C" ]] && { next_is="-C"; continue; }
  [[ -z "$sub" && ( "$a" == "install" || "$a" == "where" ) ]] && sub="$a"
done
case "$sub" in
  install)
    if [[ -n "$work" && -f "$work/.mise/config.toml" ]]; then
      cat "$work/.mise/config.toml" >>"$MISE_CONFIG_CAPTURE"
      echo "---" >>"$MISE_CONFIG_CAPTURE"
      grep -o 'tools\."[^"]*"' "$work/.mise/config.toml" |
        sed 's/tools\."//; s/"$//' >>"$MISE_REGISTRY"
    fi
    ;;
  where)
    ref="" seen=""
    for a in "$@"; do
      if [[ "$seen" == 1 ]]; then ref="$a"; break; fi
      [[ "$a" == "where" ]] && seen=1
    done
    if ! grep -qxF -- "${ref%@*}" "$MISE_REGISTRY" 2>/dev/null; then
      echo "mise shim: not installed: ${ref}" >&2
      exit 1
    fi
    echo "$MISE_INSTALL_DIR"
    ;;
esac
exit 0
EOF
  chmod +x "$BIN/mise"
}

# install_cp_shim replaces the cp symlink with a pass-through that records
# invocations and fails only the final swap copy into
# priv/repo/extensions/<dir> — modelling a failure AFTER the entry-point
# check passed, so the case can assert the version marker is still not
# written (a marker written before that swap would masquerade a partial tree
# as a complete installation).
install_cp_shim() {
  rm -f "$BIN/cp"
  cat >"$BIN/cp" <<'EOF'
#!/usr/bin/env bash
echo "cp $*" >>"$SHIM_LOG"
for a in "$@"; do
  case "$a" in
    */priv/repo/extensions/*) exit 1 ;;
  esac
done
exec "$REAL_CP" "$@"
EOF
  chmod +x "$BIN/cp"
}

# invoke_fetch [args...] — runs the script with the curated PATH and the
# case's env; captures stdout/stderr/exit status.
invoke_fetch() {
  (
    cd "$CASE" &&
      env -i \
        PATH="$BIN" \
        SHIM_LOG="$LOG" \
        FIXTURE_ZIP="$CASE/fixture.zip" \
        PAYLOAD_DIR="$CASE/payload" \
        MISE_INSTALL_DIR="${CASE_MISE_INSTALL_DIR:-$CASE/payload}" \
        MISE_CONFIG_CAPTURE="$CASE/mise-configs.txt" \
        MISE_REGISTRY="$CASE/mise-registry.txt" \
        REAL_CP="$REAL_CP" \
        ${CASE_MISE_LOCKED:+MISE_LOCKED=1} \
        bash "$CASE/tooling/fetch-sqlean.sh" "$@" </dev/null
  ) >"$CASE/out" 2>"$CASE/err"
  STATUS=$?
}

status_is() { [[ "$STATUS" -eq "$1" ]]; }
out_has() { grep -qF -- "$1" "$CASE/out"; }
err_has() { grep -qF -- "$1" "$CASE/err"; }
log_has() { grep -qF -- "$1" "$LOG"; }
log_lacks() { ! grep -qF -- "$1" "$LOG"; }
configs_has() { grep -qF -- "$1" "$CASE/mise-configs.txt"; }
target() { printf '%s/priv/repo/extensions/%s' "$CASE" "$1"; }
marker_of() { cat "$(target "$1")/.sqlean-version" 2>/dev/null; }

# seed_install <dir> <version-marker> — a previously installed extension tree.
seed_install() {
  mkdir -p "$(target "$1")"
  printf 'previously installed %s\n' "$2" >"$(target "$1")/sqlean.so"
  printf '%s\n' "$2" >"$(target "$1")/.sqlean-version"
}

expect() {
  local desc=$1
  if eval "${2}"; then
    report "$desc" ok
  else
    report "$desc" bad
    echo "  --- stdout ---"
    sed 's/^/  /' "$CASE/out"
    echo "  --- stderr ---"
    sed 's/^/  /' "$CASE/err"
    echo "  --- shim log ---"
    sed 's/^/  /' "$LOG"
  fi
}

# --- curl+unzip path -------------------------------------------------------------

new_case
use_pinned_fixture_digests
install_curl_shim
install_unzip_shim
invoke_fetch
expect "curl path: digest-verified asset installed for both arches, marker written last" \
  'status_is 0 && out_has "sqlean ${SQLEAN_VERSION} ready" &&
   [[ "$(marker_of sqlean-linux-x86)" == "$SQLEAN_VERSION" &&
      "$(marker_of sqlean-linux-arm)" == "$SQLEAN_VERSION" ]] &&
   [[ -f "$(target sqlean-linux-x86)/sqlean.so" &&
      -f "$(target sqlean-linux-x86)/regexp_ext.so" &&
      -f "$(target sqlean-linux-arm)/sqlean.so" ]]'

new_case
install_curl_shim
install_unzip_shim
invoke_fetch
expect "curl path: asset not matching the pinned digest is rejected before unpack" \
  'status_is 1 && err_has "sha256 mismatch" && err_has "update the digests in ARCHES" &&
   log_lacks "unzip" && ! [[ -e "$(target sqlean-linux-x86)/sqlean.so" ]]'

new_case
install_curl_shim
install_unzip_shim
seed_install sqlean-linux-x86 0.21.0
seed_install sqlean-linux-arm 0.21.0
invoke_fetch
expect "curl path: a digest mismatch leaves the working install untouched" \
  'status_is 1 && err_has "sha256 mismatch" &&
   [[ "$(marker_of sqlean-linux-x86)" == "0.21.0" &&
      "$(marker_of sqlean-linux-arm)" == "0.21.0" &&
      "$(cat "$(target sqlean-linux-x86)/sqlean.so")" == "previously installed 0.21.0" ]]'

new_case
seed_install sqlean-linux-x86 "$SQLEAN_VERSION"
seed_install sqlean-linux-arm "$SQLEAN_VERSION"
invoke_fetch
expect "already-present pinned version: skips without fetching (no network shims exist)" \
  'status_is 0 && out_has "already present" && out_has "ready"'

new_case
use_pinned_fixture_digests
install_curl_shim
install_unzip_shim
seed_install sqlean-linux-x86 "$SQLEAN_VERSION"
seed_install sqlean-linux-arm "$SQLEAN_VERSION"
invoke_fetch --force
expect "--force re-fetches even when the marker matches" \
  'status_is 0 && log_has "curl" &&
   [[ "$(cat "$(target sqlean-linux-x86)/sqlean.so")" == "fake sqlean ${FIXTURE_SHA}" ]]'

# --- mise http-backend path --------------------------------------------------------

new_case
install_mise_shim
invoke_fetch
expect "no curl/unzip: mise http fallback installs both arches with per-asset tool keys" \
  'status_is 0 &&
   out_has "(fetching via mise: sqlean-linux-x86.zip)" &&
   out_has "(fetching via mise: sqlean-linux-arm64.zip)" &&
   log_has "where http:sqlean-sqlean-linux-x86.zip@${SQLEAN_VERSION}" &&
   log_has "where http:sqlean-sqlean-linux-arm64.zip@${SQLEAN_VERSION}" &&
   [[ -f "$(target sqlean-linux-x86)/sqlean.so" &&
      "$(marker_of sqlean-linux-arm)" == "$SQLEAN_VERSION" ]]'

new_case
install_mise_shim
CASE_MISE_LOCKED=1 invoke_fetch
expect "locked runner (MISE_LOCKED=1): the throwaway config is fetched unlocked" \
  'status_is 0 && log_has "MISE_LOCKED=<unset>" && log_lacks "MISE_LOCKED=1"'

new_case
install_mise_shim
invoke_fetch
expect "throwaway mise config is pinned: locked=false, format=zip, url, per-asset tool, sha256" \
  'status_is 0 &&
   configs_has "locked = false" &&
   configs_has "format = \"zip\"" &&
   configs_has "[tools.\"http:sqlean-sqlean-linux-x86.zip\"]" &&
   configs_has "[tools.\"http:sqlean-sqlean-linux-arm64.zip\"]" &&
   configs_has "checksum = \"sha256:$(sha_of_asset sqlean-linux-x86.zip)\"" &&
   configs_has "checksum = \"sha256:$(sha_of_asset sqlean-linux-arm64.zip)\"" &&
   configs_has "url = \"https://github.com/nalgeon/sqlean/releases/download/${SQLEAN_VERSION}/sqlean-linux-arm64.zip\""'

new_case
use_pinned_fixture_digests
install_curl_shim
install_unzip_shim
install_cp_shim
invoke_fetch
expect "a swap that fails after the entry-point check still leaves no version marker" \
  'status_is 1 &&
   [[ ! -f "$(target sqlean-linux-x86)/.sqlean-version" &&
      ! -f "$(target sqlean-linux-arm)/.sqlean-version" ]]'

new_case
install_mise_shim
# An asset that unpacks without the entry point: the swap must not happen.
mkdir -p "$CASE/no-entry"
printf 'not the extension\n' >"$CASE/no-entry/other.so"
seed_install sqlean-linux-x86 0.21.0
seed_install sqlean-linux-arm 0.21.0
CASE_MISE_INSTALL_DIR="$CASE/no-entry" invoke_fetch
expect "mise path: archive without sqlean.so fails loudly and keeps the working install" \
  'status_is 1 && err_has "did not provide sqlean.so" &&
   [[ "$(cat "$(target sqlean-linux-x86)/sqlean.so")" == "previously installed 0.21.0" &&
      "$(marker_of sqlean-linux-x86)" == "0.21.0" &&
      "$(marker_of sqlean-linux-arm)" == "0.21.0" ]]'

new_case
invoke_fetch
expect "neither curl+unzip nor mise: exit 1 with an actionable error" \
  'status_is 1 && err_has "neither curl+unzip nor mise" && err_has "mise run bootstrap"'

echo
echo "$passed passed, $failed failed"
if [[ "$failed" -eq 0 ]]; then
  exit 0
fi
exit 1
