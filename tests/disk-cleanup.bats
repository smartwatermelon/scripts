#!/usr/bin/env bats
# bats tests for disk-cleanup.sh
#
# Run from repo root:  bats tests/disk-cleanup.bats
#
# disk-cleanup.sh deletes caches, so these tests must never reach a real
# tool. Every external it calls is a *_BIN variable; setup() points each one
# at a stub in the per-test temp dir that records its argv to CALLS and
# exits with the code in <tool>.rc (default 0). A "missing" tool is a path
# that does not exist. DATA_VOLUME also points into the temp dir.
#
# The script itself never deletes a path (a guard test below checks this),
# so no test here can reach a real rm. The temp dir is BATS_TEST_TMPDIR,
# which bats creates and removes; this file has no rm either.
# Nothing here assumes macOS, so the suite runs on the ubuntu CI runner.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  TMPDIR_T="${BATS_TEST_TMPDIR:?bats 1.4 or later is required}"
  STUBS="${TMPDIR_T}/stubs"
  mkdir -p "${STUBS}"
  export CALLS="${TMPDIR_T}/calls"
  : >"${CALLS}"

  local tool
  for tool in npm uv xcrun df; do
    _stub "${tool}"
  done
  # df prints a fixed two-line block, as `df -Pk` does.
  cat >"${STUBS}/df" <<'EOF'
#!/usr/bin/env bash
echo "df $*" >>"${CALLS}"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3s5 482797652 300000000 41943040 88% /System/Volumes/Data"
EOF
  chmod +x "${STUBS}/df"

  # timeout stub: records its argv, then runs the wrapped command, so the
  # xcrun stub is still invoked through it.
  cat >"${STUBS}/timeout" <<'EOF'
#!/usr/bin/env bash
echo "timeout $*" >>"${CALLS}"
rc_file="$(dirname "$0")/timeout.rc"
if [[ -f "${rc_file}" ]]; then exit "$(cat "${rc_file}")"; fi
shift
exec "$@"
EOF
  chmod +x "${STUBS}/timeout"

  # Exported BEFORE sourcing: the script reads these as defaults at load
  # time, so even if the source guard regressed and main() ran, it would
  # reach only the stubs and the temp dir, never a real cache.
  export NPM_BIN="${STUBS}/npm"
  export UV_BIN="${STUBS}/uv"
  export XCRUN_BIN="${STUBS}/xcrun"
  export DF_BIN="${STUBS}/df"
  export TIMEOUT_BIN="${STUBS}/timeout"
  export SIMCTL_TIMEOUT_SECONDS=7
  export DATA_VOLUME="${TMPDIR_T}"

  # The source guard keeps main() from running when we load the functions.
  source "${REPO_ROOT}/disk-cleanup.sh"
}

# Writes a stub that appends "<name> <argv>" to CALLS and exits with the
# value in <name>.rc if that file exists.
_stub() {
  local name="$1"
  cat >"${STUBS}/${name}" <<EOF
#!/usr/bin/env bash
echo "${name} \$*" >>"\${CALLS}"
rc_file="\$(dirname "\$0")/${name}.rc"
if [[ -f "\${rc_file}" ]]; then exit "\$(cat "\${rc_file}")"; fi
exit 0
EOF
  chmod +x "${STUBS}/${name}"
}

_fail() {
  printf '%s\n' "${2:-1}" >"${STUBS}/$1.rc"
}

# ---------------------------------------------------------------------------
# Whole run
# ---------------------------------------------------------------------------

@test "a clean run calls every tool with the expected arguments and exits 0" {
  run main
  [ "${status}" -eq 0 ]
  grep -qx "npm cache clean --force" "${CALLS}"
  grep -qx "uv cache prune" "${CALLS}"
  grep -qx "xcrun simctl delete unavailable" "${CALLS}"
}

@test "free space is logged before and after, from DATA_VOLUME" {
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Free space before: 40 GiB (41943040 KiB) on ${TMPDIR_T}"* ]]
  [[ "${output}" == *"Free space after: 40 GiB"* ]]
  [ "$(grep -c "^df -Pk ${TMPDIR_T}\$" "${CALLS}")" -eq 2 ]
}

@test "log lines carry a timestamp" {
  run main
  [[ "${lines[0]}" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\]\ \[INFO\] ]]
}

@test "a df failure is logged but does not fail the run" {
  # Swap the fixed-output df for the generic stub, made to exit 1.
  _stub df
  _fail df
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"could not read df"* ]]
}

