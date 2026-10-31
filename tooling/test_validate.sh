#!/usr/bin/env bash
# Regression suite for tooling/validate.sh (issue #165) — the validation entry
# point behind `mise run check` / `mise run test`. CI's own job exercises the
# authoritative Docker path (tooling/lint_test.sh / tooling/test.sh), so this
# suite covers what CI otherwise would not: the routing decision (usable
# daemon -> wrapper, unusable/absent daemon -> native toolchain), the native
# command sequence, argument forwarding, and the expected failure modes.
#
# Runs entirely against a scratch repo tree (a copy of validate.sh with stub
# lint_test.sh / test.sh / fetch-sqlean.sh wrappers) and PATH shims for
# docker / mise / mix / yarn. The invoked script gets a PATH containing ONLY
# the shim directory, so "absent" really means absent regardless of what the
# host or CI runner happens to have installed. Exits 0 only when every case
# passes. Needs GNU coreutils (`env -i`), like the ci-base container it
# mirrors: Linux dev boxes and CI, not macOS.
set -uo pipefail

VALIDATE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate.sh"

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
#   $CASE/repo   scratch repo root (validate.sh + stub tooling/ + assets/)
#   $CASE/bin    the ONLY directory on the invoked PATH; fill with shims
#   $CASE/shim.log  where the shims record their invocations
new_case() {
  CASE=$(mktemp -d)
  tmp_dirs+=("$CASE")
  REPO="$CASE/repo"
  BIN="$CASE/bin"
  LOG="$CASE/shim.log"
  : >"$LOG"
  # Case-scoped env switches must not leak between cases: the shell keeps
  # `VAR=x func` assignments after the function returns.
  unset DOCKER_INFO_EXIT CASE_TMPDIR
  mkdir -p "$REPO/tooling" "$REPO/assets" "$BIN"
  cp "$VALIDATE_SRC" "$REPO/tooling/validate.sh"
  printf '#!/usr/bin/env bash\necho "LINT_TEST $*"\n' >"$REPO/tooling/lint_test.sh"
  printf '#!/usr/bin/env bash\necho "TEST $*"\n' >"$REPO/tooling/test.sh"
  printf '#!/usr/bin/env bash\necho "fetch_sqlean" >>"$SHIM_LOG"\necho FETCH_SQLEAN\n' >"$REPO/tooling/fetch-sqlean.sh"
  chmod +x "$REPO"/tooling/*.sh
  # The minimal set of real utilities the scripts need under the curated PATH.
  ln -s "$(command -v bash)" "$BIN/bash"
  ln -s /usr/bin/env "$BIN/env"
  ln -s "$(command -v dirname)" "$BIN/dirname"
}

# Shims record "<cmd> <args>" plus the env validate.sh must control, then
# succeed. The mise shim does NOT run its inner command: any mix/yarn call
# that bypassed `mise exec` shows up as a missing line, not as a hidden pass.
install_docker_shim() {
  cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$SHIM_LOG"
if [[ "${1:-}" == "info" ]]; then
  exit "${DOCKER_INFO_EXIT:-0}"
fi
exit 0
EOF
  chmod +x "$BIN/docker"
}

install_mise_shim() {
  cat >"$BIN/mise" <<'EOF'
#!/usr/bin/env bash
# PWD distinguishes the root yarn install from the assets/ install that
# validate.sh runs in a subshell — deleting either one is a behavior change.
echo "mise $* | TMPDIR=${TMPDIR:-} TMP=${TMP:-} TEMP=${TEMP:-} MIX_ENV=${MIX_ENV:-} PWD=${PWD:-}" >>"$SHIM_LOG"
exit 0
EOF
  chmod +x "$BIN/mise"
}

install_mix_shim() {
  cat >"$BIN/mix" <<'EOF'
#!/usr/bin/env bash
echo "mix $* | MIX_ENV=${MIX_ENV:-}" >>"$SHIM_LOG"
exit 0
EOF
  chmod +x "$BIN/mix"
}

install_yarn_shim() {
  cat >"$BIN/yarn" <<'EOF'
#!/usr/bin/env bash
echo "yarn $*" >>"$SHIM_LOG"
exit 0
EOF
  chmod +x "$BIN/yarn"
}

# invoke_validate <mode> [args...] — runs validate.sh from a neutral cwd with
# the curated PATH; captures stdout/stderr/exit status and the shim log.
invoke_validate() {
  (
    cd "$CASE" &&
      env -i \
        PATH="$BIN" \
        SHIM_LOG="$LOG" \
        HOME="$CASE/home" \
        DOCKER_INFO_EXIT="${DOCKER_INFO_EXIT:-0}" \
        TMPDIR="${CASE_TMPDIR:-/tmp}" \
        bash "$REPO/tooling/validate.sh" "$@" </dev/null
  ) >"$CASE/out" 2>"$CASE/err"
  STATUS=$?
}

status_is() { [[ "$STATUS" -eq "$1" ]]; }
out_has() { grep -qF -- "$1" "$CASE/out"; }
err_has() { grep -qF -- "$1" "$CASE/err"; }
log_has() { grep -qF -- "$1" "$LOG"; }
log_lacks() { ! grep -qF -- "$1" "$LOG"; }
out_lacks() { ! grep -qF -- "$1" "$CASE/out"; }
# log_order <first> <second> — first occurrence of each literal; both must
# exist and <first> must precede <second> (the sequence itself is behavior).
log_order() {
  local la lb
  la=$(grep -nF -- "$1" "$LOG" | head -1 | cut -d: -f1)
  lb=$(grep -nF -- "$2" "$LOG" | head -1 | cut -d: -f1)
  [[ -n "$la" && -n "$lb" && "$la" -lt "$lb" ]]
}
log_count() { [[ "$(grep -cF -- "$1" "$LOG")" -eq "$2" ]]; }

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

# --- usage and mode validation -------------------------------------------------

new_case
invoke_validate
expect "no mode: exit 2 with usage" 'status_is 2 && err_has "usage:"'

new_case
invoke_validate lint
expect "unknown mode: exit 2 naming the mode" 'status_is 2 && err_has "unknown mode" && err_has "lint"'

# --- Docker routing ------------------------------------------------------------

new_case
install_docker_shim
DOCKER_INFO_EXIT=0 invoke_validate check --stale
expect "usable daemon + check execs tooling/lint_test.sh with args" \
  'status_is 0 && out_has "LINT_TEST --stale" && out_lacks "No usable Docker daemon" && log_lacks "mix"'

new_case
install_docker_shim
DOCKER_INFO_EXIT=0 invoke_validate test test/foo_test.exs:42
expect "usable daemon + test execs tooling/test.sh with args" \
  'status_is 0 && out_has "TEST test/foo_test.exs:42" && log_lacks "mix"'

new_case
install_docker_shim
install_mise_shim
DOCKER_INFO_EXIT=1 invoke_validate test
expect "docker CLI with a dead daemon falls back to the native path" \
  'status_is 0 && out_has "No usable Docker daemon" && out_lacks "TEST" && log_has "mise exec -- mix test"'

new_case
install_mise_shim
invoke_validate check
expect "absent docker CLI falls back to the native path" \
  'status_is 0 && out_has "No usable Docker daemon" && out_lacks "LINT_TEST" && log_has "mise exec -- mix check --no-fix --no-retry"'

# --- native path: command sequence via mise --------------------------------------

new_case
install_mise_shim
invoke_validate test
expect "native test runs deps.get, SQLean fetch, then mix test through mise" \
  'status_is 0 &&
   log_has "mise exec -- mix local.hex --force" &&
   log_has "mise exec -- mix local.rebar --force" &&
   log_has "mise exec -- mix deps.get" &&
   out_has "FETCH_SQLEAN" &&
   log_order "mise exec -- mix deps.get" "fetch_sqlean" &&
   log_order "fetch_sqlean" "mise exec -- mix test" &&
   log_has "mise exec -- mix test" &&
   log_lacks "yarn install" &&
   log_lacks "ecto.create"'

new_case
install_mise_shim
invoke_validate check
expect "native check adds both yarn installs, test-env ecto, then mix check --no-fix --no-retry" \
  'status_is 0 &&
   [[ "$(grep -c "mise exec -- yarn install | .* PWD=$REPO$" "$LOG")" -eq 1 ]] &&
   log_has "mise exec -- yarn install | TMPDIR=/tmp TMP= TEMP= MIX_ENV= PWD=$REPO/assets" &&
   log_order "fetch_sqlean" "mise exec -- mix ecto.create" &&
   log_order "mise exec -- mix ecto.migrate" "mise exec -- mix check" &&
   log_has "mise exec -- mix ecto.create | TMPDIR=/tmp TMP= TEMP= MIX_ENV=test" &&
   log_has "mise exec -- mix ecto.migrate | TMPDIR=/tmp TMP= TEMP= MIX_ENV=test" &&
   log_has "mise exec -- mix check --no-fix --no-retry"'

new_case
install_mise_shim
invoke_validate test test/path/to/file_test.exs:42
expect "native test forwards extra args to mix test verbatim" \
  'status_is 0 && log_has "mise exec -- mix test test/path/to/file_test.exs:42"'

new_case
install_mise_shim
invoke_validate test --clean test/foo_test.exs
expect "--clean runs mix clean and is not forwarded to mix test" \
  'status_is 0 && log_has "mise exec -- mix clean" &&
   log_has "mise exec -- mix test test/foo_test.exs" &&
   log_lacks "mix test --clean"'

new_case
install_mise_shim
invoke_validate test --shell
expect "--shell opens the toolchain shell and runs nothing else" \
  'status_is 0 && out_has "Opening a shell" &&
   log_has "mise exec -- bash |" &&
   log_lacks "deps.get"'

# --- native path: environment control --------------------------------------------

new_case
install_mise_shim
CASE_TMPDIR="$CASE/sandbox-tmp" invoke_validate test
expect "TMPDIR passes through to the toolchain (the suite derives its fixture paths from config)" \
  'status_is 0 && out_lacks "Pinning TMPDIR" &&
   log_has "mise exec -- mix test | TMPDIR=$CASE/sandbox-tmp TMP= TEMP=" &&
   ! grep -q "TMPDIR=/tmp " "$LOG"'

# --- native path: toolchain resolution and failure modes ---------------------------

new_case
install_mix_shim
install_yarn_shim
invoke_validate check
expect "no mise: falls back to the host toolchain (mix/yarn used directly)" \
  'status_is 0 && out_has "mise not found" &&
   log_has "mix deps.get" &&
   log_has "yarn install" &&
   log_lacks "mise exec"'

new_case
invoke_validate test
expect "no mise and no mix: exit 1 pointing at mise run bootstrap" \
  'status_is 1 && err_has "mix is not on PATH" && err_has "mise run bootstrap"'

new_case
install_mix_shim
invoke_validate check
expect "no mise, no yarn, check mode: exit 1 pointing at mise run bootstrap" \
  'status_is 1 && err_has "yarn is not on PATH" && err_has "mise run bootstrap"'

echo
echo "$passed passed, $failed failed"
if [[ "$failed" -eq 0 ]]; then
  exit 0
fi
exit 1
