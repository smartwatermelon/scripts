#!/usr/bin/env bash
set -euo pipefail

# Two-way sync of ~/.local/state/claude-handoffs with Drive "Claude Handoff". TILSIT cron, every 5 min: no GUI there for a LaunchAgent.

# Auth errors in the log: rclone's shared client_id is likely retired. Fix with: rclone config reconnect gdrive:

# Full path, not command -v: cron's PATH lacks /opt/homebrew/bin. Tests stub it; empty or non-executable = missing.
RCLONE_BIN="${RCLONE_BIN:-/opt/homebrew/bin/rclone}"

# Not under ~/.claude: the Claude Code sandbox denies writes there, so a skill could not save a handoff (claude-config#779).

# After moving this dir, run bisync once by hand with --resync: rclone keys its sync state on the path pair.
HANDOFF_LOCAL_DIR="${HANDOFF_LOCAL_DIR:-${HOME}/.local/state/claude-handoffs}"
HANDOFF_REMOTE="${HANDOFF_REMOTE:-gdrive:Claude Handoff}"
HANDOFF_LOG_DIR="${HANDOFF_LOG_DIR:-${HOME}/.local/state/rclone}"

# Above this many lines the log is cut back to its last LOG_KEEP_LINES.
LOG_MAX_LINES=2000
LOG_KEEP_LINES=1000

# =========================================================
# FUNCTIONS
# =========================================================
function log_error() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] [ERROR] $*" >&2
}

# True when $1 names an executable file. An empty value is "missing".
function have_tool() {
  [[ -n "${1:-}" && -x "${1}" ]]
}

function trim_log() {
  local log_file="$1" log_lines

  [[ -f "${log_file}" ]] || return 0
  log_lines=$(wc -l <"${log_file}")
  if [[ "${log_lines}" -gt "${LOG_MAX_LINES}" ]]; then
    tail -n "${LOG_KEEP_LINES}" "${log_file}" >"${log_file}.tmp" && mv "${log_file}.tmp" "${log_file}"
  fi
}

# =========================================================
# MAIN EXECUTION
# =========================================================
function main() {
  local log_file="${HANDOFF_LOG_DIR}/handoff-sync.log"

  mkdir -p "${HANDOFF_LOCAL_DIR}" "${HANDOFF_LOG_DIR}"
  trim_log "${log_file}"

  # cron discards stdout and stderr, so the log file is the only record.
  if ! have_tool "${RCLONE_BIN}"; then
    log_error "rclone not found at '${RCLONE_BIN}'" 2>>"${log_file}"
    return 1
  fi

  # --resilient/--recover: retry after a transient failure instead of
  # demanding a manual --resync. --max-lock: a crashed run's lock expires.
  "${RCLONE_BIN}" bisync "${HANDOFF_LOCAL_DIR}" "${HANDOFF_REMOTE}" \
    --drive-skip-gdocs \
    --create-empty-src-dirs \
    --resilient --recover --max-lock 10m \
    --log-level NOTICE \
    --log-file "${log_file}"
}

# Skip main when sourced (e.g., by bats tests loading function defs).
# Mirrors the guard in break-watcher.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
