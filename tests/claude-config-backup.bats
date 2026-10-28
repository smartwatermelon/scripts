#!/usr/bin/env bats
# bats tests for claude-config-backup.sh: host label, company-machine refusal,
# layout migration, tracked files and the push step.
#
# Run from repo root:  bats tests/claude-config-backup.bats
#
# Hermetic. Every path the script touches is under BATS_TEST_TMPDIR:
#   - REPO is ${XDG_DATA_HOME}/claude-config-backup, and XDG_DATA_HOME is set
#     to the temp dir, so the real backup clone is never reached.
#   - TRACKED sources are under ${HOME}, and HOME is the temp dir, so no real
#     Claude config is read. CLAUDE_MACHINE_SETTINGS is cleared from the
#     ambient environment for the same reason.
#   - origin is a temp bare repo; "elsewhere" is a second temp clone that
#     plays the part of the fleet rollout that pushed to the remote.
#   - gitleaks is a stub that finds nothing. stat is a stub that prints a
#     constant, because the script uses BSD `stat -f` and CI runs on Linux,
#     where `stat -f` means filesystem status and drifts between samples.
#   - hostname and id are stubs that print STUBS/hostname.out and
#     STUBS/user.out, so the host label and the arich-mac check never depend
#     on the machine running the tests. run_backup sets
#     CLAUDE_CONFIG_BACKUP_HOST from BACKUP_HOST (default ASIAGO).
#   - GIT_CONFIG_GLOBAL points at a temp file and GIT_CONFIG_NOSYSTEM=1, so
#     no global hooksPath, template dir, or identity leaks into the fixtures.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  TMPDIR_T="${BATS_TEST_TMPDIR:?bats 1.4 or later is required}"
  SCRIPT="${REPO_ROOT}/claude-config-backup.sh"

  export GIT_CONFIG_GLOBAL="${TMPDIR_T}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --file "${GIT_CONFIG_GLOBAL}" user.name "Backup Test"
  git config --file "${GIT_CONFIG_GLOBAL}" user.email "backup-test@example.invalid"
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" advice.detachedHead false

  STUBS="${TMPDIR_T}/stubs"
  mkdir -p "${STUBS}"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${STUBS}/gitleaks"
  printf '#!/usr/bin/env bash\necho 1:1\n' >"${STUBS}/stat"
  # hostname prints STUBS/hostname.out, and fails when it is absent.
  printf '#!/usr/bin/env bash\ncat "%s/hostname.out" 2>/dev/null\n' "${STUBS}" >"${STUBS}/hostname"
  # id prints STUBS/user.out (the script only calls `id -un`).
  printf '#!/usr/bin/env bash\ncat "%s/user.out"\n' "${STUBS}" >"${STUBS}/id"
  # A git stand-in for GIT_BIN: records its arguments and changes nothing.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/git-mv.calls"\nexit 1\n' "${STUBS}" >"${STUBS}/fake-git"
  chmod +x "${STUBS}/gitleaks" "${STUBS}/stat" "${STUBS}/hostname" "${STUBS}/id" "${STUBS}/fake-git"
  echo "testhost" >"${STUBS}/hostname.out"
  echo "tester" >"${STUBS}/user.out"
  BACKUP_HOST="ASIAGO"

  T_HOME="${TMPDIR_T}/home"
  T_DATA="${TMPDIR_T}/data"
  SRC="${T_HOME}/.claude/.claude.json"
  SRC_MS="${T_HOME}/.config/claude-code/machine-settings.json"
  mkdir -p "${T_HOME}/.claude" "${T_HOME}/.config/claude-code" "${T_DATA}"

  # origin with one commit that already holds ASIAGO/cli/claude.json.
  use_origin "base" "ASIAGO/cli/claude.json"
}

# Points ORIGIN, ELSEWHERE and CLONE at a fresh set named <name>: a bare
# origin with one commit holding each given path, and two clones of it.
# CLONE is always ${T_DATA}/claude-config-backup, the path the script uses.
use_origin() {
  local name="$1" path
  shift
  ORIGIN="${TMPDIR_T}/${name}-origin.git"
  ELSEWHERE="${TMPDIR_T}/${name}-elsewhere"
  CLONE="${T_DATA}/claude-config-backup"
  if [[ -e "${CLONE}" ]]; then
    # Park the previous clone under the temp dir instead of deleting it.
    mv "${CLONE}" "${TMPDIR_T}/parked-clone-before-${name}"
  fi
  git init --quiet --bare -b main "${ORIGIN}"
  git clone --quiet "${ORIGIN}" "${ELSEWHERE}" 2>/dev/null
  for path in "$@"; do
    mkdir -p "$(dirname "${ELSEWHERE}/${path}")"
    echo '{"v": 0}' >"${ELSEWHERE}/${path}"
    git -C "${ELSEWHERE}" add -- "${path}"
  done
  git -C "${ELSEWHERE}" commit --quiet -m "initial"
  git -C "${ELSEWHERE}" push --quiet origin main
  git clone --quiet "${ORIGIN}" "${CLONE}"
}

