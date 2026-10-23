#!/usr/bin/env bats
# bats tests for disk-space-alert.sh
#
# Run from repo root:  bats tests/disk-space-alert.bats
#
# The script reads df and posts a notification with osascript. Both are
# *_BIN variables; setup() points each at a stub in the per-test temp dir.
# The df stub reports the KiB value in df.kib; the osascript stub records
# one argv item per line to NOTIFY and exits with the code in osascript.rc.
# The script deletes nothing, and the temp dir is BATS_TEST_TMPDIR, which
# bats removes. Nothing here assumes macOS, so it runs on the ubuntu runner.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  TMPDIR_T="${BATS_TEST_TMPDIR:?bats 1.4 or later is required}"
  STUBS="${TMPDIR_T}/stubs"
  mkdir -p "${STUBS}"
  export NOTIFY="${TMPDIR_T}/notify"
  export DF_CALLS="${TMPDIR_T}/df-calls"

  cat >"${STUBS}/df" <<'EOF'
#!/usr/bin/env bash
echo "df $*" >>"${DF_CALLS}"
dir="$(dirname "$0")"
if [[ -f "${dir}/df.rc" ]]; then exit "$(cat "${dir}/df.rc")"; fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3s5 482797652 300000000 $(cat "${dir}/df.kib") 88% /System/Volumes/Data"
EOF
  chmod +x "${STUBS}/df"

  cat >"${STUBS}/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${NOTIFY}"
rc_file="$(dirname "$0")/osascript.rc"
if [[ -f "${rc_file}" ]]; then exit "$(cat "${rc_file}")"; fi
exit 0
EOF
  chmod +x "${STUBS}/osascript"

  # Exported BEFORE sourcing: the script reads these as defaults at load
  # time, so even if the source guard regressed, only stubs would run.
  export DF_BIN="${STUBS}/df"
  export OSASCRIPT_BIN="${STUBS}/osascript"
  export DATA_VOLUME="${TMPDIR_T}"

  _free_gib 100
  source "${REPO_ROOT}/disk-space-alert.sh"
}

# Sets the df stub's Available column to $1 GiB (as KiB).
_free_gib() {
  echo "$(($1 * 1024 * 1024))" >"${STUBS}/df.kib"
}

# ---------------------------------------------------------------------------
# Threshold
# ---------------------------------------------------------------------------

@test "plenty of free space logs OK and posts nothing" {
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK: 100 GiB free on ${TMPDIR_T} (threshold 40 GiB)"* ]]
  [ ! -e "${NOTIFY}" ]
}

@test "free space below the default 40 GiB posts a notification" {
  _free_gib 37
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"LOW: 37 GiB free"* ]]
  grep -qx "Low disk space" "${NOTIFY}"
  grep -qx "37 GiB free on ${TMPDIR_T} (alert below 40 GiB)." "${NOTIFY}"
}

@test "free space exactly at the threshold does not alert" {
  _free_gib 40
  run main
  [ "${status}" -eq 0 ]
  [ ! -e "${NOTIFY}" ]
}

@test "a partial GiB rounds down, so 39.9 GiB alerts" {
  echo "$((40 * 1024 * 1024 - 1))" >"${STUBS}/df.kib"
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"LOW: 39 GiB free"* ]]
  [ -e "${NOTIFY}" ]
}

@test "the first argument overrides the threshold" {
  _free_gib 60
  run main 75
  [ "${status}" -eq 0 ]
  grep -qx "60 GiB free on ${TMPDIR_T} (alert below 75 GiB)." "${NOTIFY}"
}

@test "a non-numeric, zero or negative threshold exits 2 and posts nothing" {
  local bad
  for bad in abc 0 -5 4.5 "" " 40"; do
    run main "${bad}"
    if [[ -z "${bad}" ]]; then
      # An empty first argument falls back to the default.
      [ "${status}" -eq 0 ]
      continue
    fi
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"threshold must be a whole number"* ]]
    [ ! -e "${NOTIFY}" ]
  done
}

# ---------------------------------------------------------------------------
# Failures are reported, not silent
# ---------------------------------------------------------------------------

@test "a df failure posts a check-failed notification and exits 1" {
  echo 1 >"${STUBS}/df.rc"
  run main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"could not read free space on ${TMPDIR_T}"* ]]
  grep -qx "Disk space check failed" "${NOTIFY}"
}

@test "unparseable df output is treated as a failure" {
  echo "n/a" >"${STUBS}/df.kib"
  run main
  [ "${status}" -eq 1 ]
  grep -qx "Disk space check failed" "${NOTIFY}"
}

@test "missing df is a failure, not a pass" {
  DF_BIN=""
  run main
  [ "${status}" -eq 1 ]
  grep -qx "Disk space check failed" "${NOTIFY}"
}

@test "an osascript failure on a low reading exits 1 and logs the alert" {
  _free_gib 10
  echo 1 >"${STUBS}/osascript.rc"
  run main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"osascript failed; could not post: Low disk space"* ]]
}

@test "missing osascript on a low reading exits 1" {
  _free_gib 10
  OSASCRIPT_BIN="${TMPDIR_T}/does-not-exist/osascript"
  run main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"osascript not found"* ]]
}

@test "df is asked about DATA_VOLUME in POSIX KiB form" {
  run main
  grep -qx "df -Pk ${TMPDIR_T}" "${DF_CALLS}"
}

# ---------------------------------------------------------------------------
# Notification safety
# ---------------------------------------------------------------------------

@test "title and message reach osascript as argv, not as script source" {
  DATA_VOLUME='/Vol "quoted" & end tell'
  _free_gib 5
  run main
  [ "${status}" -eq 0 ]
  # The three -e lines are fixed; the volume name appears only in argv.
  [ "$(sed -n '1,6p' "${NOTIFY}" | grep -c 'quoted')" -eq 0 ]
  grep -qx '5 GiB free on /Vol "quoted" & end tell (alert below 40 GiB).' "${NOTIFY}"
}

# ---------------------------------------------------------------------------
# Script shape
# ---------------------------------------------------------------------------

@test "the script never deletes or moves a path itself" {
  # Same guard as tests/disk-cleanup.bats. Comment lines are ignored.
  run grep -nE '^([^#]*[^[:alnum:]_-])?(rm|rmdir|mv|unlink|shred)([^[:alnum:]_-]|$)|^[^#]*[[:space:]]-delete([^[:alnum:]_]|$)' \
    "${REPO_ROOT}/disk-space-alert.sh"
  [ "${status}" -eq 1 ]
}

@test "sourcing the script does not run main" {
  [ "$(type -t main)" = "function" ]
  [ ! -e "${NOTIFY}" ]
  [ ! -e "${DF_CALLS}" ]
}
