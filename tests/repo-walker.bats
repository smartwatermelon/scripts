#!/usr/bin/env bats
# bats tests for lib/repo-walker.sh
#
# Run from repo root:  bats tests/repo-walker.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  LIB="${REPO_ROOT}/lib/repo-walker.sh"
  TMPDIR_T="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR_T}"
}

@test "sourcing the library has no side effects and defines main" {
  run bash -c "source '${LIB}'; declare -F repo_walker_main"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"repo_walker_main"* ]]
}

@test "require_config exits 2 when REPO_WALKER_DEVDIR is unset" {
  run bash -c "source '${LIB}'; REPO_WALKER_ORGS=x REPO_WALKER_DESC=y REPO_WALKER_DIRVAR=z repo_walker_require_config"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"REPO_WALKER_DEVDIR"* ]]
}

@test "require_config exits 2 when REPO_WALKER_ORGS is empty" {
  run bash -c "source '${LIB}'; REPO_WALKER_DEVDIR=/tmp REPO_WALKER_ORGS= REPO_WALKER_DESC=y REPO_WALKER_DIRVAR=z repo_walker_require_config"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"REPO_WALKER_ORGS"* ]]
}

@test "require_config succeeds when all four are set" {
  run bash -c "source '${LIB}'; REPO_WALKER_DEVDIR=/tmp REPO_WALKER_ORGS=x REPO_WALKER_DESC=y REPO_WALKER_DIRVAR=z repo_walker_require_config"
  [ "${status}" -eq 0 ]
}

@test "owner_repo extracts owner/name from an ssh remote" {
  run bash -c "source '${LIB}'; repo_walker_owner_repo 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon/scripts" ]
}

@test "owner_repo extracts owner/name from an https remote" {
  run bash -c "source '${LIB}'; repo_walker_owner_repo 'https://github.com/beacon-biosignals/infra.git'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "beacon-biosignals/infra" ]
}

@test "parse_args sets check and quiet flags" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check --quiet; \
    echo \"\${REPO_WALKER_CHECK_ONLY} \${REPO_WALKER_QUIET}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "true true" ]
}

@test "parse_args rejects an unknown flag with exit 2" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --bogus"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Unknown argument: --bogus"* ]]
}

@test "indent prefixes each line with four spaces" {
  run bash -c "source '${LIB}'; printf 'a\nb\n' | repo_walker_indent"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "    a" ]
  [ "${lines[1]}" = "    b" ]
}

@test "usage prints the wrapper's own name when invoked directly" {
  run "${REPO_ROOT}/my-repos.sh" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage: my-repos.sh"* ]]
}

@test "usage prints the invoked symlink name, not the wrapper's real name" {
  ln -s "${REPO_ROOT}/my-repos.sh" "${TMPDIR_T}/my-repos-link"
  run "${TMPDIR_T}/my-repos-link" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage: my-repos-link"* ]]
}

@test "missing directory warns by name and exits 0" {
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/nope' '${REPO_ROOT}/my-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${TMPDIR_T}/nope"* ]]
  [[ "${output}" == *"MY_REPOS_DIR"* ]]
}

@test "missing directory does not print a bare Total: 0" {
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/nope' '${REPO_ROOT}/my-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Warning"* ]]
  [[ "${output}" != *"Total: 0"* ]]
}

@test "empty directory warns that zero repos matched" {
  mkdir -p "${TMPDIR_T}/empty"
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/empty' '${REPO_ROOT}/my-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no repos matched"* ]]
}

@test "beacon wrapper names BEACON_REPOS_DIR in its warning" {
  run bash -c "BEACON_REPOS_DIR='${TMPDIR_T}/nope' '${REPO_ROOT}/beacon-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"BEACON_REPOS_DIR"* ]]
}

@test "show_issues skips a non-GitHub remote" {
  run bash -c "source '${LIB}'; REPO_WALKER_QUIET=false \
    repo_walker_show_issues 'demo' 'git@gitlab.com:foo/bar.git'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not a GitHub remote"* ]]
}

@test "show_issues reports fetch failure without aborting" {
  fake="${TMPDIR_T}/bin"
  mkdir -p "${fake}"
  printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' >"${fake}/gh"
  chmod +x "${fake}/gh"
  run bash -c "source '${LIB}'; PATH='${fake}:${PATH}' REPO_WALKER_QUIET=false \
    repo_walker_show_issues 'demo' 'git@github.com:o/r.git'; echo \"rc=\$?\""
  [[ "${output}" == *"issue fetch failed"* ]]
  [[ "${output}" == *"rc=0"* ]]
}

@test "parse_args accepts --show-issues" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --show-issues; \
    echo \"\${REPO_WALKER_SHOW_ISSUES}\""
  [ "${output}" = "true" ]
}

