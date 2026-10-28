#!/usr/bin/env bats
# bats tests for claude-config-backup.sh: the push step.
#
# Run from repo root:  bats tests/claude-config-backup.bats
#
# Hermetic. Every path the script touches is under BATS_TEST_TMPDIR:
#   - REPO is ${XDG_DATA_HOME}/claude-config-backup, and XDG_DATA_HOME is set
#     to the temp dir, so the real backup clone is never reached.
#   - TRACKED sources are under ${HOME}, and HOME is the temp dir, so no real
#     Claude config is read.
#   - origin is a temp bare repo; "elsewhere" is a second temp clone that
#     plays the part of the fleet rollout that pushed to the remote.
#   - gitleaks is a stub that finds nothing. stat is a stub that prints a
#     constant, because the script uses BSD `stat -f` and CI runs on Linux,
#     where `stat -f` means filesystem status and drifts between samples.
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
  chmod +x "${STUBS}/gitleaks" "${STUBS}/stat"

  T_HOME="${TMPDIR_T}/home"
  T_DATA="${TMPDIR_T}/data"
  ORIGIN="${TMPDIR_T}/origin.git"
  CLONE="${T_DATA}/claude-config-backup"
  ELSEWHERE="${TMPDIR_T}/elsewhere"
  SRC="${T_HOME}/.claude/.claude.json"
  mkdir -p "${T_HOME}/.claude" "${T_DATA}"

  # origin with one commit that already holds cli/claude.json.
  git init --quiet --bare -b main "${ORIGIN}"
  git clone --quiet "${ORIGIN}" "${ELSEWHERE}" 2>/dev/null
  mkdir -p "${ELSEWHERE}/cli"
  echo '{"v": 0}' >"${ELSEWHERE}/cli/claude.json"
  git -C "${ELSEWHERE}" add cli/claude.json
  git -C "${ELSEWHERE}" commit --quiet -m "initial"
  git -C "${ELSEWHERE}" push --quiet origin main

  git clone --quiet "${ORIGIN}" "${CLONE}"
}

# Runs the script with every input pointed into the temp dir.
run_backup() {
  run env HOME="${T_HOME}" XDG_DATA_HOME="${T_DATA}" TMPDIR="${TMPDIR_T}" \
    SETTLE_SECONDS=0 PATH="${STUBS}:${PATH}" bash "${SCRIPT}"
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
  [ "$(git -C "${ORIGIN}" show main:cli/claude.json)" = '{"v": 1}' ]
  [ "$(git -C "${ORIGIN}" rev-parse main)" = "$(git -C "${CLONE}" rev-parse HEAD)" ]
}

@test "a conflicting remote commit aborts the rebase and keeps local commits" {
  remote_commit "cli/claude.json" '{"v": "remote"}'
  remote_head="$(git -C "${ORIGIN}" rev-parse main)"
  before="$(git -C "${CLONE}" rev-list --count HEAD)"
  echo '{"v": "local"}' >"${SRC}"
  run_backup
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR: rebase onto origin/main conflicted (CONFLICT"*"cli/claude.json"* ]]
  [[ "${output}" == *"local commits are intact"* ]]
  [[ "${output}" == *"Fix by hand: git -C '${CLONE}' pull --rebase origin main"* ]]
  # Our commit is still there, on top of what we had; nothing was dropped.
  [ "$(git -C "${CLONE}" rev-list --count HEAD)" -eq $((before + 1)) ]
  [ "$(git -C "${CLONE}" show HEAD:cli/claude.json)" = '{"v": "local"}' ]
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
