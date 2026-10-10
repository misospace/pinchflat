#!/usr/bin/env bash
# Regression suite for tooling/pr_image_metadata.sh (issue #139) — the
# pr-image artifact metadata validator that gates the privileged
# pr-image-publish workflow. Run directly; exits 0 only when every case
# passes. Coreutils + bash only.
set -uo pipefail

VALIDATOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr_image_metadata.sh"

TRUSTED_PR='42'
TRUSTED_SHA='abc1234567890abcdef1234567890abcdef12345'

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

new_case() {
  CASE_DIR=$(mktemp -d)
  tmp_dirs+=("$CASE_DIR")
  mkdir -p "$CASE_DIR/meta"
  : > "$CASE_DIR/output"
}

# invoke <dir> <validator args...> — run the validator from <dir> so any
# injection marker file would land there; records the exit status.
invoke() {
  local dir=$1
  shift
  (cd "$dir" && GITHUB_OUTPUT="$dir/output" bash "$VALIDATOR" "$@") > "$dir/log" 2>&1
  LAST_STATUS=$?
}

invoke_meta() {
  invoke "$CASE_DIR" "$CASE_DIR/meta" "${1:-$TRUSTED_PR}" "${2:-$TRUSTED_SHA}"
}

has_no_markers() {
  local markers
  shopt -s nullglob
  markers=("$CASE_DIR"/PWNED*)
  shopt -u nullglob
  [[ ${#markers[@]} -eq 0 ]]
}

expect_reject() {
  local desc=$1
  invoke_meta
  if [[ "$LAST_STATUS" -eq 1 && ! -s "$CASE_DIR/output" ]]; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

expect_reject_no_marker() {
  local desc=$1
  invoke_meta
  if [[ "$LAST_STATUS" -eq 1 && ! -s "$CASE_DIR/output" ]] && has_no_markers; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

expect_reject_trusted() {
  local desc=$1 pr=$2 sha=$3
  invoke "$CASE_DIR" "$CASE_DIR/meta" "$pr" "$sha"
  if [[ "$LAST_STATUS" -eq 1 && ! -s "$CASE_DIR/output" ]]; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

expect_accept() {
  local desc=$1 pr=$2 sha=$3
  printf 'pr=%s\nsha=%s\n' "$pr" "$sha" > "$CASE_DIR/expected"
  if [[ "$LAST_STATUS" -eq 0 ]] && cmp -s "$CASE_DIR/output" "$CASE_DIR/expected"; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

write_valid_meta() {
  printf '%s\n' "$TRUSTED_PR" > "$CASE_DIR/meta/pr"
  printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
}

# --- accept cases -----------------------------------------------------------

new_case
write_valid_meta
invoke_meta
expect_accept "valid metadata with trailing newlines accepted, exact output" 42 abc1234

new_case
printf '%s' 42 > "$CASE_DIR/meta/pr"
printf '%s' abc1234 > "$CASE_DIR/meta/sha"
invoke_meta
expect_accept "valid metadata without trailing newline accepted" 42 abc1234

# --- injection attempts -----------------------------------------------------

new_case
write_valid_meta
printf '%s' '$(touch PWNED)' > "$CASE_DIR/meta/sha"
expect_reject_no_marker "meta/sha command substitution rejected, no marker"

new_case
write_valid_meta
printf '%s' '`touch PWNED2`' > "$CASE_DIR/meta/sha"
expect_reject_no_marker "meta/sha backtick substitution rejected, no marker"

new_case
printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
printf '%s' '$(touch PWNED3)' > "$CASE_DIR/meta/pr"
expect_reject_no_marker "meta/pr command substitution rejected, no marker"

# --- malformed artifact metadata --------------------------------------------

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n%s\n' abc1234 second > "$CASE_DIR/meta/sha"
expect_reject "meta/sha multiline rejected"

new_case
printf '%s\n%s\n' 42 43 > "$CASE_DIR/meta/pr"
printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
expect_reject "meta/pr multiline rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n' ABC1234 > "$CASE_DIR/meta/sha"
expect_reject "uppercase meta/sha rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n' abc123 > "$CASE_DIR/meta/sha"
expect_reject "6-character meta/sha rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n' abc12345 > "$CASE_DIR/meta/sha"
expect_reject "8-character meta/sha rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n' abcdefg > "$CASE_DIR/meta/sha"
expect_reject "non-hex meta/sha rejected"

new_case
printf '%s\n' 43 > "$CASE_DIR/meta/pr"
printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
expect_reject "meta/pr mismatching trusted PR rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n' dead123 > "$CASE_DIR/meta/sha"
expect_reject "valid-hex meta/sha that is not a trusted prefix rejected"

new_case
write_valid_meta
rm "$CASE_DIR/meta/pr"
expect_reject "missing meta/pr rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
expect_reject "missing meta/sha rejected"

new_case
write_valid_meta
rm -rf "$CASE_DIR/meta"
expect_reject "missing meta directory rejected"

new_case
printf '' > "$CASE_DIR/meta/pr"
printf '' > "$CASE_DIR/meta/sha"
expect_reject "empty metadata files rejected"

new_case
printf '%s\n' ' 42' > "$CASE_DIR/meta/pr"
printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
expect_reject "leading-space meta/pr rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s ' abc1234 > "$CASE_DIR/meta/sha"
expect_reject "trailing-space meta/sha rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%s\n' '"abc1234"' > "$CASE_DIR/meta/sha"
expect_reject "double-quoted meta/sha rejected"

new_case
printf "%s\n" "'42'" > "$CASE_DIR/meta/pr"
printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
expect_reject "single-quoted meta/pr rejected"

new_case
printf '%s\r\n' abc1234 > "$CASE_DIR/meta/sha"
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
expect_reject "CRLF-terminated meta/sha rejected"

new_case
printf '%s\n' 42 > "$CASE_DIR/meta/pr"
printf '%05000d' 7 > "$CASE_DIR/meta/sha"
expect_reject "oversized meta/sha rejected before being read whole"

new_case
printf '%s\nsha=%s\n' 42 999 > "$CASE_DIR/meta/pr"
printf '%s\n' abc1234 > "$CASE_DIR/meta/sha"
expect_reject "meta/pr newline forging an extra output line rejected"

# --- invalid trusted inputs (with valid artifact metadata) -------------------

new_case
write_valid_meta
expect_reject_trusted "trusted pr '4a' rejected" '4a' "$TRUSTED_SHA"

new_case
write_valid_meta
expect_reject_trusted "trusted sha uppercase rejected" "$TRUSTED_PR" 'ABC1234567890ABCDEF1234567890ABCDEF12345'

new_case
write_valid_meta
expect_reject_trusted "trusted sha 39 characters rejected" "$TRUSTED_PR" "${TRUSTED_SHA:0:39}"

new_case
write_valid_meta
expect_reject_trusted "trusted sha 41 characters rejected" "$TRUSTED_PR" "${TRUSTED_SHA}a"

new_case
write_valid_meta
invoke "$CASE_DIR" "$CASE_DIR/meta" "$TRUSTED_PR" '$(touch PWNED4)'
if [[ "$LAST_STATUS" -eq 1 && ! -s "$CASE_DIR/output" ]] && has_no_markers; then
  report "trusted sha command substitution rejected, no marker" ok
else
  report "trusted sha command substitution rejected, no marker" bad
fi

# --- usage errors -------------------------------------------------------------

new_case
write_valid_meta
invoke "$CASE_DIR" "$CASE_DIR/meta" "$TRUSTED_PR"
if [[ "$LAST_STATUS" -eq 2 && ! -s "$CASE_DIR/output" ]]; then
  report "two arguments rejected with exit 2" ok
else
  report "two arguments rejected with exit 2" bad
fi

new_case
write_valid_meta
invoke "$CASE_DIR" "$CASE_DIR/meta" "$TRUSTED_PR" "$TRUSTED_SHA" extra
if [[ "$LAST_STATUS" -eq 2 && ! -s "$CASE_DIR/output" ]]; then
  report "four arguments rejected with exit 2" ok
else
  report "four arguments rejected with exit 2" bad
fi

echo
echo "$passed passed, $failed failed"
if [[ "$failed" -eq 0 ]]; then
  exit 0
fi
exit 1