#!/usr/bin/env bats
# bats tests for break-watcher.sh
#
# Run from repo root:  bats tests/break-watcher.bats
#
# Covers get_idle_seconds, which converts ioreg's HIDIdleTime into the whole
# seconds the poll loop compares against IDLE_RESET_THRESHOLD_SECONDS. The
# watcher's decision to reset the active accumulator rests entirely on this
# number, and it is parsed out of ioreg's text output — so a format change
# upstream is the realistic way this breaks.
#
# IOREG_BIN is a variable in the script, so these stub it on PATH rather than
# calling the real ioreg. That keeps the suite hermetic and runnable off macOS.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  TMPDIR_T="$(mktemp -d)"
  # The source guard in break-watcher.sh keeps main()'s infinite poll loop
  # from running when we load the function definitions.
  source "${REPO_ROOT}/break-watcher.sh"
  # Keep log writes inside the temp dir instead of ~/.local/state.
  WATCHER_LOG="${TMPDIR_T}/watcher.log"
}

teardown() {
  [[ -n "${TMPDIR_T:-}" ]] && rm -rf "${TMPDIR_T}"
}

# Writes a stub ioreg that emits $1 as the HIDIdleTime line, and points
# IOREG_BIN at it.
_stub_ioreg() {
  # The value goes in a data file that the stub reads at run time, so it is
  # never part of the stub's source and needs no escaping. An earlier version
  # interpolated it through printf %q, which escapes for eval rather than for
  # a double-quoted heredoc: "5 000000000" became the literal 5\ 000000000 and
  # awk read the wrong field.
  printf '%s\n' "$1" >"${TMPDIR_T}/idle_value"
  cat >"${TMPDIR_T}/ioreg" <<'EOF'
#!/usr/bin/env bash
echo "    | | |   \"HIDIdleTime\" = $(cat "$(dirname "$0")/idle_value")"
EOF
  chmod +x "${TMPDIR_T}/ioreg"
  IOREG_BIN="${TMPDIR_T}/ioreg"
}

@test "converts nanoseconds to whole seconds" {
  _stub_ioreg 5000000000
  run get_idle_seconds
  [ "${status}" -eq 0 ]
  [ "${output}" = "5" ]
}

@test "truncates sub-second idle time to zero rather than erroring" {
  _stub_ioreg 999999999
  run get_idle_seconds
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "a long idle period converts without overflowing" {
  # ~8 hours. Bash integers are 64-bit, so this must not wrap.
  _stub_ioreg 28800000000000
  run get_idle_seconds
  [ "${status}" -eq 0 ]
  [ "${output}" = "28800" ]
}

@test "idle time at the reset threshold is reported exactly" {
  # 60s is IDLE_RESET_THRESHOLD_SECONDS; the loop's comparison is >=, so the
  # boundary value deciding whether the accumulator resets is worth pinning.
  _stub_ioreg 60000000000
  run get_idle_seconds
  [ "${status}" -eq 0 ]
  [ "${output}" = "60" ]
}

@test "unreadable ioreg output fails open toward active, not toward skipping breaks" {
  # If HIDIdleTime cannot be found, returning a large number would look like
  # the user is idle and quietly suppress breaks forever. It must return 0.
  cat >"${TMPDIR_T}/ioreg" <<'EOF'
#!/usr/bin/env bash
echo "some unexpected ioreg output with no idle field"
EOF
  chmod +x "${TMPDIR_T}/ioreg"
  IOREG_BIN="${TMPDIR_T}/ioreg"

  # log_error writes to stderr as well as the log file, and `run` folds stderr
  # into $output, so assert on the last line: the value the caller consumes.
  run get_idle_seconds
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
}

@test "the failure path says why in the log rather than failing silently" {
  cat >"${TMPDIR_T}/ioreg" <<'EOF'
#!/usr/bin/env bash
echo "no idle field here"
EOF
  chmod +x "${TMPDIR_T}/ioreg"
  IOREG_BIN="${TMPDIR_T}/ioreg"

  get_idle_seconds >/dev/null 2>&1
  run cat "${WATCHER_LOG}"
  [[ "${output}" == *"Could not read HIDIdleTime"* ]]
}

@test "only the first HIDIdleTime match is used" {
  # ioreg can list multiple IOHIDSystem nodes. The awk uses `exit` to take the
  # first; this pins that rather than concatenating or summing matches.
  cat >"${TMPDIR_T}/ioreg" <<'EOF'
#!/usr/bin/env bash
echo '    | | |   "HIDIdleTime" = 7000000000'
echo '    | | |   "HIDIdleTime" = 99000000000'
EOF
  chmod +x "${TMPDIR_T}/ioreg"
  IOREG_BIN="${TMPDIR_T}/ioreg"

  run get_idle_seconds
  [ "${status}" -eq 0 ]
  [ "${output}" = "7" ]
}

@test "the stub helper passes values through verbatim, without escaping artifacts" {
  # Guards the helper itself. It once ran the value through printf %q, which
  # escapes for eval and not for a heredoc, so a value with a space reached awk
  # as 5\ 000000000 and the wrong field was read. Every real test here uses a
  # plain integer, so only a test like this one catches that class of bug.
  _stub_ioreg "5 000000000"
  run "${TMPDIR_T}/ioreg"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'"HIDIdleTime" = 5 000000000' ]]
  # A literal backslash would mean the escaping artifact is back.
  [[ "${output}" != *[\\]* ]]
}

