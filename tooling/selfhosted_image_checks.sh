#!/usr/bin/env bash
# Assert the production image's yt-dlp executable-path and permission contract.
#
# Runs inside the built selfhosted image (piped to `bash -s`) and can also be
# pointed at a simulated root so the layout assertions run without Docker.
#
# Contract asserted here:
#   * /usr/local/bin is NOT world-writable, so the other binaries living there
#     (Deno, apprise, ...) cannot be replaced from inside the container,
#   * /usr/local/bin/yt-dlp is a symlink to /opt/yt-dlp/yt-dlp, so PATH lookup
#     keeps working while the updater's realpath resolves to /opt/yt-dlp,
#   * /opt/yt-dlp and /opt/yt-dlp/yt-dlp are writable, so yt-dlp can replace
#     itself in place (yt_dlp/update.py renames <binary>.new/<binary>.old
#     beside the binary),
#   * a self-update never downgrades the installed binary.
#
# The contract is defined once, in the "the contract" block below, and can be
# printed with --print-contract so the host-side harness
# (tooling/test_selfhosted_image.sh) asserts the same values instead of
# keeping a second copy of them.
#
# Usage: selfhosted_image_checks.sh [--root <dir>]
#   --root <dir>     check <dir> as if it were "/" (absolute symlink targets are
#                    resolved inside <dir>); checks that need to execute yt-dlp
#                    are reported as skipped instead of failing.
#   --print-contract print the asserted contract to stdout and exit.
#
# Exits 0 only when every case passes.
set -uo pipefail

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

# --- the contract ---------------------------------------------------------------
#
# Single source of truth for the image's executable-path/permission contract.

# The paths docker/selfhosted.Dockerfile makes world-writable.
CHMOD_PATHS=(
  /etc/elixir_tzdata_data
  /etc/yt-dlp
  /etc/yt-dlp/plugins
  /opt/yt-dlp
  /opt/yt-dlp/yt-dlp
)

# Paths allowed to be world-writable in the final image: the self-update
# surface above plus the standard sticky temp dirs (a sticky directory is
# always allowed below).
ALLOWED_PATHS=(
  "${CHMOD_PATHS[@]}"
  /tmp
  /var/tmp
)

# The real yt-dlp binary and the PATH symlink pointing at it.
YTDLP_BIN=/opt/yt-dlp/yt-dlp
YTDLP_LINK=/usr/local/bin/yt-dlp

# The directory holding the real binary: the self-update surface the whole
# image world-writable scan must cover.
SELF_UPDATE_DIR=$(dirname "$YTDLP_BIN")

# yt-dlp updater messages that mean "the network was unreachable", as opposed
# to a permission or verification failure. "Unable to verify the new
# executable" is a checksum/signature failure and is deliberately NOT listed:
# it must fail the suite, never be downgraded to a skip.
NETWORK_FAILURE_MESSAGES=(
  'Unable to obtain version info'
  'Unable to fetch updates'
  'Unable to fetch update spec'
  'Unable to fetch checksums'
)

print_contract() {
  local entry
  for entry in "${CHMOD_PATHS[@]}"; do
    printf 'CHMOD_PATH=%s\n' "$entry"
  done
  for entry in "${ALLOWED_PATHS[@]}"; do
    printf 'ALLOWED_PATH=%s\n' "$entry"
  done
  printf 'YTDLP_BIN=%s\n' "$YTDLP_BIN"
  printf 'YTDLP_LINK=%s\n' "$YTDLP_LINK"
  for entry in "${NETWORK_FAILURE_MESSAGES[@]}"; do
    printf 'NETWORK_FAILURE=%s\n' "$entry"
  done
}

ROOT=''
print_contract_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      if [[ $# -lt 2 ]]; then
        echo "selfhosted_image_checks: --root requires a directory" >&2
        exit 2
      fi
      ROOT="${2%/}"
      shift 2
      ;;
    --print-contract)
      print_contract_only=1
      shift
      ;;
    -h | --help)
      echo "usage: selfhosted_image_checks.sh [--root <dir>] [--print-contract]"
      exit 0
      ;;
    *)
      echo "selfhosted_image_checks: unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$print_contract_only" -eq 1 ]]; then
  print_contract
  exit 0
