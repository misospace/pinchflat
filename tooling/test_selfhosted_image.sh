#!/usr/bin/env bash
# Regression suite for the selfhosted image executable-path/permission contract.
#
# Two modes:
#   Mode A (no Docker): asserts the contract statically against
#     docker/selfhosted.Dockerfile and then replays the Dockerfile's runtime
#     command in a temporary simulated root, running the in-image assertions
#     (tooling/selfhosted_image_checks.sh --root) against it.
#   Mode B (<image-ref>): runs tooling/selfhosted_image_checks.sh inside the
#     built image as root and as an unprivileged user, plus the non-downgrading
#     self-update checks. Requires Docker.
#
# The contract itself (the world-writable paths, the yt-dlp binary/symlink and
# the updater's network-failure messages) is owned by
# tooling/selfhosted_image_checks.sh and read from it with --print-contract, so
# both scripts assert the same values.
#
# Usage: bash tooling/test_selfhosted_image.sh [image-ref]
#
# Exits 0 only when nothing failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKS="$SCRIPT_DIR/selfhosted_image_checks.sh"
DOCKERFILE="$REPO_ROOT/docker/selfhosted.Dockerfile"

passed=0
failed=0
skipped=0

tmp_dirs=()

cleanup() {
  local dir
  for dir in "${tmp_dirs[@]+"${tmp_dirs[@]}"}"; do
    rm -rf "$dir" 2>/dev/null
  done
}
trap cleanup EXIT

report() {
  case "$2" in
    ok)
      passed=$((passed + 1))
      echo "ok - $1"
      ;;
    skip)
      skipped=$((skipped + 1))
      echo "skip - $1"
      ;;
    *)
      failed=$((failed + 1))
      echo "FAIL - $1"
      ;;
  esac
}

new_case() {
  CASE_DIR=$(mktemp -d)
  tmp_dirs+=("$CASE_DIR")
}

# --- the contract ---------------------------------------------------------------
#
# The checks script owns the contract; it is read from there instead of being
# copied here.

CHMOD_PATHS=()
ALLOWED_PATHS=()
NETWORK_MESSAGES=()
NETWORK_FAILURE_REGEX=''
YTDLP_BIN=''
YTDLP_LINK=''

# load_contract — read the contract from the checks script. Reports a failure
# and returns non-zero when the contract cannot be read.
load_contract() {
  local line key value contract

  if [[ ! -f "$CHECKS" ]]; then
    report "the image check contract can be read from $CHECKS" bad
    return 1
  fi

  contract=$(bash "$CHECKS" --print-contract 2>/dev/null)
  if [[ -z "$contract" ]]; then
    report "the image check contract can be read from $CHECKS (the contract is empty)" bad
    return 1
  fi

  CHMOD_PATHS=()
  ALLOWED_PATHS=()
  NETWORK_MESSAGES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      CHMOD_PATH) CHMOD_PATHS+=("$value") ;;
      ALLOWED_PATH) ALLOWED_PATHS+=("$value") ;;
      NETWORK_FAILURE) NETWORK_MESSAGES+=("$value") ;;
      YTDLP_BIN) YTDLP_BIN=$value ;;
      YTDLP_LINK) YTDLP_LINK=$value ;;
    esac
  done <<< "$contract"

  if [[ ${#CHMOD_PATHS[@]} -eq 0 || ${#ALLOWED_PATHS[@]} -eq 0 || ${#NETWORK_MESSAGES[@]} -eq 0 \
    || -z "$YTDLP_BIN" || -z "$YTDLP_LINK" ]]; then
    report "the image check contract can be read from $CHECKS (the contract is incomplete)" bad
    return 1
  fi

  NETWORK_FAILURE_REGEX=$(IFS='|'; printf '%s' "${NETWORK_MESSAGES[*]}")
  report "the image check contract can be read from $CHECKS" ok
  return 0
}

# network_failure_message <output> — the contract's network-failure message
# contained in <output>, if any. A checksum/signature failure is not a network
# failure and must never be reported as one.
network_failure_message() {
  local message
  for message in "${NETWORK_MESSAGES[@]}"; do
    if [[ "$1" == *"$message"* ]]; then
      printf '%s' "$message"
      return 0
    fi
  done
  return 1
}

# --- Dockerfile parsing --------------------------------------------------------

# join_continuations <file> — drop standalone comment lines, then join
# backslash-newline continuations the way the Docker parser does. A file whose
# last line ends with a backslash must not lose that line.
join_continuations() {
  sed -e '/^[[:space:]]*#/d' "$1" | awk '
    {
      line = $0
      while (sub(/\\$/, "", line)) {
        if ((getline next_line) <= 0) {
          break
        }
        line = line " " next_line
      }
      print line
    }'
}

