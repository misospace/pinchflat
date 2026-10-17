#!/usr/bin/env bash
# Regression suite for tooling/pr_identity_resolver.sh (issue #143) — the
# trusted-PR-identity resolver that gates the privileged pr-image-publish
# workflow. Run directly; exits 0 only when every case passes.
# Bash + coreutils + jq only: `gh` is stubbed through a PATH-prepended
# directory that serves recorded fixtures, so the suite needs no network, no
# token, and no real API.
set -uo pipefail

RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr_identity_resolver.sh"

# Fail closed on a missing dependency rather than skipping: a suite that passes
# silently without running its cases is worse than no suite in CI.
if ! command -v jq > /dev/null 2>&1; then
  echo "test_pr_identity_resolver: jq is required but not on PATH" >&2
  exit 1
fi

# Trusted run/PR data the cases resolve against.
REPOSITORY='misospace/pinchflat'
HEAD_REPO='contributor/pinchflat'
HEAD_OWNER='contributor'
HEAD_BRANCH='fix-thing'
RUN_HEAD_SHA='abc1234567890abcdef1234567890abcdef12345'
OTHER_SHA='0123456789abcdef0123456789abcdef01234567'
UPPER_SHA='ABC1234567890ABCDEF1234567890ABCDEF12345'
PR=42

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

# --- gh stub -----------------------------------------------------------------

# A gh that records its argv and answers only the two API calls the resolver is
# allowed to make, from recorded fixtures. Anything else — and any fixture that
# was not set up for the case — exits 1, so a case cannot pass by making a call
# the resolver should never make.
write_gh_stub() {
  cat > "$CASE_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

fixture_dir=${GH_FIXTURE_DIR:?GH_FIXTURE_DIR must be set}
mkdir -p "$fixture_dir"

# One shell-quoted argv per line, so cases can assert what was called and how.
line=''
for arg in "$@"; do
  line+=" $(printf '%q' "$arg")"
done
printf '%s\n' "${line# }" >> "$fixture_dir/calls.log"

number=''
search=''
for arg in "$@"; do
  case "$arg" in
    repos/*/pulls/[0-9]*) number=${arg##*/} ;;
    repos/*/pulls) search=1 ;;
  esac
done

if [[ -n "$number" ]]; then
  file="$fixture_dir/pr_${number}.json"
elif [[ -n "$search" ]]; then
  file="$fixture_dir/pull_search.json"
else
  echo "gh stub: unexpected invocation: ${line# }" >&2
  exit 1
fi

if [[ ! -f "$file" ]]; then
  echo "gh stub: no fixture recorded for ${file##*/}" >&2
  exit 1
fi
cat "$file"
STUB
  chmod +x "$CASE_DIR/bin/gh"
}

# --- fixtures ----------------------------------------------------------------

# write_pr <number> <state> <head_repo_full_name> <head_sha>
write_pr() {
  cat > "$CASE_DIR/fixtures/pr_$1.json" <<JSON
{
  "number": $1,
  "state": "$2",
  "head": {
    "sha": "$4",
    "repo": { "full_name": "$3" }
  }
}
JSON
}

# pr_json <number> <state> <head_repo_full_name> <head_sha> — one PR object, for
# composing search fixtures.
pr_json() {
  printf '{"number":%s,"state":"%s","head":{"sha":"%s","repo":{"full_name":"%s"}}}' \
    "$1" "$2" "$4" "$3"
}

# write_search <json> — the --paginate --slurp shape: an array of pages, each
# page an array of PR objects.
write_search() {
  printf '%s\n' "$1" > "$CASE_DIR/fixtures/pull_search.json"
}

# --- harness -----------------------------------------------------------------

CASE_DIR=''
CASE_REPOSITORY=''
CASE_ASSOCIATIONS=''
CASE_HEAD_REPO=''
CASE_HEAD_OWNER=''
CASE_HEAD_BRANCH=''
CASE_RUN_HEAD_SHA=''
# file | empty | unset — how GITHUB_OUTPUT is passed to the resolver.
CASE_OUTPUT_MODE='file'
# Space-separated variable names to unset / empty before the run.
CASE_MISSING=''
CASE_EMPTY=''

new_case() {
  CASE_DIR=$(mktemp -d)
  tmp_dirs+=("$CASE_DIR")
  mkdir -p "$CASE_DIR/fixtures" "$CASE_DIR/bin"
  : > "$CASE_DIR/output"
  write_gh_stub
  # Baseline: a fork run — no associations, so the resolver must search.
  CASE_REPOSITORY=$REPOSITORY
  CASE_ASSOCIATIONS='[]'
  CASE_HEAD_REPO=$HEAD_REPO
  CASE_HEAD_OWNER=$HEAD_OWNER
  CASE_HEAD_BRANCH=$HEAD_BRANCH
  CASE_RUN_HEAD_SHA=$RUN_HEAD_SHA
  CASE_OUTPUT_MODE='file'
  CASE_MISSING=''
  CASE_EMPTY=''
}