# ---------------------------------------------------------------------------
# Missing tools skip; they are not failures
# ---------------------------------------------------------------------------

@test "missing npm is a logged skip, not a failure" {
  NPM_BIN="${TMPDIR_T}/does-not-exist/npm"
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"npm: not found, skipping"* ]]
  grep -qx "uv cache prune" "${CALLS}"
}

@test "missing uv is a logged skip, not a failure" {
  UV_BIN="${TMPDIR_T}/does-not-exist/uv"
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"uv: not found, skipping"* ]]
}

@test "missing xcrun is a logged skip, not a failure (the Linux case)" {
  XCRUN_BIN=""
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"simctl: xcrun not found, skipping"* ]]
  [ "$(grep -c "^timeout" "${CALLS}")" -eq 0 ]
}

@test "missing df logs unknown free space, not a failure" {
  DF_BIN=""
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Free space before: unknown"* ]]
}

@test "every tool missing at once still exits 0" {
  NPM_BIN="" UV_BIN="" XCRUN_BIN="" DF_BIN="" TIMEOUT_BIN=""
  run main
  [ "${status}" -eq 0 ]
  [ ! -s "${CALLS}" ]
}

# ---------------------------------------------------------------------------
# Failure isolation
# ---------------------------------------------------------------------------

@test "a failing npm step does not stop the other steps, and the run exits 1" {
  _fail npm
  run main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"npm: cache clean failed"* ]]
  grep -qx "uv cache prune" "${CALLS}"
  grep -qx "xcrun simctl delete unavailable" "${CALLS}"
  [[ "${output}" == *"Free space after"* ]]
  [[ "${output}" == *"1 failed step(s)"* ]]
}

@test "two failing steps are both counted" {
  _fail uv
  _fail xcrun 3
  run main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"simctl: delete unavailable failed (exit 3)"* ]]
  [[ "${output}" == *"2 failed step(s)"* ]]
}

# ---------------------------------------------------------------------------
# simctl runs under timeout
# ---------------------------------------------------------------------------

@test "simctl is wrapped in timeout with SIMCTL_TIMEOUT_SECONDS" {
  run step_simctl
  [ "${status}" -eq 0 ]
  grep -qx "timeout 7 ${STUBS}/xcrun simctl delete unavailable" "${CALLS}"
  # The timeout call comes first: xcrun ran through it, not beside it.
  [ "$(head -n 1 "${CALLS}")" = "timeout 7 ${STUBS}/xcrun simctl delete unavailable" ]
}

@test "a simctl timeout (exit 124) is a failure that says it timed out" {
  _fail timeout 124
  run step_simctl
  [ "${status}" -eq "${STEP_FAILED}" ]
  [[ "${output}" == *"simctl: timed out after 7s"* ]]
}

@test "no timeout binary skips simctl rather than running it unbounded" {
  TIMEOUT_BIN=""
  run main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"timeout/gtimeout not found, skipping"* ]]
  [ "$(grep -c "xcrun" "${CALLS}")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Script shape
# ---------------------------------------------------------------------------

@test "the script never deletes or moves a path itself" {
  # Cache deletion belongs to the tool that owns the cache. A hand-written
  # rm -rf in this script removed ~40 apps from /Applications on
  # 2026-10-22. Comment lines are ignored; any code line that calls one of
  # these fails the test. The word boundaries are spelled out because \b
  # and [[:<:]] differ between BSD and GNU grep.
  run grep -nE '^([^#]*[^[:alnum:]_-])?(rm|rmdir|mv|unlink|shred)([^[:alnum:]_-]|$)|^[^#]*[[:space:]]-delete([^[:alnum:]_]|$)' \
    "${REPO_ROOT}/disk-cleanup.sh"
  [ "${status}" -eq 1 ]
}

@test "sourcing the script does not run main" {
  # setup() sourced it with every tool pointed at a recording stub; if the
  # guard regressed, main() would have run and CALLS would not be empty.
  [ "$(type -t main)" = "function" ]
  [ ! -s "${CALLS}" ]
}

@test "the default simctl timeout is a positive integer" {
  run env -u SIMCTL_TIMEOUT_SECONDS bash -c \
    "source '${REPO_ROOT}/disk-cleanup.sh'; echo \"\${SIMCTL_TIMEOUT_SECONDS}\""
  [[ "${output}" =~ ^[1-9][0-9]*$ ]]
}