@test "--check suppresses --show-issues with a warning" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check --show-issues 2>&1; \
    echo \"\${REPO_WALKER_SHOW_ISSUES}\""
  [[ "${output}" == *"--show-issues is ignored when --check is set"* ]]
  [[ "${output}" == *"false"* ]]
}

# --status now covers four flags: --check-remotes joined the shorthand, so the
# consolidated warning names four. The point of the test is unchanged — one
# warning line, not one per flag.
@test "--check --status prints one consolidated warning naming every flag" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check --status 2>&1; \
    echo \"\${REPO_WALKER_SHOW_PRS} \${REPO_WALKER_SHOW_ISSUES} \${REPO_WALKER_SHOW_DEAD_BRANCHES} \${REPO_WALKER_CHECK_REMOTES}\""
  [ "${status}" -eq 0 ]
  warning_lines="$(grep -c 'ignored when --check is set' <<<"${output}")"
  [ "${warning_lines}" -eq 1 ]
  [[ "${output}" == *"--show-prs, --show-issues, --show-dead-branches, --check-remotes are ignored when --check is set"* ]]
  [[ "${output}" == *"false false false false"* ]]
}

@test "--check --show-prs alone still names --show-prs specifically" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check --show-prs 2>&1"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Warning: --show-prs is ignored when --check is set"* ]]
  [[ "${output}" != *","* ]]
}

@test "branch_upstream detects a cherry-equivalent branch" {
  r="${TMPDIR_T}/r"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" switch -qc feature
  echo two >>"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm two
  git -C "${r}" switch -q main
  echo three >"${r}/other"
  git -C "${r}" add other
  git -C "${r}" commit -qm three
  git -C "${r}" cherry-pick feature >/dev/null
  run bash -c "source '${LIB}'; repo_walker_branch_upstream '${r}' main feature"
  [ "${status}" -eq 0 ]
}

@test "branch_upstream returns non-zero for a branch with unique work" {
  r="${TMPDIR_T}/r2"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" switch -qc feature
  echo unique >>"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm unique
  run bash -c "source '${LIB}'; repo_walker_branch_upstream '${r}' main feature"
  [ "${status}" -ne 0 ]
}

@test "default_branch falls back to main with no origin remote at all" {
  r="${TMPDIR_T}/r3"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  run bash -c "source '${LIB}'; repo_walker_default_branch '${r}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "main" ]
}

@test "default_branch falls back to main with an origin remote but no origin/HEAD" {
  r="${TMPDIR_T}/r3b"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  git -C "${r}" remote add origin git@github.com:example/repo.git
  run bash -c "source '${LIB}'; repo_walker_default_branch '${r}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "main" ]
}

@test "default_branch falls back to main when called bare (no command substitution)" {
  r="${TMPDIR_T}/r3c"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  git -C "${r}" remote add origin git@github.com:example/repo.git
  run bash -c "set -euo pipefail; source '${LIB}'; repo_walker_default_branch '${r}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "main" ]
}

@test "walk completes and prints a summary for a repo with an origin remote but no origin/HEAD" {
  r="${TMPDIR_T}/walkdir/repo3"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" remote add origin git@github.com:smartwatermelon/repo3-does-not-exist-xyz.git
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/walkdir' '${REPO_ROOT}/my-repos.sh'"
  # The origin does not exist, so the pull fails and the walk exits 1; what
  # matters here is that it reaches the summary instead of aborting early.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"repo3"* ]]
  [[ "${output}" == *"Total:"* ]]
}

# Builds a local "upstream" for the moved-tag tests: a bare repo whose path
# contains "smartwatermelon" (so the walker's org filter accepts the remote),
# a scratch clone used to push to it, and a walked clone under walkdir/.
#
# The walked clone sets fetch.pruneTags itself rather than relying on the
# developer's global config. pruneTags adds a non-forced
# refs/tags/*:refs/tags/* refspec to every fetch, which is what turns a
# moved upstream tag into "would clobber existing tag". Without it, plain
# tag auto-follow never updates an existing tag and the bug is invisible.
_mk_tag_upstream() {
  up="${TMPDIR_T}/smartwatermelon/tagrepo.git"
  pusher="${TMPDIR_T}/pusher"
  walked="${TMPDIR_T}/walkdir/tagrepo"
  mkdir -p "${up}" "${TMPDIR_T}/walkdir"
  _GIT_WRAPPER_ACTIVE=1 git -C "${up}" init -q --bare -b main
  _GIT_WRAPPER_ACTIVE=1 git -c core.hooksPath=/dev/null clone -q "${up}" "${pusher}" 2>/dev/null
  git -C "${pusher}" config core.hooksPath /dev/null
  git -C "${pusher}" config user.email t@t
  git -C "${pusher}" config user.name t
  git -C "${pusher}" config tag.gpgSign false
  git -C "${pusher}" config commit.gpgSign false
  echo one >"${pusher}/f"
  git -C "${pusher}" add f
  git -C "${pusher}" commit -qm one
  git -C "${pusher}" tag v3
  git -C "${pusher}" push -q origin main v3
  _GIT_WRAPPER_ACTIVE=1 git -c core.hooksPath=/dev/null clone -q "${up}" "${walked}"
  git -C "${walked}" config core.hooksPath /dev/null
  git -C "${walked}" config user.email t@t
  git -C "${walked}" config user.name t
  git -C "${walked}" config commit.gpgSign false
  git -C "${walked}" config fetch.pruneTags true
}