# invoke [args...] — run the resolver with cwd = case dir, so any injection
# marker file would land there, and with the gh stub first on PATH. Records the
# exit status and captures stdout and stderr separately so refusals can be
# matched on their message.
invoke() {
  local dir=$CASE_DIR
  (
    cd "$dir"
    export PATH="$dir/bin:$PATH"
    export GH_FIXTURE_DIR="$dir/fixtures"
    export GH_TOKEN='stub-token'
    export REPOSITORY="$CASE_REPOSITORY"
    export PR_ASSOCIATIONS="$CASE_ASSOCIATIONS"
    export HEAD_REPO="$CASE_HEAD_REPO"
    export HEAD_OWNER="$CASE_HEAD_OWNER"
    export HEAD_BRANCH="$CASE_HEAD_BRANCH"
    export RUN_HEAD_SHA="$CASE_RUN_HEAD_SHA"
    case "$CASE_OUTPUT_MODE" in
      file) export GITHUB_OUTPUT="$dir/output" ;;
      empty) export GITHUB_OUTPUT='' ;;
      unset) unset GITHUB_OUTPUT ;;
    esac
    for name in $CASE_EMPTY; do export "$name="; done
    for name in $CASE_MISSING; do unset "$name"; done
    bash "$RESOLVER" "$@"
  ) > "$dir/out" 2> "$dir/err"
  LAST_STATUS=$?
}

