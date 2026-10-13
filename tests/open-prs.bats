#!/usr/bin/env bats
# bats tests for open-prs.sh
#
# Run from repo root:  bats tests/open-prs.bats
#
# open-prs.sh shells out to `gh search prs` and `jq`. The tests stub `gh` on
# PATH so no network call happens and the fixture payload is deterministic;
# `jq` is left real, because the filter and render expressions ARE the logic
# under test and stubbing jq would test nothing.
#
# On a machine with ~/.config/bash/gh-wrapper.sh installed, the stub is reached
# THROUGH that wrapper rather than directly -- BASH_ENV sources the wrapper's
# `gh` function into every non-interactive bash, and a shell function beats any
# PATH executable. The wrapper then resolves the real `gh` by scanning PATH,
# which finds this stub. That is fine as long as the wrapper passes straight
# through; see setup() for the one case where it does not.

# `run --separate-stderr` needs 1.5.0+; declaring it turns the BW02 warning
# into a hard version check instead of a silent behavior difference.
bats_require_minimum_version 1.5.0

setup() {
  # With GH_TOKEN set, gh-wrapper.sh runs an identity preflight before handing
  # off: it calls `<real gh> api user --jq .login` and requires the output to
  # match ^[A-Za-z0-9-]+$. Its "real gh" is found by scanning PATH, so it finds
  # the stub below, which answers every invocation with the PR payload -- `[`
  # fails the login regex, the wrapper refuses to run, and open-prs.sh exits 1
  # before its own logic executes. Unsetting the token skips that preflight, so
  # the suite tests open-prs.sh instead of the developer's auth shape. This is
  # why the suite passed in CI (no wrapper installed there) while failing 15/25
  # locally -- smartwatermelon/scripts#177.
  unset GH_TOKEN

  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${REPO_ROOT}/open-prs.sh"
  TMPDIR_T="$(mktemp -d)"
  mkdir -p "${TMPDIR_T}/bin"

  # Two repos, three PRs: one human, one is_bot-flagged, one dependabot login
  # that is NOT flagged (the case the login regex exists to catch).
  cat >"${TMPDIR_T}/payload.json" <<'JSON'
[
  {"repository":{"nameWithOwner":"o/alpha"},"number":1,"title":"human pr",
   "author":{"is_bot":false,"login":"andrewrich"},"url":"https://x/1"},
  {"repository":{"nameWithOwner":"o/alpha"},"number":2,"title":"flagged bot",
   "author":{"is_bot":true,"login":"someapp"},"url":"https://x/2"},
  {"repository":{"nameWithOwner":"o/beta"},"number":3,"title":"unflagged dependabot",
   "author":{"is_bot":false,"login":"dependabot[bot]"},"url":"https://x/3"}
]
JSON

  cat >"${TMPDIR_T}/bin/gh" <<EOF
#!/usr/bin/env bash
# Record argv so tests can assert on what the script asked gh for.
printf '%s\n' "\$@" >"${TMPDIR_T}/gh-args"
cat "${TMPDIR_T}/payload.json"
EOF
  chmod +x "${TMPDIR_T}/bin/gh"
}

teardown() {
  rm -rf "${TMPDIR_T}"
}

run_script() {
  PATH="${TMPDIR_T}/bin:${PATH}" run "${SCRIPT}" "$@"
}

# Same, but keeps stdout and stderr apart. Error-path tests use this so they
# assert on the stream the message was actually written to -- with the merged
# default, a diagnostic wrongly sent to stdout would still pass.
run_script_split() {
  PATH="${TMPDIR_T}/bin:${PATH}" run --separate-stderr "${SCRIPT}" "$@"
}

# ---------------------------------------------------------------- help text

# The regression this pins: help was `sed -n '2,16p'`, a hardcoded range whose
# line 16 had drifted onto `set -euo pipefail`. Any code line in help output
# means the sentinel broke.
@test "help prints the usage block and no shell code" {
  run_script --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--mine"* ]]
  [[ "${output}" == *"--limit"* ]]
  [[ "${output}" != *"set -euo"* ]]
  [[ "${output}" != *"OWNERS="* ]]
}

@test "help stops at the first non-comment line" {
  run_script --help
  # Guard the loop: with empty output the body never runs and the test would
  # pass vacuously.
  [ -n "${output}" ]
  # Every emitted line must still be a comment.
  while IFS= read -r line; do
    [[ "${line}" == "#"* ]]
  done <<<"${output}"
}

@test "help survives inserting a line into the usage block" {
  cp "${SCRIPT}" "${TMPDIR_T}/probe.sh"
  # Add a comment line inside the block; a hardcoded range would drop the tail.
  sed -i.bak '3i\
#   --newflag    an added line
' "${TMPDIR_T}/probe.sh"
  PATH="${TMPDIR_T}/bin:${PATH}" run bash "${TMPDIR_T}/probe.sh" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--newflag"* ]]
  # The last line of the block must still be present, not truncated away.
  [[ "${output}" == *"returns real PR fields"* ]]
  [[ "${output}" != *"set -euo"* ]]
}

