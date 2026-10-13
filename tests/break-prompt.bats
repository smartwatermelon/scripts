#!/usr/bin/env bats
# bats tests for break-prompt.sh
#
# Run from repo root:  bats tests/break-prompt.bats
#
# The dialog is a single osascript modal with three named buttons, and every
# decision the script makes hangs off which string comes back. Two directions
# are worth pinning. A button whose text drifts out of sync with the case arms
# here stops being recognized, and an unrecognized result is treated as a
# timeout -- so a user who clicked "Stand up now" gets their machine slept out
# from under them. In the other direction, a failure that resolved toward
# "skip" would suppress the break silently, with nothing in the log to say why.
#
# OSASCRIPT_BIN is a variable in the script, so these stub it rather than
# opening real dialogs. That keeps the suite hermetic, non-blocking, and
# runnable off macOS.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  TMPDIR_T="$(mktemp -d)"
  # The source guard in break-prompt.sh keeps main() from firing real dialogs.
  source "${REPO_ROOT}/break-prompt.sh"
  # Keep state writes inside the temp dir instead of ~/.local/state.
  STATE_DIR="${TMPDIR_T}/state"
  LOG_FILE="${STATE_DIR}/dismissals.log"
  NEXT_INTERVAL_FILE="${STATE_DIR}/next-interval-seconds"
  GRACE_FILE="${STATE_DIR}/grace-seconds"
}

teardown() {
  [[ -n "${TMPDIR_T:-}" ]] && rm -rf "${TMPDIR_T}"
}

# Writes a stub osascript that prints $1 verbatim, and points OSASCRIPT_BIN at
# it. The value goes in a data file the stub reads at run time, so it is never
# part of the stub's source and needs no escaping.
_stub_osascript() {
  printf '%s\n' "$1" >"${TMPDIR_T}/dialog_result"
  cat >"${TMPDIR_T}/osascript" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/dialog_result"
EOF
  chmod +x "${TMPDIR_T}/osascript"
  OSASCRIPT_BIN="${TMPDIR_T}/osascript"
}

# Stubs pmset so a test that reaches the lock path records the call instead of
# actually sleeping the machine running the suite.
_stub_pmset() {
  cat >"${TMPDIR_T}/pmset" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/pmset_calls"
EOF
  chmod +x "${TMPDIR_T}/pmset"
  PMSET_BIN="${TMPDIR_T}/pmset"
}

# =========================================================
# show_break_dialog: raw button text -> choice token
# =========================================================
# Each button string below is duplicated from the AppleScript literal in
# break-prompt.sh on purpose. If someone reword a button without updating the
# matching case arm, the two copies diverge and these tests fail -- which is
# the whole point, since the script itself would just silently start treating
# that button as a timeout.

@test "the stand-up button maps to stand_up" {
  _stub_osascript "Stand up now"
  run show_break_dialog
  [ "${status}" -eq 0 ]
  [ "${output}" = "stand_up" ]
}

@test "the snooze button maps to snooze" {
  _stub_osascript "Give me a few minutes"
  run show_break_dialog
  [ "${status}" -eq 0 ]
  [ "${output}" = "snooze" ]
}

@test "the skip button maps to skip" {
  _stub_osascript "Skip this break entirely"
  run show_break_dialog
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip" ]
}

@test "an untouched dialog maps to timeout" {
  # The AppleScript returns the literal "timeout" when `gave up` is true.
  _stub_osascript "timeout"
  run show_break_dialog
  [ "${status}" -eq 0 ]
  [ "${output}" = "timeout" ]
}

@test "empty output (osascript failed) fails toward timeout, not toward skip" {
  # Resolving a failure toward "skip" would suppress the break silently.
  _stub_osascript ""
  run show_break_dialog
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "timeout" ]
}

@test "an unrecognized result fails toward timeout" {
  _stub_osascript "Some Other Button"
  run show_break_dialog
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "timeout" ]
}

@test "an unexpected result says why rather than failing silently" {
  # An unexplained lock is the failure mode this log line exists to prevent.
  _stub_osascript "Some Other Button"
  run show_break_dialog
  [[ "${output}" == *"Unexpected dialog result"* ]]
}