has_no_markers() {
  local markers
  shopt -s nullglob
  markers=("$CASE_DIR"/PWNED*)
  shopt -u nullglob
  [[ ${#markers[@]} -eq 0 ]]
}

# Nothing may reach the output on any refusal: the file when there is one, the
# captured stdout when the resolver fell back to it — and stdout must stay free
# of output lines either way, so a resolver that wrote there instead of refusing
# silently cannot pass as a clean refusal.
output_empty() {
  if [[ "$CASE_OUTPUT_MODE" == 'file' ]]; then
    [[ ! -s "$CASE_DIR/output" ]] && ! grep -q -e '^pr=' -e '^sha=' "$CASE_DIR/out"
  else
    ! grep -q -e '^pr=' -e '^sha=' "$CASE_DIR/out"
  fi
}

no_gh_call() {
  [[ ! -s "$CASE_DIR/fixtures/calls.log" ]]
}

no_search_call() {
  local log=$CASE_DIR/fixtures/calls.log
  [[ ! -f "$log" ]] || ! grep -F -q -- "repos/${REPOSITORY}/pulls -f state=open" "$log"
}

# The fork fallback must ask GitHub for exactly the run's head branch, paginated,
# and open only — no looser query may stand in for it.
search_was_pinned() {
  local log=$CASE_DIR/fixtures/calls.log
  [[ -f "$log" ]] \
    && grep -F -q -- "repos/${REPOSITORY}/pulls -f state=open" "$log" \
    && grep -F -q -- '--paginate --slurp' "$log" \
    && grep -F -q -- '-f per_page=100' "$log" \
    && grep -F -q -- "-f head=${HEAD_OWNER}:${HEAD_BRANCH}" "$log"
}


fetched_only_pr() {
  local log=$CASE_DIR/fixtures/calls.log
  grep -F -q -- "repos/${REPOSITORY}/pulls/${PR}" "$log" \
    && ! grep -F -q -- 'pulls/9' "$log"
}


# expect_accept <desc> <pr> <sha> [predicate]
expect_accept() {
  local desc=$1 pr=$2 sha=$3
  local predicate=${4:-:}
  printf 'pr=%s\nsha=%s\n' "$pr" "$sha" > "$CASE_DIR/expected"
  if [[ "$LAST_STATUS" -eq 0 ]] && cmp -s "$CASE_DIR/output" "$CASE_DIR/expected" \
    && $predicate; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

# Same, for the stdout fallback: both lines present, nothing else emitted.
expect_accept_stdout() {
  local desc=$1 pr=$2 sha=$3
  if [[ "$LAST_STATUS" -eq 0 ]] \
    && grep -Fxq "pr=${pr}" "$CASE_DIR/out" \
    && grep -Fxq "sha=${sha}" "$CASE_DIR/out" \
    && [[ "$(wc -l < "$CASE_DIR/out")" -eq 3 ]]; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

# expect_reject <desc> [predicate] [stderr substring] — a refusal must always be
# exit 1 with an empty output; the optional predicate and needle let a case
# pin the specific reason, so a silent logic regression cannot pass.
expect_reject() {
  local desc=$1
  local predicate=${2:-:}
  local needle=${3:-}
  local message_ok=true
  invoke
  if [[ -n "$needle" ]] && ! grep -F -q -- "$needle" "$CASE_DIR/err"; then
    message_ok=false
  fi
  if [[ "$LAST_STATUS" -eq 1 ]] && output_empty && $predicate \
    && [[ "$message_ok" == true ]]; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

# expect_reject_message <desc> <stderr substring>
expect_reject_message() {
  expect_reject "$1" : "$2"
}

# expect_reject_code2 <desc> [resolver args...]
expect_reject_code2() {
  local desc=$1
  shift
  invoke "$@"
  if [[ "$LAST_STATUS" -eq 2 ]] && output_empty; then
    report "$desc" ok
  else
    report "$desc" bad
  fi
}

# --- accept cases ------------------------------------------------------------

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
invoke
expect_accept "single association resolves the open PR at the run head SHA" 42 "$RUN_HEAD_SHA"

new_case
write_search "[[$(pr_json 42 open "$HEAD_REPO" "$RUN_HEAD_SHA")],[]]"
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
invoke
expect_accept "empty associations resolve through a head-pinned open PR search" 42 \
  "$RUN_HEAD_SHA" search_was_pinned

new_case
CASE_ASSOCIATIONS='[]'
other_repo_pr=$(pr_json 9 open 'contributor/other-repo' "$RUN_HEAD_SHA")
write_search "[[${other_repo_pr}],[$(pr_json 42 open "$HEAD_REPO" "$RUN_HEAD_SHA")]]"
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
invoke
expect_accept "same-named branch on another repo of the same owner cannot impersonate" 42 \
  "$RUN_HEAD_SHA" fetched_only_pr

new_case
CASE_HEAD_OWNER='$(touch PWNED_owner)'
write_search "[[$(pr_json 42 open "$HEAD_REPO" "$RUN_HEAD_SHA")]]"
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
invoke
expect_accept "injected head owner is accepted as data without executing it" 42 \
  "$RUN_HEAD_SHA" has_no_markers

# --- fork fallback refusals --------------------------------------------------

new_case
write_search "[[$(pr_json 9 open 'contributor/other-repo' "$RUN_HEAD_SHA")]]"
expect_reject_message "search with no PR from the run's head repo refused" 'found 0'

new_case
second_match=$(pr_json 43 open "$HEAD_REPO" "$RUN_HEAD_SHA")
write_search "[[$(pr_json 42 open "$HEAD_REPO" "$RUN_HEAD_SHA")],[${second_match}]]"
expect_reject_message "search matching two PRs from the head repo refused" 'found 2'

new_case
CASE_ASSOCIATIONS='[{"number":42},{"number":43}]'
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
expect_reject "two associations refused as ambiguous, with no search call" no_search_call \
  'ambiguous'

# --- PR data refusals --------------------------------------------------------

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
write_pr 42 closed "$HEAD_REPO" "$RUN_HEAD_SHA"
expect_reject_message "closed PR refused" 'PR #42 is not open (state: closed)'

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
write_pr 42 open 'someone-else/pinchflat' "$RUN_HEAD_SHA"
expect_reject_message "PR head repo mismatch refused" "does not match the run's head repo"

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
write_pr 42 open "$HEAD_REPO" "$OTHER_SHA"
expect_reject_message "PR head ahead of the run refused" 'a newer push supersedes this artifact'

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
write_pr 42 open "$HEAD_REPO" "$UPPER_SHA"
expect_reject_message "uppercase PR head SHA refused" 'head SHA is not 40 lowercase hex'

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
write_pr 42 open "$HEAD_REPO" "${RUN_HEAD_SHA:0:39}"
expect_reject_message "39-character PR head SHA refused" 'head SHA is not 40 lowercase hex'

# --- run head SHA refusals ---------------------------------------------------

new_case
CASE_RUN_HEAD_SHA=${RUN_HEAD_SHA:0:39}
expect_reject_message "39-character run head SHA refused" 'run head SHA is not 40 lowercase hex'

new_case
CASE_RUN_HEAD_SHA=$UPPER_SHA
expect_reject_message "uppercase run head SHA refused" 'run head SHA is not 40 lowercase hex'

new_case
CASE_RUN_HEAD_SHA="${RUN_HEAD_SHA}a"
expect_reject_message "41-character run head SHA refused" 'run head SHA is not 40 lowercase hex'

new_case
CASE_RUN_HEAD_SHA='$(touch PWNED_sha)'
expect_reject "injected run head SHA refused without executing it" has_no_markers

new_case
CASE_RUN_HEAD_SHA='not-a-sha'
expect_reject "malformed run head SHA refused before any gh call" no_gh_call

# --- untrusted PR number / malformed payload ---------------------------------

new_case
CASE_ASSOCIATIONS='[{"number":"4a"}]'
expect_reject_message "non-integer association number refused" 'not a plain integer'

new_case
CASE_ASSOCIATIONS='[{"number":null}]'
expect_reject_message "null association number refused" 'not a plain integer'

new_case
CASE_ASSOCIATIONS='[1]'
expect_reject_message "association that is not an object refused" \
  'the single PR association carries no readable number'

new_case
CASE_ASSOCIATIONS='not json at all'
expect_reject_message "unparseable PR associations refused" 'not parseable JSON'

new_case
CASE_ASSOCIATIONS='not json at all'
expect_reject "unparseable PR associations refused before any gh call" no_gh_call

new_case
CASE_ASSOCIATIONS='[{"number":42}] trailing garbage'
expect_reject_message "PR associations with trailing garbage refused" 'not parseable JSON'

# --- untrusted API responses -------------------------------------------------

new_case
printf '%s\n' 'not json at all' > "$CASE_DIR/fixtures/pull_search.json"
expect_reject_message "unparseable PR search response refused" \
  "open PR search for head ${HEAD_OWNER}:${HEAD_BRANCH} failed"

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
printf '%s\n' 'not json at all' > "$CASE_DIR/fixtures/pr_42.json"
expect_reject_message "unparseable PR response refused" 'state is not readable JSON'

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
printf '%s\n' '{"state":"open","head":"not-an-object"}' > "$CASE_DIR/fixtures/pr_42.json"
expect_reject_message "PR response without a head repo refused" \
  'head repo is not readable JSON'

new_case
CASE_ASSOCIATIONS='[{"number":43}]'
expect_reject_message "unreadable PR response refused" 'could not read PR #43'

# --- injection ---------------------------------------------------------------

new_case
CASE_HEAD_BRANCH='$(touch PWNED_branch)'
write_search '[[]]'
expect_reject "injected head branch refused without executing it" has_no_markers

new_case
CASE_HEAD_REPO='"; touch PWNED_repo; echo "'
write_search '[[]]'
expect_reject "injected head repo refused without executing it" has_no_markers

new_case
CASE_ASSOCIATIONS='[{"number":"$(touch PWNED_assoc)"}]'
expect_reject "injected association number refused without executing it" has_no_markers

# --- missing / empty required variables --------------------------------------

new_case
CASE_MISSING='REPOSITORY'
expect_reject_code2 "missing REPOSITORY exits 2"

new_case
CASE_MISSING='PR_ASSOCIATIONS'
expect_reject_code2 "missing PR_ASSOCIATIONS exits 2"

new_case
CASE_MISSING='HEAD_REPO'
expect_reject_code2 "missing HEAD_REPO exits 2"

new_case
CASE_MISSING='HEAD_OWNER'
expect_reject_code2 "missing HEAD_OWNER exits 2"

new_case
CASE_MISSING='HEAD_BRANCH'
expect_reject_code2 "missing HEAD_BRANCH exits 2"

new_case
CASE_MISSING='RUN_HEAD_SHA'
expect_reject_code2 "missing RUN_HEAD_SHA exits 2"

new_case
CASE_EMPTY='HEAD_BRANCH'
expect_reject_code2 "empty HEAD_BRANCH exits 2"

new_case
expect_reject_code2 "a positional argument is a usage error" extra

# --- GITHUB_OUTPUT fallback --------------------------------------------------

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
CASE_OUTPUT_MODE='unset'
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
invoke
expect_accept_stdout "unset GITHUB_OUTPUT writes the two lines to stdout" 42 "$RUN_HEAD_SHA"

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
CASE_OUTPUT_MODE='empty'
write_pr 42 open "$HEAD_REPO" "$RUN_HEAD_SHA"
invoke
expect_accept_stdout "empty GITHUB_OUTPUT writes the two lines to stdout" 42 "$RUN_HEAD_SHA"

new_case
CASE_ASSOCIATIONS='[{"number":42}]'
CASE_OUTPUT_MODE='unset'
write_pr 42 closed "$HEAD_REPO" "$RUN_HEAD_SHA"
expect_reject_message "refusal with unset GITHUB_OUTPUT writes nothing to stdout" 'is not open'

echo
echo "$passed passed, $failed failed"
if [[ "$failed" -eq 0 ]]; then
  exit 0
fi
exit 1