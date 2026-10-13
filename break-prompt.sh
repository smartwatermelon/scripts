#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# CONFIGURATION
# =========================================================
# Next-prompt intervals (seconds) selected by the user's choice in the dialog.
STAND_UP_NEXT_SECONDS=$((50 * 60)) # 45 work + 5 break, per user's own accounting
SNOOZE_NEXT_SECONDS=180            # "give me a few minutes"
SKIP_NEXT_SECONDS=$((45 * 60))     # same as the normal work interval

# Grace period after "Stand up now": the watcher should not resume counting
# active time until this many idle seconds have been observed, so clicking
# the button and immediately typing again doesn't erase the break.
STAND_UP_GRACE_SECONDS=$((5 * 60))

# How long the dialog waits for a response before treating it as unanswered
# (the only path that reaches the screen lock). A live countdown was tried
# and reverted -- reopening the dialog every second to update the label
# flickered badly. This is a single static dialog with a fixed warning line
# instead.
DIALOG_TIMEOUT_SECONDS=60

# State/log locations
STATE_DIR="${HOME}/.local/state/break-enforcer"
LOG_FILE="${STATE_DIR}/dismissals.log"
NEXT_INTERVAL_FILE="${STATE_DIR}/next-interval-seconds"
GRACE_FILE="${STATE_DIR}/grace-seconds"

# Binaries
OSASCRIPT_BIN="/usr/bin/osascript"
PMSET_BIN="/usr/bin/pmset"

# =========================================================
# FUNCTIONS
# =========================================================
function log_info() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] [INFO] $*"
}

function log_error() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] [ERROR] $*" >&2
}

# Single dialog, three named choices. Uses "giving up after" so an untouched
# dialog (away from keyboard, or ignored outright) times out on its own --
# that is the ONLY path that reaches the screen lock. Every explicit button
# press is a deliberate answer and none of them lock the screen.
#
# Prints one of: stand_up | snooze | skip | timeout
function show_break_dialog() {
  local raw
  raw="$(
    "${OSASCRIPT_BIN}" <<EOF || true
set theResult to display dialog "Time to stand up. Get water, use the bathroom, look away from the screen." & return & return & "Sleeping in ${DIALOG_TIMEOUT_SECONDS} seconds if no response." ¬
  with title "Break Reminder" ¬
  buttons {"Skip this break entirely", "Give me a few minutes", "Stand up now"} ¬
  default button "Stand up now" ¬
  giving up after ${DIALOG_TIMEOUT_SECONDS} ¬
  with icon note
if (gave up of theResult) then
  return "timeout"
else
  return (button returned of theResult)
end if
EOF
  )"

  case "${raw}" in
    "Stand up now") echo "stand_up" ;;
    "Give me a few minutes") echo "snooze" ;;
    "Skip this break entirely") echo "skip" ;;
    "timeout") echo "timeout" ;;
    *)
      # osascript failed, dialog was killed some other way, or returned
      # something unexpected. Fail toward the strict outcome rather than
      # silently letting the break get skipped.
      log_error "Unexpected dialog result: '${raw}'. Treating as timeout."
      echo "timeout"
      ;;
  esac
}

function log_choice() {
  local choice="$1"
  mkdir -p "${STATE_DIR}"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\t%s\n' "${timestamp}" "${choice}" >>"${LOG_FILE}"
}

# Writes the next-interval and grace values for break-watcher.sh to read.
function write_watcher_state() {
  local next_interval="$1"
  local grace="$2"
  mkdir -p "${STATE_DIR}"
  echo "${next_interval}" >"${NEXT_INTERVAL_FILE}"
  echo "${grace}" >"${GRACE_FILE}"
}

function lock_screen() {
  log_info "Dialog timed out unanswered. Sleeping the machine; wake requires the password."
  "${PMSET_BIN}" sleepnow
}

# =========================================================
# MAIN EXECUTION
# =========================================================
function main() {
  local choice
  choice="$(show_break_dialog)"

  case "${choice}" in
    stand_up)
      log_info "User chose: stand up now. Next prompt in ${STAND_UP_NEXT_SECONDS}s, with ${STAND_UP_GRACE_SECONDS}s grace before counting resumes."
      log_choice "stand_up"
      write_watcher_state "${STAND_UP_NEXT_SECONDS}" "${STAND_UP_GRACE_SECONDS}"
      ;;
    snooze)
      log_info "User chose: give me a few minutes. Next prompt in ${SNOOZE_NEXT_SECONDS}s."
      log_choice "snooze"
      write_watcher_state "${SNOOZE_NEXT_SECONDS}" 0
      ;;
    skip)
      log_info "User chose: skip this break entirely. Next prompt in ${SKIP_NEXT_SECONDS}s."
      log_choice "skip"
      write_watcher_state "${SKIP_NEXT_SECONDS}" 0
      ;;
    timeout)
      log_choice "timeout_locked"
      # Write the next-interval BEFORE sleeping, not after. pmset sleepnow
      # returns before the machine is actually asleep, so a trailing write
      # usually lands -- but if the process is suspended first, the watcher
      # wakes to a missing state file. lock_screen also ends in the pmset
      # call, so under `set -e` a non-zero pmset would abort main() before a
      # trailing write every time. Ordering it first removes both.
      write_watcher_state "${SKIP_NEXT_SECONDS}" 0
      lock_screen
      ;;
    *)
      log_error "Unhandled choice '${choice}'. Locking as a fail-safe."
      write_watcher_state "${SKIP_NEXT_SECONDS}" 0
      lock_screen
      ;;
  esac
}

# Skip main when sourced (e.g., by bats tests loading function defs).
# Mirrors the guard in break-watcher.sh, smb-mount.sh, and the `ssh` wrapper.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