@test "a button match is exact, not a prefix" {
  # "Skip this break entirely, again" must not be read as the skip button.
  _stub_osascript "Skip this break entirely, again"
  run show_break_dialog
  [ "${lines[-1]}" = "timeout" ]
}

# =========================================================
# main: choice -> watcher state
# =========================================================
# The two state files are the entire contract with break-watcher.sh: the next
# interval, and the grace period before the active accumulator resumes. If
# these are wrong the watcher schedules the next break wrong, and nothing in
# either script notices.

@test "stand up now writes the long interval and a grace period" {
  _stub_osascript "Stand up now"
  run main
  [ "${status}" -eq 0 ]
  [ "$(cat "${NEXT_INTERVAL_FILE}")" = "${STAND_UP_NEXT_SECONDS}" ]
  # Grace is what keeps the break from being erased by typing again the moment
  # the button is clicked, so a zero here would quietly defeat the feature.
  [ "$(cat "${GRACE_FILE}")" = "${STAND_UP_GRACE_SECONDS}" ]
}

@test "snooze writes the short interval and no grace" {
  _stub_osascript "Give me a few minutes"
  run main
  [ "${status}" -eq 0 ]
  [ "$(cat "${NEXT_INTERVAL_FILE}")" = "${SNOOZE_NEXT_SECONDS}" ]
  [ "$(cat "${GRACE_FILE}")" = "0" ]
}

@test "skip writes the normal work interval and no grace" {
  _stub_osascript "Skip this break entirely"
  run main
  [ "${status}" -eq 0 ]
  [ "$(cat "${NEXT_INTERVAL_FILE}")" = "${SKIP_NEXT_SECONDS}" ]
  [ "$(cat "${GRACE_FILE}")" = "0" ]
}

@test "snooze is shorter than a full work interval" {
  # Snooze means "a few minutes", not "another whole cycle". Pins the intent
  # rather than the number, so tuning the value stays free.
  [ "${SNOOZE_NEXT_SECONDS}" -lt "${SKIP_NEXT_SECONDS}" ]
}

@test "every interval is a whole multiple of the watcher poll interval" {
  # The watcher accumulates active time in fixed poll-sized steps, so an
  # interval that is not a multiple is silently rounded up past what the
  # dialog promised. Read from break-watcher.sh rather than hardcoded, so a
  # change to the poll interval is caught here.
  local poll
  poll="$(sed -n 's/^POLL_INTERVAL_SECONDS=\([0-9]*\).*/\1/p' "${REPO_ROOT}/break-watcher.sh")"
  [ -n "${poll}" ]
  [ $((STAND_UP_NEXT_SECONDS % poll)) -eq 0 ]
  [ $((SNOOZE_NEXT_SECONDS % poll)) -eq 0 ]
  [ $((SKIP_NEXT_SECONDS % poll)) -eq 0 ]
  [ $((STAND_UP_GRACE_SECONDS % poll)) -eq 0 ]
}

@test "no explicit button press ever sleeps the machine" {
  # The timeout is meant to be the only path to the lock. A button press that
  # reached pmset would sleep a user who answered the dialog deliberately.
  _stub_pmset
  for button in "Stand up now" "Give me a few minutes" "Skip this break entirely"; do
    _stub_osascript "${button}"
    run main
    [ "${status}" -eq 0 ]
  done
  [ ! -f "${TMPDIR_T}/pmset_calls" ]
}

@test "an unanswered dialog sleeps the machine" {
  _stub_osascript "timeout"
  _stub_pmset
  run main
  [ "${status}" -eq 0 ]
  [ "$(cat "${TMPDIR_T}/pmset_calls")" = "sleepnow" ]
}

@test "the lock path still leaves the watcher a sane interval to wake into" {
  # Without this the watcher resumes on a stale or missing state file after
  # the machine wakes back up.
  _stub_osascript "timeout"
  _stub_pmset
  run main
  [ "$(cat "${NEXT_INTERVAL_FILE}")" = "${SKIP_NEXT_SECONDS}" ]
  [ "$(cat "${GRACE_FILE}")" = "0" ]
}

# =========================================================
# Choice log
# =========================================================

@test "each choice is recorded in the dismissal log" {
  _stub_osascript "Skip this break entirely"
  run main
  [ "${status}" -eq 0 ]
  run cat "${LOG_FILE}"
  [[ "${output}" == *"skip"* ]]
}