# Runs the script with every input pointed into the temp dir. Extra
# NAME=value arguments are passed to env before the script.
run_backup() {
  run env -u CLAUDE_MACHINE_SETTINGS -u GIT_BIN \
    HOME="${T_HOME}" XDG_DATA_HOME="${T_DATA}" TMPDIR="${TMPDIR_T}" \
    CLAUDE_CONFIG_BACKUP_HOST="${BACKUP_HOST}" \
    SETTLE_SECONDS=0 PATH="${STUBS}:${PATH}" "$@" bash "${SCRIPT}"
}

# Adds a commit to origin from the other clone, as the fleet rollout did.
remote_commit() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "${ELSEWHERE}/${path}")"
  printf '%s\n' "${content}" >"${ELSEWHERE}/${path}"
  git -C "${ELSEWHERE}" add -- "${path}"
  git -C "${ELSEWHERE}" commit --quiet -m "elsewhere: ${path}"
  git -C "${ELSEWHERE}" push --quiet origin main
}

# --- push step ---------------------------------------------------------------

@test "a normal push succeeds and says so" {
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pushed to origin"* ]]
  [[ "${output}" != *"rebas"* ]]
  [ "$(git -C "${ORIGIN}" rev-parse main)" = "$(git -C "${CLONE}" rev-parse HEAD)" ]
}

@test "a remote commit we lack is rebased onto, then the push succeeds" {
  remote_commit ".github/workflows/standards-check.yml" "name: stub"
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"push rejected, remote has commits we lack; rebasing onto origin/main"* ]]
  [[ "${output}" == *"pushed to origin after rebase"* ]]
  # initial + elsewhere + ours
  [ "$(git -C "${ORIGIN}" rev-list --count main)" -eq 3 ]
  git -C "${ORIGIN}" cat-file -e main:.github/workflows/standards-check.yml
  [ "$(git -C "${ORIGIN}" show main:ASIAGO/cli/claude.json)" = '{"v": 1}' ]
  [ "$(git -C "${ORIGIN}" rev-parse main)" = "$(git -C "${CLONE}" rev-parse HEAD)" ]
}

@test "a conflicting remote commit aborts the rebase and keeps local commits" {
  remote_commit "ASIAGO/cli/claude.json" '{"v": "remote"}'
  remote_head="$(git -C "${ORIGIN}" rev-parse main)"
  before="$(git -C "${CLONE}" rev-list --count HEAD)"
  echo '{"v": "local"}' >"${SRC}"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: rebase onto origin/main conflicted (CONFLICT"*"ASIAGO/cli/claude.json"* ]]
  [[ "${output}" == *"local commits are intact"* ]]
  [[ "${output}" == *"Fix by hand: git -C '${CLONE}' pull --rebase origin main"* ]]
  # Our commit is still there, on top of what we had; nothing was dropped.
  [ "$(git -C "${CLONE}" rev-list --count HEAD)" -eq $((before + 1)) ]
  [ "$(git -C "${CLONE}" show HEAD:ASIAGO/cli/claude.json)" = '{"v": "local"}' ]
  [ "$(git -C "${CLONE}" symbolic-ref --short HEAD)" = "main" ]
  [ ! -d "$(git -C "${CLONE}" rev-parse --git-path rebase-merge)" ]
  [ ! -d "$(git -C "${CLONE}" rev-parse --git-path rebase-apply)" ]
  [ -z "$(git -C "${CLONE}" status --porcelain)" ]
  # No force-push: the remote is exactly where it was.
  [ "$(git -C "${ORIGIN}" rev-parse main)" = "${remote_head}" ]
}

@test "any other push failure warns with git's error and does not rebase" {
  git -C "${CLONE}" remote set-url origin "${TMPDIR_T}/does-not-exist.git"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"WARN: push failed (fatal: "*"); commit is safe locally, will retry next run"* ]]
  [[ "${output}" != *"rebas"* ]]
  [ "$(git -C "${CLONE}" rev-list --count HEAD)" -eq 2 ]
  [ "$(git -C "${CLONE}" rev-parse HEAD~1)" = "${before}" ]
}