# Moves v3 to a new commit upstream, the way github-workflows re-points its
# floating major tags on each release.
_move_upstream_tag() {
  echo two >>"${pusher}/f"
  git -C "${pusher}" add f
  git -C "${pusher}" commit -qm two
  git -C "${pusher}" tag -f v3 >/dev/null
  git -C "${pusher}" push -q -f origin main v3
}

@test "walk pulls and overwrites a tag that moved upstream" {
  _mk_tag_upstream
  _move_upstream_tag
  want_tag="$(git -C "${up}" rev-parse v3)"
  want_head="$(git -C "${up}" rev-parse main)"
  old_tag="$(git -C "${walked}" rev-parse v3)"
  [ "${old_tag}" != "${want_tag}" ]

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/walkdir' '${REPO_ROOT}/my-repos.sh'"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"would clobber existing tag"* ]]
  [[ "${output}" != *"pull failed"* ]]
  [[ "${output}" == *"Failed: 0"* ]]
  new_tag="$(git -C "${walked}" rev-parse v3)"
  new_head="$(git -C "${walked}" rev-parse HEAD)"
  [ "${new_tag}" = "${want_tag}" ]
  [ "${new_head}" = "${want_head}" ]
}

@test "walk still refuses a non-fast-forward branch after the tag fix" {
  _mk_tag_upstream
  # Diverge: a local-only commit, then a different upstream commit.
  echo local >"${walked}/g"
  git -C "${walked}" add g
  git -C "${walked}" commit -qm local-only
  before="$(git -C "${walked}" rev-parse HEAD)"
  _move_upstream_tag

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/walkdir' '${REPO_ROOT}/my-repos.sh'"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pull failed"* ]]
  # The failure must come from the divergence, not from the tag.
  [[ "${output}" != *"would clobber existing tag"* ]]
  [[ "${output}" == *"Failed: 1"* ]]
  after="$(git -C "${walked}" rev-parse HEAD)"
  [ "${after}" = "${before}" ]
}

@test "walk exits 1 when a pull fails, in both wrappers" {
  # An origin whose path does not exist: the pull fails.
  mkdir -p "${TMPDIR_T}/walkdir" "${TMPDIR_T}/beacondir"
  for d in walkdir/brokenrepo beacondir/brokenrepo; do
    _GIT_WRAPPER_ACTIVE=1 git -C "${TMPDIR_T}" init -q -b main "${d}"
  done
  git -C "${TMPDIR_T}/walkdir/brokenrepo" remote add origin \
    "${TMPDIR_T}/missing/smartwatermelon/brokenrepo.git"
  git -C "${TMPDIR_T}/beacondir/brokenrepo" remote add origin \
    "${TMPDIR_T}/missing/beacon-biosignals/brokenrepo.git"

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/walkdir' '${REPO_ROOT}/my-repos.sh' --quiet"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Failed: 1"* ]]
  [[ "${output}" == *"- brokenrepo"* ]]

  run bash -c "BEACON_REPOS_DIR='${TMPDIR_T}/beacondir' '${REPO_ROOT}/beacon-repos.sh' --quiet"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Failed: 1"* ]]
}

@test "walk exits 0 when the only repo left alone is dirty" {
  _mk_tag_upstream
  echo scratch >"${walked}/untracked"

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/walkdir' '${REPO_ROOT}/my-repos.sh'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Skipped: 1"* ]]
  [[ "${output}" == *"Failed: 0"* ]]
}

@test "parse_args accepts --show-dead-branches and --status" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --status; \
    echo \"\${REPO_WALKER_SHOW_PRS} \${REPO_WALKER_SHOW_ISSUES} \${REPO_WALKER_SHOW_DEAD_BRANCHES}\""
  [ "${output}" = "true true true" ]
}

