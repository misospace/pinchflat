#!/usr/bin/env bash
# Validate pr-image artifact metadata against trusted GitHub run/PR data.
#
# The pr-image artifact (meta/pr + meta/sha) is produced by CI steps that a
# fork PR can edit, so its contents are attacker-controlled. They are read
# with cat and compared using anchored regexes and string equality only —
# never eval'd, sourced, executed, or interpolated into any command or script
# source (issue #139).
#
# Usage: pr_image_metadata.sh <meta_dir> <trusted_pr> <trusted_full_head_sha>
#
# On success appends exactly two lines, "pr=<value>" and "sha=<value>", to
# $GITHUB_OUTPUT (or stdout when unset) and exits 0. Any failure writes
# nothing to the output and exits 1 with a diagnostic on stderr.
set -euo pipefail

usage() {
  echo "Usage: pr_image_metadata.sh <meta_dir> <trusted_pr> <trusted_full_head_sha>" >&2
}

fail() {
  echo "pr_image_metadata: refusing: $*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

meta_dir=$1
trusted_pr=$2
trusted_sha=$3

[[ "$trusted_pr" =~ ^[0-9]+$ ]] || fail "trusted PR number is not a plain integer"
[[ "$trusted_sha" =~ ^[0-9a-f]{40}$ ]] || fail "trusted head SHA is not 40 lowercase hex characters"

pr_file="${meta_dir}/pr"
sha_file="${meta_dir}/sha"

[[ -f "$pr_file" ]] || fail "artifact metadata file not found: pr"
[[ -f "$sha_file" ]] || fail "artifact metadata file not found: sha"

# Cap the attacker-controlled files before reading them: valid values are at
# most 7 bytes, so anything near 4 KiB is a bogus or hostile payload and must
# not be slurped whole.
for file in "$pr_file" "$sha_file"; do
  [[ $(wc -c < "$file") -le 4096 ]] || fail "artifact metadata file exceeds 4096 bytes: ${file##*/}"
done

# Command substitution strips trailing newlines, so a trailing newline in the
# file is tolerated, while embedded newlines, padding, or anything else fail
# the anchored checks below.
pr_content=$(cat "$pr_file")
sha_content=$(cat "$sha_file")

[[ "$pr_content" =~ ^[0-9]+$ ]] || fail "artifact pr metadata is not a plain integer"
[[ "$sha_content" =~ ^[0-9a-f]{7}$ ]] || fail "artifact sha metadata is not exactly 7 lowercase hex characters"
[[ "$pr_content" == "$trusted_pr" ]] || fail "artifact pr metadata does not match the trusted PR number"
[[ "${trusted_sha:0:7}" == "$sha_content" ]] || fail "artifact sha metadata is not a prefix of the trusted head SHA"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'pr=%s\n' "$pr_content"
    printf 'sha=%s\n' "$sha_content"
  } >> "$GITHUB_OUTPUT"
else
  printf 'pr=%s\n' "$pr_content"
  printf 'sha=%s\n' "$sha_content"
fi
exit 0