@test "an earlier failed push is retried on a run with no content change" {
  echo '{"v": 1}' >"${SRC}"
  git -C "${CLONE}" remote set-url origin "${TMPDIR_T}/does-not-exist.git"
  run_backup
  [[ "${output}" == *"WARN: push failed"* ]]
  git -C "${CLONE}" remote set-url origin "${ORIGIN}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no content change; 1 unpushed commit(s), retrying push"* ]]
  [[ "${output}" == *"pushed to origin"* ]]
  [ "$(git -C "${ORIGIN}" rev-parse main)" = "$(git -C "${CLONE}" rev-parse HEAD)" ]
}

@test "a run with no content change and nothing unpushed does not push" {
  echo '{"v": 1}' >"${SRC}"
  run_backup
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no content change; nothing to commit"* ]]
  [[ "${output}" != *"push"* ]]
}

@test "URL userinfo is stripped from the logged error" {
  git -C "${CLONE}" remote set-url origin "https://someuser:s3cr3t-token@127.0.0.1:1/nope.git"
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"WARN: push failed ("* ]]
  [[ "${output}" != *"s3cr3t-token"* ]]
  [[ "${output}" != *"someuser"* ]]
}

# --- host-prefixed layout and tracked files ----------------------------------

@test "files are written under the host folder, never at the root" {
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [ "$(git -C "${ORIGIN}" show main:ASIAGO/cli/claude.json)" = '{"v": 1}' ]
  [ -z "$(git -C "${ORIGIN}" ls-tree --name-only main -- cli desktop machine-settings.json)" ]
}

@test "machine-settings.json is tracked and committed under the host folder" {
  echo '{"autoMode": {"enabled": true}}' >"${SRC_MS}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"committed: ASIAGO/machine-settings.json"* ]]
  [ "$(git -C "${ORIGIN}" show main:ASIAGO/machine-settings.json)" = '{"autoMode": {"enabled": true}}' ]
}

@test "CLAUDE_MACHINE_SETTINGS names the overlay source, as in claude-wrapper" {
  other="${TMPDIR_T}/elsewhere-overlay.json"
  echo '{"v": "override"}' >"${other}"
  run_backup CLAUDE_MACHINE_SETTINGS="${other}"
  [ "${status}" -eq 0 ]
  [ "$(git -C "${ORIGIN}" show main:ASIAGO/machine-settings.json)" = '{"v": "override"}' ]
}

@test "an invalid-JSON machine-settings.json is not committed; the others still are" {
  echo '{"sandbox": ' >"${SRC_MS}"
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SKIP ASIAGO/machine-settings.json: source is not valid JSON, refusing to commit"* ]]
  [ "$(git -C "${ORIGIN}" show main:ASIAGO/cli/claude.json)" = '{"v": 1}' ]
  run git -C "${ORIGIN}" cat-file -e main:ASIAGO/machine-settings.json
  [ "${status}" -ne 0 ]
}

@test "a lowercase hostname is used, uppercased, when no override is set" {
  BACKUP_HOST=""
  echo "tilsit" >"${STUBS}/hostname.out"
  echo '{"v": 1}' >"${SRC_MS}"
  run_backup
  [ "${status}" -eq 0 ]
  [ "$(git -C "${ORIGIN}" show main:TILSIT/machine-settings.json)" = '{"v": 1}' ]
}

# --- host label refusals -----------------------------------------------------

@test "no host label from either source exits non-zero and commits nothing" {
  BACKUP_HOST=""
  mv "${STUBS}/hostname.out" "${STUBS}/hostname.out.parked"
  echo '{"v": 1}' >"${SRC}"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: no host label; set CLAUDE_CONFIG_BACKUP_HOST"* ]]
  [ "$(git -C "${CLONE}" rev-parse HEAD)" = "${before}" ]
  [ -z "$(git -C "${CLONE}" status --porcelain)" ]
}

@test "invalid host labels are refused and nothing is written" {
  echo '{"v": 1}' >"${SRC}"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  for label in "../x" "a/b" ".." "-X" "AS IAGO" "ASIAGO/"; do
    BACKUP_HOST="${label}"
    run_backup
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"ERROR: invalid host label '${label}'"* ]]
  done
  [ "$(git -C "${CLONE}" rev-parse HEAD)" = "${before}" ]
  [ -z "$(git -C "${CLONE}" status --porcelain)" ]
  [ ! -e "${T_DATA}/x" ]
}

