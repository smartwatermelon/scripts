#!/usr/bin/env bats
# bats tests for handoff-sync.sh
#
# Run from repo root:  bats tests/handoff-sync.bats
#
# The script runs rclone bisync. RCLONE_BIN points at a stub in the per-test
# temp dir that records one argv item per line to RCLONE_ARGS and exits with
# the code in rclone.rc. All three directories are under BATS_TEST_TMPDIR,
# which bats removes, so nothing touches a real Drive or ~/.claude.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  TMPDIR_T="${BATS_TEST_TMPDIR:?bats 1.4 or later is required}"
  STUBS="${TMPDIR_T}/stubs"
  mkdir -p "${STUBS}"
  export RCLONE_ARGS="${TMPDIR_T}/rclone-args"

  cat >"${STUBS}/rclone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${RCLONE_ARGS}"
rc_file="$(dirname "$0")/rclone.rc"
if [[ -f "${rc_file}" ]]; then exit "$(cat "${rc_file}")"; fi
exit 0
EOF
  chmod +x "${STUBS}/rclone"

  # Exported BEFORE sourcing: the script reads these as defaults at load
  # time, so even if the source guard regressed, only the stub would run.
  export RCLONE_BIN="${STUBS}/rclone"
  export HANDOFF_LOCAL_DIR="${TMPDIR_T}/handoffs"
  export HANDOFF_REMOTE="testremote:Claude Handoff"
  export HANDOFF_LOG_DIR="${TMPDIR_T}/state"
  LOG_FILE="${HANDOFF_LOG_DIR}/handoff-sync.log"

  source "${REPO_ROOT}/handoff-sync.sh"
}

# ---------------------------------------------------------------------------
# The sync call
# ---------------------------------------------------------------------------

@test "runs rclone bisync between the local folder and the remote" {
  run main
  [ "${status}" -eq 0 ]
  [ "$(sed -n 1p "${RCLONE_ARGS}")" = "bisync" ]
  [ "$(sed -n 2p "${RCLONE_ARGS}")" = "${HANDOFF_LOCAL_DIR}" ]
  # The space in the folder name survives as one argument.
  [ "$(sed -n 3p "${RCLONE_ARGS}")" = "testremote:Claude Handoff" ]
}

@test "passes the self-healing and Drive flags" {
  run main
  local flag
  for flag in --drive-skip-gdocs --create-empty-src-dirs --resilient --recover; do
    grep -qx -- "${flag}" "${RCLONE_ARGS}"
  done
  grep -A1 -x -- --max-lock "${RCLONE_ARGS}" | grep -qx 10m
}

@test "rclone writes to the log file in the log dir" {
  run main
  grep -A1 -x -- --log-file "${RCLONE_ARGS}" | grep -qx "${LOG_FILE}"
}

@test "creates the local and log folders when missing" {
  [ ! -d "${HANDOFF_LOCAL_DIR}" ]
  run main
  [ -d "${HANDOFF_LOCAL_DIR}" ]
  [ -d "${HANDOFF_LOG_DIR}" ]
}

# ---------------------------------------------------------------------------
# Failures are visible
# ---------------------------------------------------------------------------

@test "an rclone failure is the script's exit status" {
  echo 7 >"${STUBS}/rclone.rc"
  run main
  [ "${status}" -eq 7 ]
}

@test "missing rclone exits 1 and says so in the log" {
  RCLONE_BIN="${TMPDIR_T}/does-not-exist/rclone"
  run main
  [ "${status}" -eq 1 ]
  grep -q "rclone not found at '${TMPDIR_T}/does-not-exist/rclone'" "${LOG_FILE}"
}

@test "an empty RCLONE_BIN counts as missing" {
  RCLONE_BIN=""
  run main
  [ "${status}" -eq 1 ]
  [ ! -e "${RCLONE_ARGS}" ]
}

# ---------------------------------------------------------------------------
# Log trimming
# ---------------------------------------------------------------------------

@test "a log over 2000 lines is cut to its last 1000" {
  mkdir -p "${HANDOFF_LOG_DIR}"
  seq 1 2001 >"${LOG_FILE}"
  run main
  [ "$(wc -l <"${LOG_FILE}" | tr -d ' ')" -eq 1000 ]
  [ "$(head -1 "${LOG_FILE}")" = "1002" ]
  [ "$(tail -1 "${LOG_FILE}")" = "2001" ]
}

@test "a log at exactly 2000 lines is left alone" {
  mkdir -p "${HANDOFF_LOG_DIR}"
  seq 1 2000 >"${LOG_FILE}"
  run main
  [ "$(wc -l <"${LOG_FILE}" | tr -d ' ')" -eq 2000 ]
}

# ---------------------------------------------------------------------------
# Script shape
# ---------------------------------------------------------------------------

@test "the default rclone is a full path, because cron's PATH lacks Homebrew" {
  run env -u RCLONE_BIN bash -c "source '${REPO_ROOT}/handoff-sync.sh'; echo \"\${RCLONE_BIN}\""
  [ "${output}" = "/opt/homebrew/bin/rclone" ]
}

@test "sourcing the script does not run main" {
  [ "$(type -t main)" = "function" ]
  [ ! -e "${RCLONE_ARGS}" ]
}