@test "a timeout lock is logged distinctly from a deliberate skip" {
  # Both leave the same next-interval behind, so the log is the only place the
  # difference between "user chose to skip" and "user was away" survives.
  _stub_osascript "timeout"
  _stub_pmset
  run main
  run cat "${LOG_FILE}"
  [[ "${output}" == *"timeout_locked"* ]]
}

@test "the log appends across prompts rather than overwriting" {
  _stub_osascript "Give me a few minutes"
  run main
  _stub_osascript "Skip this break entirely"
  run main
  run cat "${LOG_FILE}"
  [[ "${output}" == *"snooze"* ]]
  [[ "${output}" == *"skip"* ]]
  [ "${#lines[@]}" -eq 2 ]
}

# =========================================================
# Source guard
# =========================================================

@test "sourcing the script does not run main (no dialog is triggered)" {
  # If the source guard regressed, setup() itself would have blocked on a real
  # dialog and the suite would hang rather than reach this assertion.
  local dialog_type main_type
  dialog_type="$(type -t show_break_dialog)"
  main_type="$(type -t main)"
  [ "${dialog_type}" = "function" ]
  [ "${main_type}" = "function" ]
}

# Ordering: state must be durable before the machine is told to sleep.
#
# `pmset sleepnow` returns before the machine is actually asleep, so a write
# placed after it usually lands -- but "usually" is the whole problem. If the
# process is suspended first, the watcher wakes to a missing state file. The
# same swap also covers a harder failure: lock_screen ends in the pmset call,
# so under `set -e` a non-zero pmset aborts main() before a trailing write
# runs every single time, not just in a race.

# Stubs a pmset that records the state files' contents at the moment it is
# called. Anything written after this point does not exist as far as a machine
# that sleeps immediately is concerned.
_stub_pmset_snapshotting_state() {
  cat >"${TMPDIR_T}/pmset" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TMPDIR_T}/pmset_calls"
cp "${NEXT_INTERVAL_FILE}" "${TMPDIR_T}/next_at_sleep" 2>/dev/null || true
cp "${GRACE_FILE}" "${TMPDIR_T}/grace_at_sleep" 2>/dev/null || true
EOF
  chmod +x "${TMPDIR_T}/pmset"
  PMSET_BIN="${TMPDIR_T}/pmset"
}

@test "watcher state is written before the machine is told to sleep" {
  _stub_osascript "timeout"
  _stub_pmset_snapshotting_state
  run main
  [ "${status}" -eq 0 ]
  [ -f "${TMPDIR_T}/next_at_sleep" ]
  [ "$(cat "${TMPDIR_T}/next_at_sleep")" = "${SKIP_NEXT_SECONDS}" ]
  [ "$(cat "${TMPDIR_T}/grace_at_sleep")" = "0" ]
}

@test "the fail-safe path also writes state before sleeping" {
  # An unrecognized choice reaches the same lock, and the watcher needs a sane
  # interval to wake into just as much as it does on a real timeout.
  _stub_osascript "Some Other Button"
  _stub_pmset_snapshotting_state
  run main
  [ "${status}" -eq 0 ]
  [ -f "${TMPDIR_T}/next_at_sleep" ]
  [ "$(cat "${TMPDIR_T}/next_at_sleep")" = "${SKIP_NEXT_SECONDS}" ]
}

@test "state survives pmset failing outright" {
  # lock_screen's last command is the pmset call, so under `set -e` a non-zero
  # exit aborts main() before any trailing write. Deterministic, not a race.
  cat >"${TMPDIR_T}/pmset" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TMPDIR_T}/pmset"
  PMSET_BIN="${TMPDIR_T}/pmset"
  _stub_osascript "timeout"
  run main
  # main() surfaces pmset's failure rather than swallowing it: lock_screen is
  # the last command in the branch, so its non-zero status propagates out.
  # That is the point of the test -- the state below must be durable whether
  # or not the sleep itself succeeded.
  [ "${status}" -ne 0 ]
  [ -f "${NEXT_INTERVAL_FILE}" ]
  [ "$(cat "${NEXT_INTERVAL_FILE}")" = "${SKIP_NEXT_SECONDS}" ]
}