@test "an empty hostname with no override counts as no label" {
  BACKUP_HOST=""
  : >"${STUBS}/hostname.out"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: no host label"* ]]
}

# --- company machine ---------------------------------------------------------

@test "arich-mac by hostname is refused before anything is written" {
  BACKUP_HOST=""
  echo "arich-mac" >"${STUBS}/hostname.out"
  echo '{"v": 1}' >"${SRC}"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: this looks like arich-mac (company machine)"* ]]
  [ "$(git -C "${CLONE}" rev-parse HEAD)" = "${before}" ]
  [ -z "$(git -C "${CLONE}" status --porcelain)" ]
}

@test "arich-mac is refused even when the override names another host" {
  BACKUP_HOST="ASIAGO"
  echo "arich-mac" >"${STUBS}/hostname.out"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"arich-mac (company machine)"* ]]
}

@test "arich-mac by override label is refused" {
  BACKUP_HOST="ARICH-MAC"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"arich-mac (company machine)"* ]]
}

@test "the arich login (arich-mac's user) is refused whatever the host name" {
  echo "arich" >"${STUBS}/user.out"
  echo '{"v": 1}' >"${SRC}"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"arich-mac (company machine)"* ]]
  [ "$(git -C "${CLONE}" rev-parse HEAD)" = "${before}" ]
}

# --- one-time layout migration -----------------------------------------------

@test "the old root layout is moved into the host folder in one commit, then backed up" {
  use_origin "legacy" "cli/claude.json" "desktop/claude_desktop_config.json"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"migrated layout: moved cli desktop into ASIAGO/"* ]]
  [[ "${output}" == *"pushed to origin"* ]]
  # initial + migration + backup
  [ "$(git -C "${ORIGIN}" rev-list --count main)" -eq 3 ]
  migration="$(git -C "${ORIGIN}" rev-parse main~1)"
  [ "$(git -C "${ORIGIN}" rev-parse main~2)" = "${before}" ]
  [ "$(git -C "${ORIGIN}" log -1 --format=%s "${migration}")" = "layout: move cli desktop into ASIAGO/" ]
  # The migration commit is renames only, with the content unchanged.
  run git -C "${ORIGIN}" diff --name-status -M "${before}" "${migration}"
  [[ "${output}" == *"R100"*"cli/claude.json"*"ASIAGO/cli/claude.json"* ]]
  [[ "${output}" == *"R100"*"desktop/claude_desktop_config.json"*"ASIAGO/desktop/claude_desktop_config.json"* ]]
  [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" -eq 2 ]
  # History follows the file across the move.
  [ "$(git -C "${CLONE}" log --follow --format=%H -- ASIAGO/cli/claude.json | tail -1)" = "${before}" ]
  [ -z "$(git -C "${ORIGIN}" ls-tree --name-only main -- cli desktop)" ]
  [ "$(git -C "${ORIGIN}" show main:ASIAGO/cli/claude.json)" = '{"v": 1}' ]
}

@test "a second run after migration does not migrate again" {
  use_origin "legacy" "cli/claude.json"
  echo '{"v": 1}' >"${SRC}"
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"migrated layout: moved cli into ASIAGO/"* ]]
  run_backup
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"migrated layout"* ]]
  [[ "${output}" == *"no content change; nothing to commit"* ]]
}

@test "old and new layout both present: ERROR, no move, no commit" {
  use_origin "both" "cli/claude.json" "ASIAGO/cli/claude.json"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  echo '{"v": 1}' >"${SRC}"
  run_backup GIT_BIN="${STUBS}/fake-git"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: both old and new layout present for: cli"* ]]
  [ ! -e "${STUBS}/git-mv.calls" ]
  [ "$(git -C "${CLONE}" rev-parse HEAD)" = "${before}" ]
  [ -z "$(git -C "${CLONE}" status --porcelain)" ]
  [ "$(cat "${CLONE}/ASIAGO/cli/claude.json")" = '{"v": 0}' ]
}

@test "the move goes through GIT_BIN, and its failure stops the run" {
  use_origin "legacy" "cli/claude.json"
  before="$(git -C "${CLONE}" rev-parse HEAD)"
  echo '{"v": 1}' >"${SRC}"
  run_backup GIT_BIN="${STUBS}/fake-git"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: git mv cli ASIAGO/cli failed"* ]]
  [ "$(cat "${STUBS}/git-mv.calls")" = "-C ${CLONE} mv -- cli ASIAGO/cli" ]
  [ "$(git -C "${CLONE}" rev-parse HEAD)" = "${before}" ]
  [ -f "${CLONE}/cli/claude.json" ]
}
