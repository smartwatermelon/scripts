#!/usr/bin/env bash
# tm-caffeinate.sh — Keep the machine awake while Time Machine is backing up.
#
# Designed to run periodically via LaunchAgent. On each invocation:
#   - If no backup is running, exits immediately.
#   - If a backup is running, re-execs under caffeinate and polls until
#     the backup completes, then exits.
#
# launchd will not start a new instance while the previous one is still
# running, so no lock file is needed.
#
# Note: caffeinate -s only prevents system sleep on AC power. On battery,
# macOS may still sleep during backups to preserve battery life.
#
# Author: Andrew Rich

set -euo pipefail

readonly POLL_INTERVAL="${1:-60}"
readonly _LOG_FILE="${HOME}/.local/state/tm-caffeinate.log"
readonly _LOG_MAX_BYTES=102400
readonly _MAX_CONSECUTIVE_FAILURES=5

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S') || ts="unknown"
  printf '%s [tm-caffeinate] %s\n' "${ts}" "$1"
}

# Trim log to last 1000 lines if it exceeds ~100KB.
_maybe_trim_log() {
  [[ -f "${_LOG_FILE}" ]] || return 0
  # `stat` is not portable: BSD/macOS spells size `-f%z`, GNU/Linux spells
  # it `-c%s`, and GNU's `-f` means *filesystem* info. Try BSD first, then
  # GNU, and validate the result is numeric before comparing.
  local size=""
  size=$(stat -f%z "${_LOG_FILE}" 2>/dev/null) || size=""
  [[ "${size}" =~ ^[0-9]+$ ]] || size=$(stat -c%s "${_LOG_FILE}" 2>/dev/null) || size=""
  [[ "${size}" =~ ^[0-9]+$ ]] || return 0
  if ((size > _LOG_MAX_BYTES)); then
    # Not `A && B || true`: that masks a failing mv and leaves the .tmp
    # behind. Trim is best-effort, so a failure at either step just cleans
    # up and moves on.
    if tail -1000 "${_LOG_FILE}" >"${_LOG_FILE}.tmp" 2>/dev/null; then
      mv -f "${_LOG_FILE}.tmp" "${_LOG_FILE}" 2>/dev/null || rm -f "${_LOG_FILE}.tmp"
    else
      rm -f "${_LOG_FILE}.tmp"
    fi
  fi
}

# Returns 0 (true) if Time Machine is actively backing up.
tm_is_running() {
  local phase
  phase=$(tmutil currentphase 2>/dev/null) || return 1
  [[ "${phase}" != "BackupNotRunning" ]]
}

# Returns the current Time Machine phase for logging.
tm_phase() {
  tmutil currentphase 2>/dev/null || echo "unknown"
}

mkdir -p "$(dirname "${_LOG_FILE}")"
_maybe_trim_log

# Re-open stdout/stderr to the (possibly rotated) log file so output
# after a trim lands in the right place.
exec >>"${_LOG_FILE}" 2>&1 || true

# Quick check — exit immediately if TM is idle.
if ! tm_is_running; then
  exit 0
fi

# Re-exec under caffeinate if not already wrapped.
# caffeinate -i -s prevents idle and system sleep.
# When this process exits, caffeinate releases its assertions automatically.
if [[ -z "${_TM_CAFFEINATED:-}" ]]; then
  phase=$(tm_phase)
  log "Time Machine backup detected (phase: ${phase}). Asserting caffeinate."
  export _TM_CAFFEINATED=1
  exec caffeinate -i -s "$0" "$@"
fi

# --- Running under caffeinate from here ---

fail_count=0
while true; do
  phase=$(tm_phase)
  if [[ "${phase}" == "BackupNotRunning" || -z "${phase}" ]]; then
    break
  fi
  if [[ "${phase}" == "unknown" ]]; then
    ((fail_count += 1))
    if ((fail_count >= _MAX_CONSECUTIVE_FAILURES)); then
      log "tmutil failed ${fail_count} consecutive times. Releasing caffeinate."
      break
    fi
    log "tmutil returned unknown (${fail_count}/${_MAX_CONSECUTIVE_FAILURES}) — retrying..."
  else
    fail_count=0
  fi
  log "Backup phase: ${phase} — keeping awake..."
  sleep "${POLL_INTERVAL}"
done

log "Backup finished. Releasing caffeinate."