# ------------------------------------------------------- mutual exclusion

@test "--mine and --bots are rejected together" {
  run_script_split --mine --bots
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"cannot combine"* ]]
  [[ "${output}" != *"cannot combine"* ]]
}

@test "--count and --urls are rejected together" {
  run_script_split --count --urls
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"cannot combine"* ]]
  [[ "${output}" != *"cannot combine"* ]]
}

@test "repeating the same flag is allowed" {
  run_script --mine --mine
  [ "${status}" -eq 0 ]
}

@test "unknown flags are rejected" {
  run_script_split --bogus
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"unknown flag"* ]]
  [[ "${output}" != *"unknown flag"* ]]
}

# ------------------------------------------------------------ composition

# The core defect: a single `mode` variable meant --mine --count silently
# dropped --mine. Filter and render must now apply together.
@test "--mine --count composes: bots excluded from the counts" {
  run_script --mine --count
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"o/alpha: 1"* ]]
  # beta held only an unflagged dependabot PR, so it drops out entirely.
  [[ "${output}" != *"o/beta"* ]]
}

@test "--bots --count composes: only bot PRs counted" {
  run_script --bots --count
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"o/alpha: 1"* ]]
  [[ "${output}" == *"o/beta: 1"* ]]
}

@test "--count alone counts every PR" {
  run_script --count
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"o/alpha: 2"* ]]
  [[ "${output}" == *"o/beta: 1"* ]]
}

@test "--mine --urls composes: URLs shown, bots excluded" {
  run_script --mine --urls
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"https://x/1"* ]]
  [[ "${output}" != *"https://x/2"* ]]
  [[ "${output}" != *"https://x/3"* ]]
}

# --------------------------------------------------------- bot detection

@test "an unflagged dependabot login is still treated as a bot" {
  run_script --mine
  [ "${status}" -eq 0 ]
  # PR 3's author is is_bot:false; only the login regex can exclude it.
  [[ "${output}" != *"unflagged dependabot"* ]]
}

@test "is_bot-flagged authors are excluded by --mine" {
  run_script --mine
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"flagged bot"* ]]
  [[ "${output}" == *"human pr"* ]]
}

# --------------------------------------------------------------- --limit

@test "--limit rejects zero" {
  run_script_split --limit 0
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"positive integer"* ]]
  [[ "${output}" != *"positive integer"* ]]
}

@test "--limit rejects non-numeric values" {
  run_script_split --limit abc
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"positive integer"* ]]
  [[ "${output}" != *"positive integer"* ]]
}

@test "--limit rejects a missing value" {
  run_script_split --limit
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"needs a number"* ]]
  [[ "${output}" != *"needs a number"* ]]
}

@test "--limit rejects values above gh's 1000 ceiling" {
  run_script_split --limit 1001
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"cannot exceed 1000"* ]]
}

@test "--limit accepts exactly the ceiling" {
  run_script --limit 1000
  [ "${status}" -eq 0 ]
}

@test "--limit is forwarded to gh" {
  run_script --limit 7
  [ "${status}" -eq 0 ]
  grep -qx -- "7" "${TMPDIR_T}/gh-args"
}

@test "the default limit is forwarded when --limit is absent" {
  run_script
  [ "${status}" -eq 0 ]
  grep -qx -- "200" "${TMPDIR_T}/gh-args"
}

# The ceiling warning must fire only on a real truncation, go to stderr, and
# never change the exit status.
@test "hitting the limit ceiling warns on stderr but still exits 0" {
  PATH="${TMPDIR_T}/bin:${PATH}" run --separate-stderr "${SCRIPT}" --limit 3
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"truncated"* ]]
  [[ "${output}" != *"truncated"* ]]
}

# Pins the `>=` in the ceiling check. With `>` the warning is unreachable,
# since the count can never exceed the limit gh was handed.
@test "an exactly-full result set still warns" {
  PATH="${TMPDIR_T}/bin:${PATH}" run --separate-stderr "${SCRIPT}" --limit 3
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"truncated"* ]]
}

@test "a result below the ceiling produces no warning" {
  PATH="${TMPDIR_T}/bin:${PATH}" run --separate-stderr "${SCRIPT}" --limit 99
  [ "${status}" -eq 0 ]
  [ -z "${stderr}" ]
}

# ------------------------------------------------------------- gh contract

# `--archived false` parses as a bare boolean plus a stray search term, which
# matches nothing and exits 0 -- a silent empty result. The equals form is
# load-bearing, so pin it.
@test "gh is called with the equals form of --archived" {
  run_script
  [ "${status}" -eq 0 ]
  grep -qx -- "--archived=false" "${TMPDIR_T}/gh-args"
  ! grep -qx -- "--archived" "${TMPDIR_T}/gh-args"
}

@test "every configured owner is passed to gh" {
  run_script
  [ "${status}" -eq 0 ]
  grep -qx -- "smartwatermelon" "${TMPDIR_T}/gh-args"
  grep -qx -- "nightowlstudiollc" "${TMPDIR_T}/gh-args"
}