@test "show_dead_branches reports a branch name containing a literal pipe intact" {
  r="${TMPDIR_T}/r4"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" switch -qc 'feat|weird'
  echo two >>"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm two
  git -C "${r}" switch -q main
  echo three >"${r}/other"
  git -C "${r}" add other
  git -C "${r}" commit -qm three
  git -C "${r}" cherry-pick 'feat|weird' >/dev/null
  run bash -c "source '${LIB}'; REPO_WALKER_QUIET=false \
    repo_walker_show_dead_branches 'demo' 'git@github.com:o/r.git' '${r}'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"branch -D feat|weird "* ]]
  [[ "${output}" != *"branch -D feat "* ]]
}

@test "show_dead_branches quiet mode surfaces a failed lookup instead of going silent" {
  r="${TMPDIR_T}/r5"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" switch -qc unresolved-feature
  echo unique >>"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm unique
  git -C "${r}" switch -q main

  fake="${TMPDIR_T}/bin5"
  mkdir -p "${fake}"
  printf '#!/usr/bin/env bash\necho "not json"\nexit 0\n' >"${fake}/gh"
  chmod +x "${fake}/gh"

  run bash -c "source '${LIB}'; PATH='${fake}:${PATH}' REPO_WALKER_QUIET=true \
    repo_walker_show_dead_branches 'demo' 'git@github.com:o/r.git' '${r}'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 lookup failed"* ]]
  [[ "${output}" != *"0 dead branches"* ]]
}

@test "owner_repo extracts owner/name from an SSH host alias remote" {
  run bash -c "source '${LIB}'; repo_walker_owner_repo 'git@github-smartwatermelon:smartwatermelon/scripts.git'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon/scripts" ]
}

@test "owner_repo extracts owner/name from a plain scp-style github.com remote" {
  run bash -c "source '${LIB}'; repo_walker_owner_repo 'git@github.com:owner/repo.git'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner/repo" ]
}

@test "owner_repo extracts owner/name from an https remote (regression)" {
  run bash -c "source '${LIB}'; repo_walker_owner_repo 'https://github.com/owner/repo.git'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner/repo" ]
}

# These two use an empty ssh config for the same reason the alias tests use a
# fixture one: without REPO_WALKER_SSH_CONFIG they read the developer's real
# ~/.ssh/config, so a machine that aliases github.com to an enterprise
# HostName would fail them for reasons unrelated to the code under test.
@test "github_host accepts a plain github.com remote" {
  cfg="${TMPDIR_T}/ssh_config_empty"
  : >"${cfg}"
  run bash -c "source '${LIB}'; REPO_WALKER_SSH_CONFIG='${cfg}' \
    repo_walker_github_host 'git@github.com:owner/repo.git'"
  [ "${status}" -eq 0 ]
}

@test "github_host rejects a genuine non-GitHub remote" {
  cfg="${TMPDIR_T}/ssh_config_empty"
  : >"${cfg}"
  run bash -c "source '${LIB}'; REPO_WALKER_SSH_CONFIG='${cfg}' \
    repo_walker_github_host 'git@gitlab.com:foo/bar.git'"
  [ "${status}" -ne 0 ]
}

@test "github_host accepts an SSH host alias that resolves to github.com" {
  cfg="${TMPDIR_T}/ssh_config"
  cat >"${cfg}" <<'EOF'
Host github-smartwatermelon
	HostName github.com
	User git
	IdentityFile ~/.ssh/id_ed25519_smartwatermelon
EOF

  run bash -c "source '${LIB}'; REPO_WALKER_SSH_CONFIG='${cfg}' \
    repo_walker_github_host 'git@github-smartwatermelon:smartwatermelon/scripts.git'"
  [ "${status}" -eq 0 ]
}

@test "github_host rejects an SSH host alias that resolves to a non-GitHub host" {
  cfg="${TMPDIR_T}/ssh_config_other"
  cat >"${cfg}" <<'EOF'
Host gitlab-work
	HostName gitlab.com
	User git
EOF

  run bash -c "source '${LIB}'; REPO_WALKER_SSH_CONFIG='${cfg}' \
    repo_walker_github_host 'git@gitlab-work:foo/bar.git'"
  [ "${status}" -ne 0 ]
}

@test "parse_args collects a single --skip value" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --skip foo; \
    printf '%s\n' \"\${REPO_WALKER_SKIP[@]}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "foo" ]
}

@test "parse_args collects repeated --skip values in order" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --skip foo --skip bar; \
    printf '%s\n' \"\${REPO_WALKER_SKIP[@]}\""
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "foo" ]
  [ "${lines[1]}" = "bar" ]
}

@test "parse_args accepts --skip=VALUE form" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --skip=foo; \
    printf '%s\n' \"\${REPO_WALKER_SKIP[@]}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "foo" ]
}

@test "parse_args exits 2 when --skip has no value" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --skip"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--skip requires a value"* ]]
}

@test "parse_args exits 2 when --skip is followed by another flag" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --skip --check"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--skip requires a value"* ]]
}

