#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# CONFIGURATION
# =========================================================
# Default active-time threshold before triggering a break prompt (seconds).
# Used for the very first prompt after the watcher starts, and as a fallback
# if break-prompt.sh's state files are missing or unreadable.
DEFAULT_ACTIVE_THRESHOLD_SECONDS=$((45 * 60))

# How often to poll idle time (seconds)
POLL_INTERVAL_SECONDS=30

# Idle time above which the poll interval is NOT counted as active (seconds).
# HIDIdleTime is reported in nanoseconds; this is compared after conversion.
IDLE_RESET_THRESHOLD_SECONDS=60

# Paths
# Resolve through symlinks: launchd invokes this via ~/.local/bin/break-watcher.sh,
# so a plain dirname would look for break-prompt.sh in ~/.local/bin rather than
# alongside this script in the repo.
SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SELF_PATH}")"
BREAK_PROMPT_SCRIPT="${SCRIPT_DIR}/break-prompt.sh"
# Two log destinations by design:
#   ~/.local/state/break-enforcer/   - this script's own logs and the bypass
#                                      log, created by main() at startup.
#   ~/.local/state/com.asiago.break-watcher.log
#                                    - launchd's stdout/stderr capture. It
#                                      lives one level up because launchd does
#                                      not create missing parent directories,
#                                      and would silently drop the first run's
#                                      output if it pointed into the subdir
#                                      above before main() ran mkdir -p.
STATE_DIR="${HOME}/.local/state/break-enforcer"
WATCHER_LOG="${STATE_DIR}/watcher.log"
# Written by break-prompt.sh after each prompt: how long until the next one
# should fire, and how many idle seconds must be observed before the active
# accumulator resumes counting (the "stand up now" grace period).
NEXT_INTERVAL_FILE="${STATE_DIR}/next-interval-seconds"
GRACE_FILE="${STATE_DIR}/grace-seconds"

# Binaries
IOREG_BIN="/usr/sbin/ioreg"

# =========================================================
# FUNCTIONS
# =========================================================
function log_info() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] [INFO] $*" >>"${WATCHER_LOG}"
}

function log_error() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] [ERROR] $*" | tee -a "${WATCHER_LOG}" >&2
}

# Returns HIDIdleTime in whole seconds. Prints 0 on parse failure
# (fails open toward "active", not toward silently skipping breaks).
function get_idle_seconds() {
  local idle_ns
  idle_ns="$("${IOREG_BIN}" -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}')"

  if [[ -z "${idle_ns}" ]]; then
    log_error "Could not read HIDIdleTime from ioreg; assuming active."
    echo 0
    return
  fi

  # HIDIdleTime is nanoseconds; convert to whole seconds.
  echo $((idle_ns / 1000000000))
}

# Reads a single non-negative integer from a state file, falling back to the
# given default if the file is missing, empty, or not a plain integer.
function read_int_state_file() {
  local file_path="$1"
  local default_value="$2"
  local value

  if [[ ! -f "${file_path}" ]]; then
    echo "${default_value}"
    return
  fi

  value="$(<"${file_path}")"

  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${value}"
  else
    log_error "State file ${file_path} contained non-integer '${value}'; using default ${default_value}."
    echo "${default_value}"
  fi
}

function trigger_break_prompt() {
  local threshold_used="$1"
  log_info "Active threshold reached (${threshold_used}s). Triggering break prompt."
  if ! "${BREAK_PROMPT_SCRIPT}"; then
    log_error "break-prompt.sh exited non-zero."
  fi
}

# =========================================================
# MAIN EXECUTION
# =========================================================
function main() {
  mkdir -p "${STATE_DIR}"
  log_info "break-watcher started. Default threshold=${DEFAULT_ACTIVE_THRESHOLD_SECONDS}s Poll=${POLL_INTERVAL_SECONDS}s"

  local active_seconds=0
  local idle_seconds
  local active_threshold_seconds="${DEFAULT_ACTIVE_THRESHOLD_SECONDS}"
  local grace_remaining_seconds=0

  while true; do
    sleep "${POLL_INTERVAL_SECONDS}"

    idle_seconds="$(get_idle_seconds)"

    if ((idle_seconds >= IDLE_RESET_THRESHOLD_SECONDS)); then
      if ((active_seconds > 0)); then
        log_info "Idle detected (${idle_seconds}s). Resetting active accumulator from ${active_seconds}s."
      fi
      active_seconds=0

      # Idle time counts toward satisfying a pending grace period (e.g. after
      # "stand up now"), since idle is exactly the signal that grace exists to wait for.
      if ((grace_remaining_seconds > 0)); then
        grace_remaining_seconds=$((grace_remaining_seconds - POLL_INTERVAL_SECONDS))
        if ((grace_remaining_seconds < 0)); then
          grace_remaining_seconds=0
        fi
      fi
      continue
    fi

    # Still within a grace period: don't count this active time yet, and
    # don't let it erase the grace countdown either.
    if ((grace_remaining_seconds > 0)); then
      continue
    fi

    active_seconds=$((active_seconds + POLL_INTERVAL_SECONDS))

    if ((active_seconds >= active_threshold_seconds)); then
      trigger_break_prompt "${active_threshold_seconds}"
      active_seconds=0

      # Pick up whatever break-prompt.sh decided based on the user's choice.
      active_threshold_seconds="$(read_int_state_file "${NEXT_INTERVAL_FILE}" "${DEFAULT_ACTIVE_THRESHOLD_SECONDS}")"
      grace_remaining_seconds="$(read_int_state_file "${GRACE_FILE}" 0)"
      log_info "Next threshold=${active_threshold_seconds}s Grace=${grace_remaining_seconds}s"
    fi
  done
}

# Skip main when sourced (e.g., by bats tests loading function defs).
# Mirrors the guard in break-prompt.sh, smb-mount.sh, and the `ssh` wrapper.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
