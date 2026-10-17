#!/usr/bin/env bash
# Resolve the trusted PR identity — the PR number and head SHA that a
# workflow_run's pr-image artifact belongs to — for the privileged
# pr-image-publish workflow. Exits non-zero without writing anything to the
# output unless every check below passes.
#
# Trust model (issues #139 and #143): the publisher runs in the trusted
# base-repo context with a write-capable token, but the workflow_run payload
# fields this resolves from are fork-influenced: a fork author picks their own
# branch name (head_branch) and head_repository.* fields, and pull_requests
# associations are empty for fork runs. Those values reach this script only as
# environment variables, are never interpolated into script source, and every
# one is re-checked against GitHub's own PR data (fetched with the workflow's
# trusted GH_TOKEN) before anything is emitted. Output is written only after the
# final gate passes, so a refusal leaves the caller's step outputs empty and the
# publisher fails closed.
#
# Usage: no arguments; all input comes from the environment.
#   REPOSITORY      base repository, owner/name                        (required)
#   PR_ASSOCIATIONS JSON array of the run payload's pull_requests       (required)
#   HEAD_REPO       head repository full_name                         (required)
#   HEAD_OWNER      head repository owner login                       (required)
#   HEAD_BRANCH     head branch name                                  (required)
#   RUN_HEAD_SHA    the run's head commit SHA                         (required)
#   GITHUB_OUTPUT   step output file; stdout when unset or empty
#   GH_TOKEN        token passed through to gh
#
# Exit codes: 0 accepted, 1 refused (untrusted or mismatched input),
# 2 usage error (a required variable missing or empty, or an argument given).
set -euo pipefail

usage() {
  echo "Usage: pr_identity_resolver.sh (no arguments; input comes from the environment)" >&2
}

fail() {
  echo "pr_identity_resolver: refusing: $*" >&2
  exit 1
}

if [[ $# -ne 0 ]]; then
  usage
  exit 2
fi

# No optional argument, no default: a gate that runs without its input is a gate
# that cannot fail closed.
for name in REPOSITORY PR_ASSOCIATIONS HEAD_REPO HEAD_OWNER HEAD_BRANCH RUN_HEAD_SHA; do
  if [[ -z "${!name:-}" ]]; then
    echo "pr_identity_resolver: missing required environment variable: ${name}" >&2
    usage
    exit 2
  fi
done

# The run's own head SHA gates everything else, so check it first.
[[ "$RUN_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || fail "run head SHA is not 40 lowercase hex characters"

# A malformed payload must refuse, not abort with jq's own exit status.
assoc_count=$(jq 'length' <<< "$PR_ASSOCIATIONS" 2> /dev/null) \
  || fail "PR associations are not parseable JSON"
[[ "$assoc_count" =~ ^[0-9]+$ ]] \
  || fail "PR associations did not resolve to a JSON array length"

if [[ "$assoc_count" -eq 1 ]]; then
  pr=$(jq -r '.[0].number' <<< "$PR_ASSOCIATIONS" 2> /dev/null) \
    || fail "the single PR association carries no readable number"
elif [[ "$assoc_count" -gt 1 ]]; then
  fail "workflow run is associated with ${assoc_count} pull requests; ambiguous"
else
  # Fork runs have empty workflow_run.pull_requests associations, so fall back to
  # the PR search API. The head filter matches owner:branch across ALL of that
  # owner's repos, so the jq select pins the exact head repo. Paginated in case
  # the owner has more open PRs for the branch than one page. --method GET is
  # required: adding any -f parameter flips gh's default method to POST, and
  # POST repos/{owner}/{repo}/pulls is the create-PR endpoint, not a search.
  candidates=$(gh api --paginate --slurp --method GET "repos/${REPOSITORY}/pulls" \
    -f state=open -f per_page=100 -f "head=${HEAD_OWNER}:${HEAD_BRANCH}" \
    | jq --arg repo "$HEAD_REPO" '[.[][] | select(.head.repo.full_name == $repo)]') \
    || fail "open PR search for head ${HEAD_OWNER}:${HEAD_BRANCH} failed"
  match_count=$(jq 'length' <<< "$candidates" 2> /dev/null) \
    || fail "open PR search returned unparseable JSON"
  # Guarded so the -ne comparison below can never fall through on a non-number.
  [[ "$match_count" =~ ^[0-9]+$ ]] \
    || fail "open PR search match count is not an integer"
  if [[ "$match_count" -ne 1 ]]; then
    fail "expected exactly one open PR for head ${HEAD_OWNER}:${HEAD_BRANCH} in ${HEAD_REPO}, \
found ${match_count}"
  fi
  pr=$(jq -r '.[0].number' <<< "$candidates" 2> /dev/null) \
    || fail "the matched open PR carries no readable number"
fi

# The association and search payloads are fork-influenced, so the resolved
# number is only ever used as a validated integer path segment.
[[ "$pr" =~ ^[0-9]+$ ]] || fail "resolved PR number is not a plain integer"

pr_data=$(gh api "repos/${REPOSITORY}/pulls/${pr}") || fail "could not read PR #${pr}"
state=$(jq -r '.state' <<< "$pr_data") || fail "PR #${pr} state is not readable JSON"
head_repo=$(jq -r '.head.repo.full_name' <<< "$pr_data") \
  || fail "PR #${pr} head repo is not readable JSON"
head_sha=$(jq -r '.head.sha' <<< "$pr_data") || fail "PR #${pr} head SHA is not readable JSON"

[[ "$state" == "open" ]] || fail "PR #${pr} is not open (state: ${state})"
[[ "$head_repo" == "$HEAD_REPO" ]] \
  || fail "PR #${pr} head repo ${head_repo} does not match the run's head repo ${HEAD_REPO}"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail "PR #${pr} head SHA is not 40 lowercase hex characters"
# The PR must not have advanced past this run; otherwise a stale artifact could
# be published and commented as the current head. (For pull_request runs the
# run's head_sha is the PR head commit, verified against this repo's own run
# data.)
[[ "$head_sha" == "$RUN_HEAD_SHA" ]] \
  || fail "PR #${pr} head ${head_sha} is not the run's head ${RUN_HEAD_SHA}; \
a newer push supersedes this artifact"

# Every gate passed; only now may anything be written to the caller's output.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "pr=${pr}"
    echo "sha=${head_sha}"
  } >> "$GITHUB_OUTPUT"
else
  echo "pr=${pr}"
  echo "sha=${head_sha}"
fi
echo "Trusted PR #${pr} at head ${head_sha}"