@test "parse_args exits 2 on an empty --skip=  value" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --skip="
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--skip requires a value"* ]]
}

@test "parse_args leaves REPO_WALKER_SKIP empty when --skip is absent" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check; \
    echo \"count=\${#REPO_WALKER_SKIP[@]}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "count=0" ]
}

@test "should_skip matches the short directory name" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(scripts); \
    repo_walker_should_skip 'scripts' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -eq 0 ]
}

@test "should_skip matches the owner/repo slug" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(smartwatermelon/scripts); \
    repo_walker_should_skip 'scripts' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -eq 0 ]
}

@test "should_skip matches a nested short path" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(nested/foo); \
    repo_walker_should_skip 'nested/foo' 'git@github.com:smartwatermelon/foo.git'"
  [ "${status}" -eq 0 ]
}

@test "should_skip does not match an unrelated name" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(other); \
    repo_walker_should_skip 'scripts' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -ne 0 ]
}

@test "should_skip does not partially match a longer name" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(script); \
    repo_walker_should_skip 'scripts' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -ne 0 ]
}

@test "should_skip treats a glob metacharacter as a literal" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=('scr*'); \
    repo_walker_should_skip 'scripts' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -ne 0 ]
}

@test "should_skip returns non-zero when the skip list is empty" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(); \
    repo_walker_should_skip 'scripts' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -ne 0 ]
}

@test "should_skip matches the slug for a repo whose dir name differs" {
  run bash -c "source '${LIB}'; REPO_WALKER_SKIP=(smartwatermelon/scripts); \
    repo_walker_should_skip 'scripts-checkout' 'git@github.com:smartwatermelon/scripts.git'"
  [ "${status}" -eq 0 ]
}

@test "usage documents --skip" {
  run "${REPO_ROOT}/my-repos.sh" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--skip"* ]]
}

@test "--skip excludes a repo from the walk and from the total" {
  mkdir -p "${TMPDIR_T}/skipdir"
  for name in keeper dropped; do
    r="${TMPDIR_T}/skipdir/${name}"
    mkdir -p "${r}"
    _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
    git -C "${r}" config core.hooksPath /dev/null
    git -C "${r}" config user.email t@t
    git -C "${r}" config user.name t
    echo one >"${r}/f"
    git -C "${r}" add f
    git -C "${r}" commit -qm one
    git -C "${r}" remote add origin "git@github.com:smartwatermelon/${name}.git"
  done

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/skipdir' '${REPO_ROOT}/my-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keeper"* ]]
  [[ "${output}" == *"dropped"* ]]

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/skipdir' '${REPO_ROOT}/my-repos.sh' --check --skip dropped"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keeper"* ]]
  [[ "${output}" != *"dropped"* ]]
  [[ "${output}" == *"Total: 1"* ]]
}

@test "--skip accepts the owner/repo slug during a real walk" {
  mkdir -p "${TMPDIR_T}/slugdir"
  r="${TMPDIR_T}/slugdir/onlyrepo"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" remote add origin git@github.com:smartwatermelon/onlyrepo.git

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/slugdir' '${REPO_ROOT}/my-repos.sh' --check --skip smartwatermelon/onlyrepo"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--skip excluded every repo"* ]]
}

@test "skipping every repo blames --skip, not the org filter" {
  mkdir -p "${TMPDIR_T}/alldir"
  r="${TMPDIR_T}/alldir/solo"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" remote add origin git@github.com:smartwatermelon/solo.git

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/alldir' '${REPO_ROOT}/my-repos.sh' --check --skip solo"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--skip excluded every repo"* ]]
  [[ "${output}" == *"1 repo(s) skipped"* ]]
  [[ "${output}" != *"no repos matched"* ]]
}

@test "an empty directory still blames the org filter, not --skip" {
  mkdir -p "${TMPDIR_T}/emptydir"
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/emptydir' '${REPO_ROOT}/my-repos.sh' --check --skip whatever"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no repos matched"* ]]
  [[ "${output}" != *"--skip excluded every repo"* ]]
}

@test "--skip with two flags excludes both repos" {
  mkdir -p "${TMPDIR_T}/twodir"
  for name in alpha beta gamma; do
    r="${TMPDIR_T}/twodir/${name}"
    mkdir -p "${r}"
    _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
    git -C "${r}" config core.hooksPath /dev/null
    git -C "${r}" config user.email t@t
    git -C "${r}" config user.name t
    echo one >"${r}/f"
    git -C "${r}" add f
    git -C "${r}" commit -qm one
    git -C "${r}" remote add origin "git@github.com:smartwatermelon/${name}.git"
  done

  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/twodir' '${REPO_ROOT}/my-repos.sh' --check --skip alpha --skip beta"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gamma"* ]]
  [[ "${output}" != *"alpha"* ]]
  [[ "${output}" != *"beta"* ]]
  [[ "${output}" == *"Total: 1"* ]]
}