fi

# path <absolute-path> — the path as it exists under the (simulated) root.
path() { printf '%s' "${ROOT}$1"; }

mode_of() { stat -c '%a' "$1" 2>/dev/null; }

has_other_write() {
  local m=${1:-}
  [[ -n "$m" ]] || return 1
  (( (8#$m & 0002) != 0 ))
}

has_other_exec() {
  local m=${1:-}
  [[ -n "$m" ]] || return 1
  (( (8#$m & 0001) != 0 ))
}

has_sticky() {
  local m=${1:-}
  [[ -n "$m" ]] || return 1
  (( (8#$m & 01000) != 0 ))
}

# have_find — the permission scans below need find(1). When it is missing the
# scans must fail, not pass silently. find exits 1 when some paths could not
# be read (expected for an unprivileged user) and 2 or more on a fatal error;
# only the latter means the scan itself did not run.
have_find() { command -v find > /dev/null 2>&1; }

# have_python3 — the updater-model checks below need python3, which both the
# production image and the ci-base CI container ship. When it is missing those
# checks must fail, not silently skip.
have_python3() { command -v python3 > /dev/null 2>&1; }

# is_network_failure <output> — true when yt-dlp's updater failed because it
# could not reach GitHub, as opposed to a permission or verification failure.
is_network_failure() {
  local message
  for message in "${NETWORK_FAILURE_MESSAGES[@]}"; do
    if [[ "$1" == *"$message"* ]]; then
      return 0
    fi
  done
  return 1
}

# describe_paths <path>... — "path (mode 777)" per path, comma separated, so a
# failure report shows what has to be fixed.
describe_paths() {
  local p mode out=''
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    mode=$(mode_of "$p")
    [[ -n "$out" ]] && out="$out, "
    out="$out$p (mode ${mode:-unknown})"
  done
  printf '%s' "$out"
}

BIN_DIR=$(path /usr/local/bin)
LOCAL_DIR=$(path /usr/local)
OPT_DIR=$(path "$SELF_UPDATE_DIR")
OPT_BIN=$(path "$YTDLP_BIN")
LINK=$(path "$YTDLP_LINK")

# --- layout and permissions ---------------------------------------------------

if [[ -d "$BIN_DIR" ]]; then
  report "/usr/local/bin exists and is a directory" ok
else
  report "/usr/local/bin exists and is a directory" bad
fi

bin_mode=$(mode_of "$BIN_DIR")
if [[ -n "$bin_mode" ]] && ! has_other_write "$bin_mode"; then
  report "/usr/local/bin is not world-writable" ok
else
  report "/usr/local/bin is not world-writable (mode ${bin_mode:-unknown})" bad
fi

# Scan 1: nothing under /usr/local may be world-writable. The scan has to
# actually run: a missing/broken find, a missing /usr/local or an empty
# /usr/local would otherwise make this assertion pass vacuously.
if ! have_find; then
  report "no file or directory under /usr/local is world-writable (find is missing, the scan did not run)" bad
elif [[ ! -d "$LOCAL_DIR" ]]; then
  report "no file or directory under /usr/local is world-writable (/usr/local does not exist, the scan did not run)" bad
else
  entries_file=$(mktemp)
  tmp_dirs+=("$entries_file")
  find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 > "$entries_file" 2>/dev/null
  entries_status=$?
  mapfile -t local_entries_list < "$entries_file"
  local_entries=${#local_entries_list[@]}
  writable_file=$(mktemp)
  tmp_dirs+=("$writable_file")
  find "$LOCAL_DIR" \( -type d -o -type f \) -perm -o+w > "$writable_file" 2>/dev/null
  writable_status=$?
  mapfile -t local_hits < "$writable_file"

  if [[ "$entries_status" -ge 2 ]]; then
    report "no file or directory under /usr/local is world-writable (the scan did not run, find exited with status $entries_status)" bad
  elif [[ "$local_entries" -lt 1 ]]; then
    report "no file or directory under /usr/local is world-writable (the scan did not run, /usr/local has no entries)" bad
  elif [[ "$writable_status" -ge 2 ]]; then
    report "no file or directory under /usr/local is world-writable (the scan did not run, find exited with status $writable_status)" bad
  elif [[ ${#local_hits[@]} -eq 0 ]]; then
    report "no file or directory under /usr/local is world-writable" ok
  else
    report "no file or directory under /usr/local is world-writable (offenders: $(describe_paths "${local_hits[@]}"))" bad
  fi
fi

if [[ -L "$LINK" ]]; then
  link_target=$(readlink "$LINK")
  if [[ "$link_target" == "$YTDLP_BIN" ]]; then
    report "$YTDLP_LINK is a symlink to $YTDLP_BIN" ok
  else
    report "$YTDLP_LINK is a symlink to $YTDLP_BIN (target: ${link_target:-empty})" bad
  fi
else
  report "$YTDLP_LINK is a symlink to $YTDLP_BIN" bad
fi

if [[ -L "$LINK" ]]; then
  link_target=$(readlink "$LINK")
  if [[ "$link_target" == /* ]]; then
    # Absolute targets are resolved inside the (simulated) root.
    resolved_candidate="${ROOT}${link_target}"
  else
    resolved_candidate="$(dirname "$LINK")/${link_target}"
  fi
  resolved=$(readlink -f "$resolved_candidate" 2>/dev/null)
  expected=$(readlink -f "$OPT_BIN" 2>/dev/null)
  if [[ -n "$resolved" && "$resolved" == "$expected" ]]; then
    report "$YTDLP_LINK resolves to the real binary in $SELF_UPDATE_DIR" ok
  else
    report "$YTDLP_LINK resolves to the real binary in $SELF_UPDATE_DIR (resolved: ${resolved:-none})" bad
  fi
else
  report "$YTDLP_LINK resolves to the real binary in $SELF_UPDATE_DIR" bad
fi

if [[ -d "$OPT_DIR" ]]; then
  opt_mode=$(mode_of "$OPT_DIR")
  if has_other_write "$opt_mode"; then
    report "$SELF_UPDATE_DIR is a world-writable directory" ok
  else
    report "$SELF_UPDATE_DIR is a world-writable directory (mode ${opt_mode:-unknown})" bad
  fi
else
  report "$SELF_UPDATE_DIR is a world-writable directory" bad
fi

if [[ -f "$OPT_BIN" && ! -L "$OPT_BIN" ]]; then
  opt_bin_mode=$(mode_of "$OPT_BIN")
  if has_other_write "$opt_bin_mode" && has_other_exec "$opt_bin_mode"; then
    report "$YTDLP_BIN is a world-writable executable regular file" ok
  else
    report "$YTDLP_BIN is a world-writable executable regular file (mode ${opt_bin_mode:-unknown})" bad
  fi
else
  report "$YTDLP_BIN is a world-writable executable regular file" bad
fi

# Scan 2: the only world-writable paths in the image are the documented
# self-update surface (plus the sticky temp dirs). The scan has to actually
# run and has to cover that surface, otherwise this assertion would pass
# vacuously.
if ! have_find; then
  report "world-writable paths are limited to the documented self-update surface (find is missing, the scan did not run)" bad
else
  scan_root="${ROOT:-/}"
  scan_file=$(mktemp)
  tmp_dirs+=("$scan_file")
  find "$scan_root" -xdev \( -type d -o -type f \) -perm -o+w > "$scan_file" 2>/dev/null
  scan_status=$?
  mapfile -t scan_hits < "$scan_file"

  offenders=()
  offender_modes=()
  offender_summary=''
  saw_self_update_surface=0
  for hit in "${scan_hits[@]+"${scan_hits[@]}"}"; do
    [[ -n "$hit" ]] || continue
    rel="$hit"
    if [[ -n "$ROOT" ]]; then
      rel=${hit#"$ROOT"}
      rel=${rel:-/}
    fi
    if [[ "$rel" == "$SELF_UPDATE_DIR" ]]; then
      saw_self_update_surface=1
    fi
    allowed=0
    for allowed_path in "${ALLOWED_PATHS[@]}"; do
      if [[ "$rel" == "$allowed_path" ]]; then
        allowed=1
        break
      fi
    done
    if [[ "$allowed" -eq 1 ]]; then
      continue
    fi
    if [[ -d "$hit" ]] && has_sticky "$(mode_of "$hit")"; then
      continue
    fi
    offenders+=("$rel")
    offender_modes+=("$(mode_of "$hit")")
  done

  index=0
  while [[ "$index" -lt ${#offenders[@]} ]]; do
    [[ -n "$offender_summary" ]] && offender_summary="$offender_summary, "
    offender_summary="$offender_summary${offenders[$index]} (mode ${offender_modes[$index]})"
    index=$((index + 1))
  done

  if [[ "$scan_status" -ge 2 ]]; then
    report "world-writable paths are limited to the documented self-update surface (the scan did not run, find exited with status $scan_status)" bad
  elif [[ "$saw_self_update_surface" -eq 0 ]]; then
    report "world-writable paths are limited to the documented self-update surface (the scan did not cover the self-update surface $SELF_UPDATE_DIR)" bad
  elif [[ ${#offenders[@]} -eq 0 ]]; then
    report "world-writable paths are limited to the documented self-update surface" ok
  else
    report "world-writable paths are limited to the documented self-update surface (offenders: ${offender_summary:-none})" bad
  fi
fi

# --- execution checks ---------------------------------------------------------

if [[ -n "$ROOT" ]]; then
  report "PATH lookup resolves yt-dlp to $YTDLP_LINK (needs a real image)" skip
  report "yt-dlp is executable through the symlink with a relative path (needs a real image)" skip
  report "the updater resolves the binary via realpath and finds it writable (needs a real image)" skip
  report "the in-place replacement rename sequence succeeds (needs a real image)" skip
  report "yt-dlp --update-to <installed version> exits 0 (needs a real image)" skip
  report "yt-dlp --update-to <installed version> leaves the installed version unchanged (needs a real image)" skip
else
  resolved_bin=$(command -v yt-dlp 2>/dev/null)
  if [[ "$resolved_bin" == "$YTDLP_LINK" ]]; then
    reported_version=$(yt-dlp --version < /dev/null 2>/dev/null | head -n 1 | tr -d '\r')
    if [[ "$reported_version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]]; then
      report "PATH lookup resolves yt-dlp to $YTDLP_LINK and reports a version" ok
    else
      report "PATH lookup resolves yt-dlp to $YTDLP_LINK and reports a version (version: ${reported_version:-empty})" bad
    fi
  else
    report "PATH lookup resolves yt-dlp to $YTDLP_LINK (resolved: ${resolved_bin:-none})" bad
  fi

  # Edge case: the symlink must work with a relative path too, not only when
  # the binary is looked up through PATH.
  relative_version=$(cd "$BIN_DIR" && ./yt-dlp --version < /dev/null 2>/dev/null | head -n 1 | tr -d '\r')
  if [[ "$relative_version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]]; then
    report "yt-dlp is executable through the symlink with a relative path and reports a version" ok
  else
    report "yt-dlp is executable through the symlink with a relative path and reports a version (version: ${relative_version:-empty})" bad
  fi

  if ! have_python3; then
    report "the updater resolves the binary via realpath and finds it writable (python3 is required by this suite)" bad
  else
    updater_info=$(python3 - <<'PY' 2>&1
import os
import shutil
import sys

binary = shutil.which("yt-dlp")
if not binary:
    print("WHICH=")
    sys.exit(0)

real = os.path.realpath(binary)
print("WHICH=" + binary)
print("REAL=" + real)
print("FILE_WRITABLE=" + ("1" if os.access(real, os.W_OK) else "0"))
print("DIR_WRITABLE=" + ("1" if os.access(os.path.dirname(real), os.W_OK) else "0"))
PY
    )
    updater_status=$?
    updater_real=$(printf '%s\n' "$updater_info" | sed -n 's/^REAL=//p')
    updater_file_writable=$(printf '%s\n' "$updater_info" | sed -n 's/^FILE_WRITABLE=//p')
    updater_dir_writable=$(printf '%s\n' "$updater_info" | sed -n 's/^DIR_WRITABLE=//p')
    if [[ "$updater_status" -eq 0 && "$updater_real" == "$YTDLP_BIN" \
      && "$updater_file_writable" == "1" && "$updater_dir_writable" == "1" ]]; then
      report "the updater resolves the binary via realpath and finds it writable" ok
    else
      report "the updater resolves the binary via realpath and finds it writable (real: ${updater_real:-none}, file writable: ${updater_file_writable:-none}, dir writable: ${updater_dir_writable:-none})" bad
    fi
  fi

  if ! have_python3; then
    report "the in-place replacement rename sequence succeeds (python3 is required by this suite)" bad
  else
    # The updater replaces the binary in place: it writes <binary>.new, renames
    # the old binary aside and renames the new one in (yt_dlp/update.py). Run
    # that sequence against the real /opt/yt-dlp directory, so a read-only
    # self-update surface fails this check instead of passing it.
    replacement_info=$(python3 - "$OPT_DIR" <<'PY' 2>&1
import os
import stat
import sys

directory = sys.argv[1]
probe_name = ".selfhosted-image-check-probe"
probe = os.path.join(directory, probe_name)
new_probe = probe + ".new"
old_probe = probe + ".old"

original_mode = 0o755
mode = 0
leftovers = []
ok = 0

try:
    with open(probe, "wb") as handle:
        handle.write(b"probe")
    os.chmod(probe, original_mode)
    with open(new_probe, "wb") as handle:
        handle.write(b"probe-new")

    # The exact sequence yt_dlp/update.py performs when replacing the binary.
    os.rename(probe, old_probe)
    os.rename(new_probe, probe)
    os.chmod(probe, original_mode)
    os.remove(old_probe)

    mode = stat.S_IMODE(os.stat(probe).st_mode)
    leftovers = sorted(
        name
        for name in os.listdir(directory)
        if name.startswith(probe_name) and (name.endswith(".new") or name.endswith(".old"))
    )
    ok = 1
except OSError as error:
    print("ERROR=" + type(error).__name__ + ": " + str(error))
finally:
    for leftover in (probe, new_probe, old_probe):
        try:
            os.remove(leftover)
        except OSError:
            pass

print("OK=%d" % ok)
print("MODE=%o" % mode)
print("LEFTOVERS=" + ",".join(leftovers))
PY
    )
    replacement_status=$?
    replacement_ok=$(printf '%s\n' "$replacement_info" | sed -n 's/^OK=//p')
    replacement_mode=$(printf '%s\n' "$replacement_info" | sed -n 's/^MODE=//p')
    replacement_leftovers=$(printf '%s\n' "$replacement_info" | sed -n 's/^LEFTOVERS=//p')
    replacement_error=$(printf '%s\n' "$replacement_info" | sed -n 's/^ERROR=//p')
    if [[ "$replacement_status" -eq 0 && "$replacement_ok" == "1" && "$replacement_mode" == "755" \
      && -z "$replacement_leftovers" ]]; then
      report "the in-place replacement rename sequence succeeds and preserves the binary mode" ok
    else
      report "the in-place replacement rename sequence succeeds and preserves the binary mode (status: $replacement_status, mode: ${replacement_mode:-none}, leftovers: ${replacement_leftovers:-none}, error: ${replacement_error:-none})" bad
    fi
  fi

  installed_version=$(yt-dlp --version < /dev/null 2>/dev/null | head -n 1 | tr -d '\r')
  update_output=$(yt-dlp --update-to "$installed_version" < /dev/null 2>&1)
  update_status=$?
  version_after=$(yt-dlp --version < /dev/null 2>/dev/null | head -n 1 | tr -d '\r')
  if [[ "$update_status" -eq 0 ]] && printf '%s\n' "$update_output" | grep -qiE 'up[ -]to[ -]date'; then
    report "yt-dlp --update-to <installed version> exits 0 and reports the binary is up to date" ok
  elif is_network_failure "$update_output"; then
    # The update could not reach GitHub. That says nothing about this image's
    # permissions, so it must not fail the suite.
    report "yt-dlp --update-to <installed version> could not reach the network" skip
  else
    report "yt-dlp --update-to <installed version> exits 0 and reports the binary is up to date (status: $update_status, output: ${update_output:-empty})" bad
  fi
  if [[ -n "$installed_version" && "$version_after" == "$installed_version" ]]; then
    report "yt-dlp --update-to <installed version> leaves the installed version unchanged" ok
  else
    report "yt-dlp --update-to <installed version> leaves the installed version unchanged (before: ${installed_version:-none}, after: ${version_after:-none})" bad
  fi
fi

# Edge case: a path with an embedded NUL byte must be rejected by the OS
# layer (ValueError: embedded null byte), never silently truncated to a
# different path.
if [[ -n "$ROOT" ]] && ! have_python3; then
  # The simulated root has no image to exercise; the host is not required to
  # ship python3, so this check runs in the image instead.
  report "paths with an embedded NUL byte are rejected by the OS layer instead of being silently truncated (needs a real image)" skip
elif ! have_python3; then
  report "paths with an embedded NUL byte are rejected by the OS layer instead of being silently truncated (python3 is required by this suite)" bad
else
  nul_info=$(python3 - "$ROOT" <<'PY' 2>&1
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else ""
base = os.path.join(root, "usr/local/bin") if root else "/usr/local/bin"

nul_path = base + "/yt\x00-dlp"
truncated_path = base + "/yt"

try:
    os.stat(nul_path)
except ValueError as error:
    print("VALUE_ERROR=" + str(error))
except OSError as error:
    print("OS_ERROR=" + type(error).__name__ + ": " + str(error))
else:
    print("NO_ERROR=1")

try:
    os.stat(truncated_path)
except FileNotFoundError:
    print("TRUNCATED_ABSENT=1")
except OSError as error:
    print("TRUNCATED_ERROR=" + type(error).__name__)
else:
    print("TRUNCATED_PRESENT=1")
PY
  )
  nul_status=$?
  nul_value_error=$(printf '%s\n' "$nul_info" | sed -n 's/^VALUE_ERROR=//p')
  nul_truncated=$(printf '%s\n' "$nul_info" | sed -n 's/^TRUNCATED_ABSENT=//p')
  # Python's wording for the embedded-NUL ValueError differs across
  # versions: "embedded null byte" (<= 3.13) and "embedded null character"
  # (newer CPython, e.g. Debian trixie's python3). Accept either; the
  # assertion is that the OS layer rejects the path, not the exact wording.
  if [[ "$nul_status" -eq 0 && ( "$nul_value_error" == *"embedded null byte"* || "$nul_value_error" == *"embedded null character"* ) \
    && "$nul_truncated" == "1" ]]; then
    report "paths with an embedded NUL byte are rejected by the OS layer instead of being silently truncated" ok
  else
    report "paths with an embedded NUL byte are rejected by the OS layer instead of being silently truncated (value error: ${nul_value_error:-none}, truncated path absent: ${nul_truncated:-none})" bad
  fi
fi

if [[ "$skipped" -gt 0 ]]; then
  echo "$skipped skipped"
fi
echo "$passed passed, $failed failed"
if [[ "$failed" -eq 0 ]]; then
  exit 0
fi
exit 1