# split_commands <joined-text> — one shell command per line.
split_commands() {
  printf '%s\n' "$1" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g'
}

# args_of <command> <tool> — the arguments a tool was called with, with any
# trailing comment removed.
args_of() {
  printf '%s\n' "$1" | sed -e "s/.*$2[[:space:]][[:space:]]*//" -e 's/[[:space:]]#.*$//' | tr -s ' ' '\n' | sed -e '/^$/d'
}

# --- Mode A: static contract + simulated image ---------------------------------

# build_simulated_root <dir> — replay the Dockerfile's runtime layout in <dir>.
build_simulated_root() {
  local fake=$1
  local allowed dir
  mkdir -p "$fake"
  for dir in "${mkdir_args[@]+"${mkdir_args[@]}"}"; do
    mkdir -p "${fake}${dir}"
  done
  mkdir -p "${fake}$(dirname "$YTDLP_LINK")" "${fake}$(dirname "$YTDLP_BIN")"
  printf 'stub\n' > "${fake}${YTDLP_BIN}"
  chmod 0755 "${fake}${YTDLP_BIN}"
  if [[ ${#ln_args[@]} -eq 2 ]]; then
    ln -s "${ln_args[0]}" "${fake}${ln_args[1]}"
  fi
  if [[ ${#chmod_args[@]} -gt 0 ]]; then
    chmod ugo+rw "${chmod_args[@]/#/$fake}"
  fi
  # The contract allows the sticky temp dirs on top of the self-update
  # surface; create them so the simulated root cannot drift from it.
  for allowed in "${ALLOWED_PATHS[@]}"; do
    if [[ ! -e "${fake}${allowed}" ]]; then
      mkdir -p "${fake}${allowed}"
      case "$allowed" in
        /tmp | /var/tmp) chmod 1777 "${fake}${allowed}" ;;
        *) chmod ugo+rw "${fake}${allowed}" ;;
      esac
    fi
  done
}

mode_a() {
  local joined commands chmod_line chmod_args ln_line ln_args mkdir_line mkdir_args
  local chmod_lines chmod_cmd arg
  local fake out status

  if [[ ! -f "$CHECKS" ]]; then
    echo "FAIL - $CHECKS is missing" >&2
    exit 1
  fi

  if [[ ! -f "$DOCKERFILE" ]]; then
    report "docker/selfhosted.Dockerfile is present" bad
    return
  fi
  report "docker/selfhosted.Dockerfile is present" ok

  joined=$(join_continuations "$DOCKERFILE")
  commands=$(split_commands "$joined")

  chmod_line=$(printf '%s\n' "$commands" | grep -E '(^|[[:space:]])chmod[[:space:]]+ugo\+rw([[:space:]]|$)' | head -n 1)
  if [[ -n "$chmod_line" ]]; then
    mapfile -t chmod_args < <(args_of "$chmod_line" 'chmod[[:space:]]\+ugo+rw')
  else
    chmod_args=()
  fi

  if [[ ${#chmod_args[@]} -eq ${#CHMOD_PATHS[@]} ]]; then
    local actual_sorted expected_sorted
    mapfile -t actual_sorted < <(printf '%s\n' "${chmod_args[@]}" | sort)
    mapfile -t expected_sorted < <(printf '%s\n' "${CHMOD_PATHS[@]}" | sort)
    if [[ "${actual_sorted[*]}" == "${expected_sorted[*]}" ]]; then
      report "the chmod ugo+rw list is exactly the documented self-update surface" ok
    else
      report "the chmod ugo+rw list is exactly the documented self-update surface (got: ${actual_sorted[*]:-none})" bad
    fi
  else
    report "the chmod ugo+rw list is exactly the documented self-update surface (got: ${chmod_args[*]:-none})" bad
  fi

  # Every chmod in the Dockerfile must leave /usr/local alone, whatever
  # spelling it uses: `chmod 777 /usr/local/bin` is as bad as `chmod ugo+rw`.
  chmod_lines=$(printf '%s\n' "$commands" | grep -E '(^|[[:space:]])chmod[[:space:]]' || true)
  local_chmod_offenders=()
  while IFS= read -r chmod_cmd; do
    [[ -n "$chmod_cmd" ]] || continue
    mapfile -t chmod_cmd_args < <(args_of "$chmod_cmd" 'chmod')
    for arg in "${chmod_cmd_args[@]+"${chmod_cmd_args[@]}"}"; do
      case "$arg" in
        -*) continue ;;
      esac
      # Skip the mode operand (octal or symbolic).
      if [[ "$arg" =~ ^[0-7]{1,4}$ || "$arg" =~ ^[ugoa]*[-+=][rwxXst]*$ ]]; then
        continue
      fi
      if [[ "$arg" == /usr/local* ]]; then
        local_chmod_offenders+=("$arg")
      fi
    done
  done <<< "$chmod_lines"
  if [[ ${#local_chmod_offenders[@]} -eq 0 ]]; then
    report "no path under /usr/local is made world-writable" ok
  else
    report "no path under /usr/local is made world-writable (offenders: ${local_chmod_offenders[*]})" bad
  fi

  ln_line=$(printf '%s\n' "$commands" | grep -E '(^|[[:space:]])ln[[:space:]]+-s([[:space:]]|$)' | head -n 1)
  if [[ -n "$ln_line" ]]; then
    mapfile -t ln_args < <(args_of "$ln_line" 'ln[[:space:]][[:space:]]*-s')
  else
    ln_args=()
  fi
  if [[ ${#ln_args[@]} -eq 2 && "${ln_args[0]}" == "$YTDLP_BIN" \
    && "${ln_args[1]}" == "$YTDLP_LINK" ]]; then
    report "the Dockerfile creates the symlink $YTDLP_LINK -> $YTDLP_BIN" ok
  else
    report "the Dockerfile creates the symlink $YTDLP_LINK -> $YTDLP_BIN (got: ${ln_args[*]:-none})" bad
  fi

  if printf '%s\n' "$joined" | grep -qF "COPY --from=builder /usr/local/bin/yt-dlp $YTDLP_BIN"; then
    report "yt-dlp is copied to $YTDLP_BIN" ok
  else
    report "yt-dlp is copied to $YTDLP_BIN" bad
  fi

  # Replay the Dockerfile's runtime command in a simulated root.
  mkdir_line=$(printf '%s\n' "$commands" | grep -E '(^|[[:space:]])mkdir[[:space:]]+-p([[:space:]]|$)' | tail -n 1)
  if [[ -n "$mkdir_line" ]]; then
    mapfile -t mkdir_args < <(args_of "$mkdir_line" 'mkdir[[:space:]][[:space:]]*-p')
  else
    mkdir_args=()
  fi

  new_case
  fake="$CASE_DIR/root"
  build_simulated_root "$fake"

  out=$(bash "$CHECKS" --root "$fake" 2>&1)
  status=$?
  if [[ "$status" -eq 0 ]] && ! printf '%s\n' "$out" | grep -q '^FAIL -'; then
    report "the simulated selfhosted image layout satisfies the image check contract" ok
  else
    report "the simulated selfhosted image layout satisfies the image check contract" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  # Edge case: the same replay under a root whose path contains a space.
  new_case
  fake="$CASE_DIR/root with space"
  build_simulated_root "$fake"

  out=$(bash "$CHECKS" --root "$fake" 2>&1)
  status=$?
  if [[ "$status" -eq 0 ]] && ! printf '%s\n' "$out" | grep -q '^FAIL -'; then
    report "the image checks handle a simulated root whose path contains a space" ok
  else
    report "the image checks handle a simulated root whose path contains a space" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# --- Mode B: the built image ----------------------------------------------------

# version_lt <a> <b> — true when version a is older than version b.
version_lt() {
  local a=$1 b=$2
  local -a pa pb
  local i max x y
  IFS='.' read -ra pa <<< "$a"
  IFS='.' read -ra pb <<< "$b"
  max=${#pa[@]}
  [[ ${#pb[@]} -gt $max ]] && max=${#pb[@]}
  for ((i = 0; i < max; i++)); do
    x=${pa[i]:-0}
    y=${pb[i]:-0}
    x=${x//[^0-9]/}
    y=${y//[^0-9]/}
    x=${x:-0}
    y=${y:-0}
    if ((10#$x < 10#$y)); then
      return 0
    fi
    if ((10#$x > 10#$y)); then
      return 1
    fi
  done
  return 1
}

# run_checks <image> <user-args> — run the in-image checks inside the container.
# The script itself is fed to the container on stdin; the container's exit
# status is the checks script's exit status.
run_checks() {
  local image=$1
  shift
  local out status
  out=$(docker run --rm -i "$@" "$image" bash -s < "$CHECKS" 2>&1)
  status=$?
  LAST_OUT=$out
  LAST_STATUS=$status
}

# checks_ran <output> — the in-image checks must have run to completion.
checks_ran() {
  printf '%s\n' "$1" | grep -qE '^[0-9]+ passed, [0-9]+ failed'
}

mode_b() {
  local image=$1
  local out status before after update_status network_message

  if [[ ! -f "$CHECKS" ]]; then
    echo "FAIL - $CHECKS is missing" >&2
    exit 1
  fi
  if ! command -v docker > /dev/null 2>&1; then
    echo "FAIL - docker is required to test a built image but was not found on PATH" >&2
    exit 1
  fi
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    echo "FAIL - image $image does not exist locally" >&2
    exit 1
  fi

  run_checks "$image"
  out=$LAST_OUT
  status=$LAST_STATUS
  if [[ "$status" -eq 0 ]] && checks_ran "$out" && ! printf '%s\n' "$out" | grep -q '^FAIL -'; then
    report "the image layout contract holds for the image default user" ok
  else
    report "the image layout contract holds for the image default user" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  run_checks "$image" --user 65534:65534
  out=$LAST_OUT
  status=$LAST_STATUS
  if [[ "$status" -eq 0 ]] && checks_ran "$out" && ! printf '%s\n' "$out" | grep -q '^FAIL -'; then
    report "the image layout contract holds for an unprivileged user" ok
  else
    report "the image layout contract holds for an unprivileged user" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  # The updater resolves the binary via realpath and replaces it in place, so
  # the self-update only works as an unprivileged user when /opt/yt-dlp is
  # writable — which is exactly what this suite guards.
  out=$(docker run --rm --user 65534:65534 "$image" bash -c '
    before=$(yt-dlp --version 2>/dev/null | head -n 1)
    echo "__BEFORE=$before"
    yt-dlp --update-to "$before"
    echo "__EXIT=$?"
    echo "__AFTER=$(yt-dlp --version 2>/dev/null | head -n 1)"
  ' 2>&1)
  status=$?
  before=$(printf '%s\n' "$out" | sed -n 's/^__BEFORE=//p' | head -n 1)
  after=$(printf '%s\n' "$out" | sed -n 's/^__AFTER=//p' | head -n 1)
  update_status=$(printf '%s\n' "$out" | sed -n 's/^__EXIT=//p' | head -n 1)
  if [[ "$update_status" == "0" && -n "$before" && "$after" == "$before" ]]; then
    report "yt-dlp --update-to <installed version> exits 0 and leaves the version unchanged" ok
  elif [[ "$update_status" != "0" ]] && network_message=$(network_failure_message "$out"); then
    # The updater could not reach GitHub. That says nothing about the image's
    # permissions, so it must not fail the suite.
    report "yt-dlp --update-to <installed version> could not reach the network ($network_message)" skip
  else
    report "yt-dlp --update-to <installed version> exits 0 and leaves the version unchanged (exit: ${update_status:-none}, before: ${before:-none}, after: ${after:-none})" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  out=$(docker run --rm --user 65534:65534 "$image" bash -c '
    echo "__BEFORE=$(yt-dlp --version 2>/dev/null | head -n 1)"
    yt-dlp --update
    echo "__EXIT=$?"
    echo "__AFTER=$(yt-dlp --version 2>/dev/null | head -n 1)"
  ' 2>&1)
  status=$?
  before=$(printf '%s\n' "$out" | sed -n 's/^__BEFORE=//p' | head -n 1)
  after=$(printf '%s\n' "$out" | sed -n 's/^__AFTER=//p' | head -n 1)
  update_status=$(printf '%s\n' "$out" | sed -n 's/^__EXIT=//p' | head -n 1)
  if [[ "$update_status" == "0" ]]; then
    if [[ -n "$before" && -n "$after" ]] && ! version_lt "$after" "$before"; then
      report "yt-dlp --update does not downgrade the installed binary" ok
    else
      report "yt-dlp --update does not downgrade the installed binary (before: ${before:-none}, after: ${after:-none})" bad
    fi
  elif printf '%s\n' "$out" | grep -qF 'Insufficient permissions to write to'; then
    # Any exit code: this message is the regression this suite exists to
    # catch, so it must never be downgraded to a skip.
    report "yt-dlp --update can replace the binary in place (Insufficient permissions to write to)" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  elif [[ "$update_status" != "0" ]] && network_message=$(network_failure_message "$out"); then
    report "yt-dlp --update could not reach the network ($network_message)" skip
  else
    report "yt-dlp --update exits 0 (exit: ${update_status:-none})" bad
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# --- entry point ----------------------------------------------------------------

if [[ $# -gt 1 ]]; then
  echo "usage: bash tooling/test_selfhosted_image.sh [image-ref]" >&2
  exit 2
fi

load_contract || exit 1

if [[ $# -eq 1 ]]; then
  mode_b "$1"
else
  mode_a
fi

echo "$passed passed, $failed failed, $skipped skipped"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0
