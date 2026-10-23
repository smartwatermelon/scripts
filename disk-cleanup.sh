#!/usr/bin/env bash
set -euo pipefail

# Weekly cache cleanup. Each tool deletes its own cache; never add rm here.
# Why: docs/plans/2026-10-22-disk-space-automation.md (Incident).

# Each tool is a variable so tests can stub it. Empty or not executable = missing.
NPM_BIN="${NPM_BIN:-$(command -v npm || true)}"
UV_BIN="${UV_BIN:-$(command -v uv || true)}"
XCRUN_BIN="${XCRUN_BIN:-$(command -v xcrun || true)}"
DF_BIN="${DF_BIN:-$(command -v df || true)}"

# simctl hung past 300 s unwrapped on 2026-10-22. timeout is from Homebrew
# coreutils; without it the step skips.
TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}"
SIMCTL_TIMEOUT_SECONDS="${SIMCTL_TIMEOUT_SECONDS:-120}"
SIMCTL_KILL_GRACE_SECONDS=10

# Free space is logged for the Data volume; / is the read-only system volume.
DATA_VOLUME="${DATA_VOLUME:-/System/Volumes/Data}"

# Step results.
STEP_OK=0
STEP_FAILED=1
STEP_SKIPPED=2

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

# Report only: a df failure is logged but never changes the exit status.
function log_free_space() {
  local label="$1"
  local avail_kib

  if ! have_tool "${DF_BIN}"; then
    log_info "Free space ${label}: unknown (df not found)"
    return 0
  fi

  # -P forces one line per filesystem on both macOS and Linux; Available is
  # field 4 in both.
  if ! avail_kib="$("${DF_BIN}" -Pk "${DATA_VOLUME}" 2>/dev/null | awk 'NR == 2 { print $4 }')" \
    || [[ ! "${avail_kib}" =~ ^[0-9]+$ ]]; then
    log_error "Free space ${label}: could not read df for ${DATA_VOLUME}"
    return 0
  fi

  log_info "Free space ${label}: $((avail_kib / 1024 / 1024)) GiB (${avail_kib} KiB) on ${DATA_VOLUME}"
}

function step_npm() {
  if ! have_tool "${NPM_BIN}"; then
    log_info "npm: not found, skipping"
    return "${STEP_SKIPPED}"
  fi
  log_info "npm: cache clean --force"
  if ! "${NPM_BIN}" cache clean --force; then
    log_error "npm: cache clean failed"
    return "${STEP_FAILED}"
  fi
  return "${STEP_OK}"
}

# `prune`, not `clean`: prune keeps cache entries still in use.
function step_uv() {
  if ! have_tool "${UV_BIN}"; then
    log_info "uv: not found, skipping"
    return "${STEP_SKIPPED}"
  fi
  log_info "uv: cache prune"
  if ! "${UV_BIN}" cache prune; then
    log_error "uv: cache prune failed"
    return "${STEP_FAILED}"
  fi
  return "${STEP_OK}"
}

function step_simctl() {
  if ! have_tool "${XCRUN_BIN}"; then
    log_info "simctl: xcrun not found, skipping"
    return "${STEP_SKIPPED}"
  fi
  if ! have_tool "${TIMEOUT_BIN}"; then
    log_info "simctl: timeout/gtimeout not found, skipping rather than running simctl unbounded"
    return "${STEP_SKIPPED}"
  fi
  log_info "simctl: delete unavailable (timeout ${SIMCTL_TIMEOUT_SECONDS}s, kill after ${SIMCTL_KILL_GRACE_SECONDS}s grace)"
  local rc=0
  "${TIMEOUT_BIN}" -k "${SIMCTL_KILL_GRACE_SECONDS}s" "${SIMCTL_TIMEOUT_SECONDS}" "${XCRUN_BIN}" simctl delete unavailable || rc=$?
  if ((rc == 124)); then
    log_error "simctl: timed out after ${SIMCTL_TIMEOUT_SECONDS}s"
    return "${STEP_FAILED}"
  elif ((rc == 137)); then
    # 137 is SIGKILL: from timeout -k, or from outside (OOM). GNU timeout gives 137 for both.
    log_error "simctl: killed (exit 137): timed out after ${SIMCTL_TIMEOUT_SECONDS}s and ignored SIGTERM for ${SIMCTL_KILL_GRACE_SECONDS}s, or killed from outside"
    return "${STEP_FAILED}"
  elif ((rc != 0)); then
    log_error "simctl: delete unavailable failed (exit ${rc})"
    return "${STEP_FAILED}"
  fi
  return "${STEP_OK}"
}

# =========================================================
# MAIN EXECUTION
# =========================================================
function main() {
  local failures=0 rc step

  log_info "disk-cleanup started"
  log_free_space "before"

  for step in step_npm step_uv step_simctl; do
    rc=0
    "${step}" || rc=$?
    if ((rc == STEP_FAILED)); then
      ((failures += 1))
    fi
  done

  log_free_space "after"

  if ((failures > 0)); then
    log_error "disk-cleanup finished with ${failures} failed step(s)"
    return 1
  fi
  log_info "disk-cleanup finished"
  return 0
}

# Skip main when sourced (e.g., by bats tests loading function defs).
# Mirrors the guard in break-watcher.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
