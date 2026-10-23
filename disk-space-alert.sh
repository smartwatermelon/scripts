#!/usr/bin/env bash
set -euo pipefail

# Daily low-disk alert. Posts a notification; deletes nothing.
# Why: docs/plans/2026-10-22-disk-space-automation.md

# Each tool is a variable so tests can stub it. Empty or not executable = missing.
DF_BIN="${DF_BIN:-$(command -v df || true)}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-/usr/bin/osascript}"

# Free space is read for the Data volume; / is the read-only system volume.
DATA_VOLUME="${DATA_VOLUME:-/System/Volumes/Data}"

# 40, not 50: the snapshot thinner targets 50 GiB and clears that on its own.
DEFAULT_THRESHOLD_GIB=40

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

# True when $1 names an executable file. An empty value is "missing".
function have_tool() {
  [[ -n "${1:-}" && -x "${1}" ]]
}

# Prints whole GiB free on DATA_VOLUME, rounded down. Returns 1 if unknown.
function free_gib() {
  local avail_kib

  have_tool "${DF_BIN}" || return 1
  # -P forces one line per filesystem on both macOS and Linux; Available is
  # field 4 in both.
  avail_kib="$("${DF_BIN}" -Pk "${DATA_VOLUME}" 2>/dev/null | awk 'NR == 2 { print $4 }')" || return 1
  [[ "${avail_kib}" =~ ^[0-9]+$ ]] || return 1
  echo "$((avail_kib / 1024 / 1024))"
}

# The title and message go in as argv, never into the AppleScript source, so
# no value can change the script.
function notify() {
  local title="$1" message="$2"

  if ! have_tool "${OSASCRIPT_BIN}"; then
    log_error "osascript not found; could not post: ${title}: ${message}"
    return 1
  fi
  if ! "${OSASCRIPT_BIN}" \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' \
    "${message}" "${title}"; then
    log_error "osascript failed; could not post: ${title}: ${message}"
    return 1
  fi
}

# =========================================================
# MAIN EXECUTION
# =========================================================
function main() {
  local threshold="${1:-${DEFAULT_THRESHOLD_GIB}}" free

  if [[ ! "${threshold}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "threshold must be a whole number of GiB above 0, got '${threshold}'"
    return 2
  fi

  # An alert that fails silently is worse than none, so an unreadable
  # volume is reported too.
  if ! free="$(free_gib)"; then
    log_error "could not read free space on ${DATA_VOLUME}"
    notify "Disk space check failed" "Could not read free space on ${DATA_VOLUME}." || true
    return 1
  fi

  if ((free < threshold)); then
    log_info "LOW: ${free} GiB free on ${DATA_VOLUME}, below ${threshold} GiB"
    notify "Low disk space" "${free} GiB free on ${DATA_VOLUME} (alert below ${threshold} GiB)." || return 1
    return 0
  fi

  log_info "OK: ${free} GiB free on ${DATA_VOLUME} (threshold ${threshold} GiB)"
}

# Skip main when sourced (e.g., by bats tests loading function defs).
# Mirrors the guard in break-watcher.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