# --- remote canonical check / fix -------------------------------------------
#
# gh is stubbed on PATH throughout. The stub answers `gh api repos/<slug>`
# with a canonical slug, mimicking GitHub's rename redirect: a repo moved
# from smartwatermelon to twistedmelonman still resolves under its old slug
# and reports the new full_name. Verified against the live API before these
# tests were written.

# Emits a `gh` shell function that maps stale slugs to canonical ones and
# fails on an unknown repo, the way real gh exits non-zero on a 404. Callers
# eval this text inside the test subshell, before the call under test.
#
# A shell function, not a PATH shim: ~/.local/bin/gh is this user's
# gh-wrapper.sh, which runs `gh api user --jq .login` to sync identity and
# aborts the whole command when that preflight fails (gh-wrapper.sh:312,770).
# A PATH stub shadows the real gh that the wrapper resolves internally, so the
# wrapper would abort before the lookup under test ever ran — the stub would
# see only `api user`. A function shadows the wrapper itself, which is not
# what these tests exercise.
#
# The redirect behaviour being mimicked is real: GitHub keeps a rename
# redirect, so `gh api repos/smartwatermelon/dotfiles --jq .full_name` answers
# `twistedmelonman/dotfiles`. Verified against the live API before these tests
# were written.
#
# The stub is written to a file and sourced, never interpolated into the
# `bash -c` string: passing it through a double-quoted layer would let the
# outer shell expand the stub's own "$@" and ${arg} before eval saw them.
_gh_stub_file() {
  local path="$1"
  _gh_stub_src >"${path}"
  echo "${path}"
}

