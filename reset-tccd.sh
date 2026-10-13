#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# CONFIGURATION
# =========================================================
# Timing configuration
readonly TCCD_MAX_WAIT_TIME=120
readonly TCCD_INIT_WAIT=10

# Logging configuration
readonly LOG_DIR="${HOME}/.local/state"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
readonly SCRIPT_NAME

# =========================================================
# FUNCTIONS
# =========================================================
# Import notification and utility functions
if [[ -f "${HOME}/.config/bash/functions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.config/bash/functions.sh"
else
  # Fallback notification function
  _notif() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] $*"
  }

  # Fallback script name function
  _what_is_this() {
    export THIS="${SCRIPT_NAME}"
  }
fi

# Set up logging with fallback
setup_logging() {
  _what_is_this

  # Ensure log directory exists
  [[ -d "${LOG_DIR}" ]] || mkdir -p "${LOG_DIR}"

  exec 3>&1 4>&2
  trap 'exec 2>&4 1>&3' 0 1 2 3
  exec 1>>"${LOG_DIR}/${THIS}.out" 2>&1

  local start_ts
  start_ts="$(date)"
  echo "${start_ts}: Script started"
}

# Kill process and wait for respawn
kill_and_wait_for_respawn() {
  local process_name="$1"
  local max_wait_time="$2"
  local matching_processes

  # Get count of matching processes
  matching_processes=$(pgrep -fl "${process_name}" | wc -l | xargs)
  if [[ ${matching_processes} -lt 1 ]]; then
    _notif "No processes matching '${process_name}' found."
    return 0
  fi

  _notif "Killing ${process_name}..."

  # Kill the process forcefully
  pkill -9 -fl "${process_name}" 2>/dev/null || true

  # Wait for the process to respawn
  local start_time
  start_time=$(date +%s)

  _notif "Waiting for ${process_name} to respawn..."
  while true; do
    local current_processes
    current_processes=$(pgrep -fl "${process_name}" | wc -l | xargs)

    if [[ ${current_processes} -ge ${matching_processes} ]]; then
      _notif "${process_name} has respawned successfully"
      break
    fi

    local now
    now="$(date +%s)"
    if ((now - start_time >= max_wait_time)); then
      _notif "Timeout waiting for ${process_name} to respawn after ${max_wait_time}s"
      return 1
    fi

    sleep 2
  done

  # Show new process details
  _notif "New ${process_name} processes:"
  pgrep -fl "${process_name}" | while read -r line; do
    _notif "  ${line}"
  done
}

# Reset tccd (Transparency, Consent, and Control daemon)
reset_tccd() {
  _notif "Starting tccd reset..."

  # Kill and wait for tccd to respawn
  if kill_and_wait_for_respawn "tccd" "${TCCD_MAX_WAIT_TIME}"; then
    _notif "Waiting ${TCCD_INIT_WAIT}s for tccd to fully initialize..."
    sleep "${TCCD_INIT_WAIT}"
    _notif "tccd reset completed successfully"
    return 0
  else
    _notif "tccd reset failed - process did not respawn properly"
    return 1
  fi
}

# Display usage information
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Reset macOS tccd (Transparency, Consent, and Control daemon) to refresh
privacy permissions and resolve permission-related issues.

OPTIONS:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose logging output

DESCRIPTION:
    This script forcefully restarts the tccd daemon, which manages privacy
    permissions for applications. This can resolve issues with:
    - App permission dialogs not appearing
    - Apps losing previously granted permissions
    - Privacy settings not taking effect

    The script waits for tccd to fully restart before completing.

EXAMPLES:
    $(basename "$0")              # Reset tccd with default settings
    $(basename "$0") --verbose    # Reset with verbose output

EOF
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        show_usage
        exit 0
        ;;
      -v | --verbose)
        set -x
        shift
        ;;
      *)
        echo "Error: Unknown option '$1'" >&2
        echo "Use --help for usage information" >&2
        exit 1
        ;;
    esac
  done
}

# Main execution function
main() {
  parse_arguments "$@"
  setup_logging

  _notif "Starting tccd reset process..."

  if reset_tccd; then
    _notif "tccd reset completed successfully!"
    local finish_ts
    finish_ts="$(date)"
    echo "${finish_ts}: Script finished successfully"
    exit 0
  else
    _notif "tccd reset failed!"
    local finish_ts
    finish_ts="$(date)"
    echo "${finish_ts}: Script finished with errors"
    exit 1
  fi
}

# =========================================================
# MAIN EXECUTION
# =========================================================
main "$@"