@test "the default break threshold is a whole multiple of the poll interval" {
  # If it were not, active_seconds would step past the threshold rather than
  # landing on it, making the actual break interval longer than configured.
  [ $((DEFAULT_ACTIVE_THRESHOLD_SECONDS % POLL_INTERVAL_SECONDS)) -eq 0 ]
}

@test "sourcing the script does not start the poll loop" {
  # If the source guard regressed, setup() would have hung in main()'s infinite
  # loop and the suite would never reach this assertion.
  local main_type
  main_type="$(type -t main)"
  [ "${main_type}" = "function" ]
}

# read_int_state_file is what carries break-prompt.sh's decision back into the
# poll loop. It is the only validation between a state file and the interval
# that governs when the next break fires, so a bad value silently changing the
# schedule is exactly the failure it exists to prevent.

@test "a valid state file value is used as-is" {
  printf '180\n' >"${TMPDIR_T}/next"
  run read_int_state_file "${TMPDIR_T}/next" 2700
  [ "${status}" -eq 0 ]
  [ "${output}" = "180" ]
}

@test "a missing state file falls back to the default" {
  # The first run after install has no state files at all; the watcher must
  # start on the default interval rather than on an empty value.
  run read_int_state_file "${TMPDIR_T}/does-not-exist" 2700
  [ "${status}" -eq 0 ]
  [ "${output}" = "2700" ]
}

@test "a non-integer state file falls back rather than poisoning the interval" {
  # An arithmetic context would treat garbage as 0, which makes the threshold
  # 0 and fires the prompt on every single poll.
  printf 'not-a-number\n' >"${TMPDIR_T}/next"
  run read_int_state_file "${TMPDIR_T}/next" 2700
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "2700" ]
}

@test "an empty state file falls back rather than yielding an empty interval" {
  # A truncated write (crash mid-write) leaves the file present but empty.
  : >"${TMPDIR_T}/next"
  run read_int_state_file "${TMPDIR_T}/next" 2700
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "2700" ]
}

@test "a negative state file value falls back rather than counting backwards" {
  printf -- '-30\n' >"${TMPDIR_T}/next"
  run read_int_state_file "${TMPDIR_T}/next" 2700
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "2700" ]
}

@test "zero is a legitimate value, not a fallback trigger" {
  # break-prompt.sh writes 0 to the grace file for snooze and skip. Rejecting
  # it would resurrect a grace period the user never asked for.
  printf '0\n' >"${TMPDIR_T}/next"
  run read_int_state_file "${TMPDIR_T}/next" 300
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "a rejected state file says why in the log" {
  printf 'garbage\n' >"${TMPDIR_T}/next"
  read_int_state_file "${TMPDIR_T}/next" 2700 >/dev/null 2>&1
  run cat "${WATCHER_LOG}"
  [[ "${output}" == *"contained non-integer"* ]]
}