_gh_stub_src() {
  cat <<'STUB'
gh() {
  local arg slug=""
  for arg in "$@"; do
    case "${arg}" in
      repos/*/*)
        slug="${arg#repos/}"
        break
        ;;
    esac
  done
  case "${slug}" in
    smartwatermelon/moved) echo "twistedmelonman/moved" ;;
    twistedmelonman/moved) echo "twistedmelonman/moved" ;;
    smartwatermelon/here) echo "smartwatermelon/here" ;;
    # A separate repo that is its own canonical name, for the triangular
    # (fetch upstream / push fork) case: it must never be rewritten.
    someone/fork) echo "someone/fork" ;;
    *) return 1 ;;
  esac
}
STUB
}

# A repo with one commit and the given origin URL.
_mkrepo() {
  local r="$1" url="$2"
  mkdir -p "${r}"
  _GIT_WRAPPER_ACTIVE=1 git -C "${r}" init -q -b main
  git -C "${r}" config core.hooksPath /dev/null
  git -C "${r}" config user.email t@t
  git -C "${r}" config user.name t
  echo one >"${r}/f"
  git -C "${r}" add f
  git -C "${r}" commit -qm one
  git -C "${r}" remote add origin "${url}"
}

@test "parse_args accepts --check-remotes" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check-remotes; \
    echo \"\${REPO_WALKER_CHECK_REMOTES} \${REPO_WALKER_FIX_REMOTES}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "true false" ]
}

@test "--fix-remotes implies --check-remotes" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --fix-remotes; \
    echo \"\${REPO_WALKER_CHECK_REMOTES} \${REPO_WALKER_FIX_REMOTES}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "true true" ]
}

@test "--status enables the remote check but never the fix" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --status; \
    echo \"\${REPO_WALKER_CHECK_REMOTES} \${REPO_WALKER_FIX_REMOTES}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "true false" ]
}

@test "--check suppresses --check-remotes by name" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check --check-remotes 2>&1"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--check-remotes is ignored when --check is set"* ]]
}

@test "--check suppresses --fix-remotes naming the flag the user typed" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --check --fix-remotes 2>&1; \
    echo \"state=\${REPO_WALKER_FIX_REMOTES}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--fix-remotes is ignored"* ]]
  [[ "${output}" != *"--check-remotes is ignored"* ]]
  [[ "${output}" == *"state=false"* ]]
}

@test "usage documents --check-remotes and --fix-remotes" {
  run bash -c "'${REPO_ROOT}/my-repos.sh' --help"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--check-remotes"* ]]
  [[ "${output}" == *"--fix-remotes"* ]]
}

@test "canonical_slug returns the new name for a redirected slug" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  run bash -c "source '${LIB}'; source '${stub}'; \
    repo_walker_canonical_slug smartwatermelon/moved"
  [ "${status}" -eq 0 ]
  [ "${output}" = "twistedmelonman/moved" ]
}

@test "canonical_slug fails without printing when the repo 404s" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  run bash -c "source '${LIB}'; source '${stub}'; \
    repo_walker_canonical_slug smartwatermelon/gone"
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "rewrite_slug preserves an scp-style URL and its .git suffix" {
  run bash -c "source '${LIB}'; repo_walker_rewrite_slug \
    'git@github.com:smartwatermelon/moved.git' twistedmelonman/moved"
  [ "${status}" -eq 0 ]
  [ "${output}" = "git@github.com:twistedmelonman/moved.git" ]
}

@test "rewrite_slug preserves an https URL without a .git suffix" {
  run bash -c "source '${LIB}'; repo_walker_rewrite_slug \
    'https://github.com/smartwatermelon/moved' twistedmelonman/moved"
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://github.com/twistedmelonman/moved" ]
}

# The host alias contains the owner name, so a first-match replacement would
# corrupt the host and break SSH identity selection.
@test "rewrite_slug does not corrupt a host alias containing the owner name" {
  run bash -c "source '${LIB}'; repo_walker_rewrite_slug \
    'git@github-smartwatermelon:smartwatermelon/moved.git' twistedmelonman/moved"
  [ "${status}" -eq 0 ]
  [ "${output}" = "git@github-smartwatermelon:twistedmelonman/moved.git" ]
}

@test "check_remote reports a canonical remote as ok" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/here.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=false \
    repo_walker_check_remote here git@github.com:smartwatermelon/here.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"remote canonical"* ]]
  [[ "${output}" == *"state=ok"* ]]
}

@test "check_remote skips a non-GitHub remote without calling gh" {
  _mkrepo "${TMPDIR_T}/r" git@git.example.com:someone/thing.git
  run bash -c "source '${LIB}'; REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=false \
    repo_walker_check_remote thing git@git.example.com:someone/thing.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not a GitHub remote"* ]]
  [[ "${output}" == *"state=skipped"* ]]
}

@test "check_remote reports a 404 lookup as failed, not as canonical" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/gone.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=false \
    repo_walker_check_remote gone git@github.com:smartwatermelon/gone.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"remote lookup failed"* ]]
  [[ "${output}" == *"state=failed"* ]]
}

@test "check_remote reports a stale remote without changing it" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/moved.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=false \
    repo_walker_check_remote moved git@github.com:smartwatermelon/moved.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"mis-pointed"* ]]
  [[ "${output}" == *"state=mispointed"* ]]
  # report-only must not write to config
  run git -C "${TMPDIR_T}/r" remote get-url origin
  [ "${output}" = "git@github.com:smartwatermelon/moved.git" ]
}

@test "fix_remotes rewrites a stale origin url in place" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/moved.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=true \
    repo_walker_check_remote moved git@github.com:smartwatermelon/moved.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state=fixed"* ]]
  run git -C "${TMPDIR_T}/r" remote get-url origin
  [ "${output}" = "git@github.com:twistedmelonman/moved.git" ]
}

@test "fix_remotes rewrites a stale pushurl too" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/moved.git
  git -C "${TMPDIR_T}/r" remote set-url --push origin git@github.com:smartwatermelon/moved.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=true \
    repo_walker_check_remote moved git@github.com:smartwatermelon/moved.git '${TMPDIR_T}/r'"
  [ "${status}" -eq 0 ]
  run git -C "${TMPDIR_T}/r" config --get remote.origin.pushurl
  [ "${output}" = "git@github.com:twistedmelonman/moved.git" ]
}

# gh-resolved=base means "origin itself" and follows a corrected url, so it is
# not stale and must not make a canonical repo report as mis-pointed.
@test "check_remote treats gh-resolved=base as canonical, not stale" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/here.git
  git -C "${TMPDIR_T}/r" config remote.origin.gh-resolved base
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=false \
    repo_walker_check_remote here git@github.com:smartwatermelon/here.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state=ok"* ]]
}

@test "fix_remotes refreshes a stale gh-resolved naming the old repo" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/here.git
  git -C "${TMPDIR_T}/r" config remote.origin.gh-resolved smartwatermelon/elsewhere
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=true \
    repo_walker_check_remote here git@github.com:smartwatermelon/here.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state=fixed"* ]]
  run git -C "${TMPDIR_T}/r" config --get remote.origin.gh-resolved
  [ "${output}" = "smartwatermelon/here" ]
}

# A full walk runs my-repos.sh as a separate process, so sourcing the stub
# into this shell cannot reach it. These two inject it with BASH_ENV, which
# bash sources into each non-interactive shell it starts.
#
# BASH_ENV rather than a PATH shim or `unset -f gh`, both of which were tried
# and do not work here: this user's profile defines gh as a *function*
# (gh-wrapper.sh), a function beats any executable on PATH, and the profile
# re-defines it in every child shell, so an unset in the parent is undone
# before my-repos.sh runs. BASH_ENV is sourced after that initialization, so
# the stub is the definition that survives.
@test "a full walk suppresses the remote check under --check" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  mkdir -p "${TMPDIR_T}/walk"
  _mkrepo "${TMPDIR_T}/walk/moved" git@github.com:smartwatermelon/moved.git
  run bash -c "BASH_ENV='${stub}' MY_REPOS_DIR='${TMPDIR_T}/walk' \
    bash '${REPO_ROOT}/my-repos.sh' --check --check-remotes 2>&1"
  [ "${status}" -eq 0 ]
  # --check means no network, so the remote check is suppressed with a warning
  [[ "${output}" == *"--check-remotes is ignored"* ]]
}

@test "a walk with --fix-remotes corrects the remote and counts it" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  mkdir -p "${TMPDIR_T}/walk"
  _mkrepo "${TMPDIR_T}/walk/moved" git@github.com:smartwatermelon/moved.git
  # dirty the tree: a remote fix must not depend on a clean worktree
  echo two >"${TMPDIR_T}/walk/moved/f"
  run bash -c "BASH_ENV='${stub}' MY_REPOS_DIR='${TMPDIR_T}/walk' \
    bash '${REPO_ROOT}/my-repos.sh' --fix-remotes 2>&1"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Fixed: 1"* ]]
  run git -C "${TMPDIR_T}/walk/moved" remote get-url origin
  [ "${output}" = "git@github.com:twistedmelonman/moved.git" ]
}

@test "my-repos.sh walks a twistedmelonman repo" {
  mkdir -p "${TMPDIR_T}/tmm"
  _mkrepo "${TMPDIR_T}/tmm/personal" git@github.com:twistedmelonman/personal.git
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/tmm' '${REPO_ROOT}/my-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"personal"* ]]
  [[ "${output}" == *"Total: 1"* ]]
}

# A pushurl naming a different repo is a triangular workflow (fetch from
# upstream, push to your fork), not migration damage. Rewriting it to canon
# would silently redirect pushes at upstream.
@test "a pushurl aimed at a different repo is left alone" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:smartwatermelon/here.git
  git -C "${TMPDIR_T}/r" remote set-url --push origin git@github.com:someone/fork.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=true \
    repo_walker_check_remote here git@github.com:smartwatermelon/here.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state=ok"* ]]
  run git -C "${TMPDIR_T}/r" config --get remote.origin.pushurl
  [ "${output}" = "git@github.com:someone/fork.git" ]
}

# A pushurl carrying a FORMER name of this same repo is migration damage, so
# it is the one pushurl case that does get rewritten.
@test "a pushurl holding a former name of the same repo is fixed" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  _mkrepo "${TMPDIR_T}/r" git@github.com:twistedmelonman/moved.git
  git -C "${TMPDIR_T}/r" remote set-url --push origin git@github.com:smartwatermelon/moved.git
  run bash -c "source '${LIB}'; source '${stub}'; \
    REPO_WALKER_QUIET=false REPO_WALKER_FIX_REMOTES=true \
    repo_walker_check_remote moved git@github.com:twistedmelonman/moved.git '${TMPDIR_T}/r'; \
    echo \"state=\${REPO_WALKER_REMOTE_STATE}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state=fixed"* ]]
  run git -C "${TMPDIR_T}/r" config --get remote.origin.pushurl
  [ "${output}" = "git@github.com:twistedmelonman/moved.git" ]
}

# The report-only summary path through repo_walker_main: the count, the list
# and the hint. Covered here because test "a full walk suppresses the remote
# check under --check" exercises suppression, not reporting.
@test "a report-only walk counts a mis-pointed remote and leaves it alone" {
  local stub
  stub="$(_gh_stub_file "${TMPDIR_T}/ghstub.sh")"
  mkdir -p "${TMPDIR_T}/walk"
  _mkrepo "${TMPDIR_T}/walk/moved" git@github.com:smartwatermelon/moved.git
  run bash -c "BASH_ENV='${stub}' MY_REPOS_DIR='${TMPDIR_T}/walk' \
    bash '${REPO_ROOT}/my-repos.sh' --check-remotes 2>&1"
  # The fake origin cannot be pulled, so the walk exits 1 for that reason.
  # This test cannot prove a mis-pointed remote alone leaves the status at 0:
  # git remote get-url applies insteadOf, so a reachable fake is not cheap.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Failed: 1"* ]]
  [[ "${output}" == *"Mis-pointed: 1"* ]]
  [[ "${output}" == *"Mis-pointed remotes:"* ]]
  [[ "${output}" == *"Re-run with --fix-remotes"* ]]
  run git -C "${TMPDIR_T}/walk/moved" remote get-url origin
  [ "${output}" = "git@github.com:smartwatermelon/moved.git" ]
}
