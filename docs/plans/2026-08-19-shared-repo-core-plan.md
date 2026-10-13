# Shared Repo-Walker Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the duplicated repo-walking logic from `pull-my-repos.sh` and
`pull-beacon-repos.sh` into one sourced library, rename both to `my-repos.sh` /
`beacon-repos.sh`, and add `--show-issues`, `--show-dead-branches`, and `--status` once
instead of twice.

**Architecture:** `lib/repo-walker.sh` holds every function and a `repo_walker_main`
entry point. Two thin wrappers set `REPO_WALKER_*` configuration variables, source the
library, and call `repo_walker_main "$@"`. The library is never executed directly and is
not symlinked into `~/.local/bin`.

**Tech Stack:** GNU Bash 5.x, `bats` (test runner, already used by `tests/*.bats`),
`shellcheck -S info`, `gh` + `jq` for the network report modes.

**Spec:** `docs/plans/2026-08-19-shared-repo-core-design.md`

## Global Constraints

- Shebang `#!/usr/bin/env bash` on wrappers; `set -euo pipefail` on wrappers only — the
  library inherits it across the `source` boundary and must not re-set it.
- **Never** `((var++))` or `((var--))`. Always `((var += 1))` / `((var -= 1))` — with
  `set -e`, the postfix form exits when the variable is 0.
- `shellcheck -S info` clean on every file. **No `# shellcheck disable` directives.**
  `# shellcheck source=lib/repo-walker.sh` is a source-path hint, not a suppression, and
  is allowed.
- Wrappers are `755` and committed with the `+x` bit; `lib/repo-walker.sh` is `644` and
  must **not** be executable. The pre-commit hook rejects non-executable `.sh` files in
  the repo root, so the library living under `lib/` matters.
- Every library-owned global is prefixed `REPO_WALKER_`.
- Never `git add .` — stage files individually.
- Branch is `claude/shared-repo-core-i122-i123-f16a6166`. Never commit to `main`.
- Report only: no task may run `git branch -D` or delete a branch.
- Text files end with a newline.

## File Structure

| Path | Responsibility | Mode |
|---|---|---|
| `lib/repo-walker.sh` | All logic: arg parsing, preflight, walk loop, report modes | 644 |
| `my-repos.sh` | Config for `~/Developer`, smartwatermelon\|nightowlstudiollc | 755 |
| `beacon-repos.sh` | Config for `~/Developer/beacon-biosignals`, beacon-biosignals | 755 |
| `tests/repo-walker.bats` | Unit tests, sourcing the library directly | 755 |
| `tests/fixtures/repo-walker/` | Scratch repos with fake remotes for walk tests | — |
| `README.md` | Script rows, Conventions env vars, `lib/` subdirectory | — |
| `CLAUDE.md` | Script categories, the not-symlinked library note | — |

**Testing approach.** `tests/ssh-wrapper.bats` establishes the convention: source the
script under test, call its functions directly. `lib/repo-walker.sh` is *always* sourced,
so the `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard used by `ssh` cannot work here — the
library instead defines `repo_walker_main` and runs nothing at source time. Sourcing is
therefore side-effect-free by construction, which is what makes it testable.

---

### Task 1: Library skeleton with configuration validation

Creates the library and both wrappers with **no behavior change yet** — the walk logic
still lives in the old scripts. This task exists on its own because the sourcing
mechanism, `SCRIPT_DIR` resolution through a symlink, and `usage()` name derivation are
the highest-risk parts of the refactor, and they are worth gating before any logic moves.

**Files:**

- Create: `lib/repo-walker.sh`
- Create: `tests/repo-walker.bats`
- Create: `tests/fixtures/repo-walker/.gitkeep`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `repo_walker_require_config()` — exits 2 if `REPO_WALKER_DEVDIR`,
    `REPO_WALKER_ORGS`, or `REPO_WALKER_DESC` is unset or empty.
  - `repo_walker_script_name()` — echoes the wrapper's basename, e.g. `my-repos.sh`.
  - `repo_walker_usage()` — prints the usage block using the above two.
  - `repo_walker_main()` — entry point; wrappers call it with `"$@"`.

- [ ] **Step 1: Write the failing test**

Create `tests/repo-walker.bats`:

```bash
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
  run bash -c "source '${LIB}'; REPO_WALKER_ORGS=x REPO_WALKER_DESC=y repo_walker_require_config"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"REPO_WALKER_DEVDIR"* ]]
}

@test "require_config exits 2 when REPO_WALKER_ORGS is empty" {
  run bash -c "source '${LIB}'; REPO_WALKER_DEVDIR=/tmp REPO_WALKER_ORGS= REPO_WALKER_DESC=y repo_walker_require_config"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"REPO_WALKER_ORGS"* ]]
}

@test "require_config succeeds when all three are set" {
  run bash -c "source '${LIB}'; REPO_WALKER_DEVDIR=/tmp REPO_WALKER_ORGS=x REPO_WALKER_DESC=y repo_walker_require_config"
  [ "${status}" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/repo-walker.bats`
Expected: FAIL — `lib/repo-walker.sh` does not exist, so `source` fails on every test.

- [ ] **Step 3: Write minimal implementation**

Create `lib/repo-walker.sh`. Note there is **no** shebang-executed body and **no**
`set -euo pipefail` — both belong to the wrapper:

```bash
# shellcheck shell=bash
# repo-walker.sh — shared implementation for my-repos.sh and beacon-repos.sh.
#
# Not executable and not a command. Wrappers set REPO_WALKER_DEVDIR,
# REPO_WALKER_ORGS, and REPO_WALKER_DESC, source this file, then call
# repo_walker_main "$@". Sourcing alone has no side effects.

repo_walker_require_config() {
  local missing=()
  [[ -n "${REPO_WALKER_DEVDIR:-}" ]] || missing+=("REPO_WALKER_DEVDIR")
  [[ -n "${REPO_WALKER_ORGS:-}" ]] || missing+=("REPO_WALKER_ORGS")
  [[ -n "${REPO_WALKER_DESC:-}" ]] || missing+=("REPO_WALKER_DESC")

  if ((${#missing[@]} > 0)); then
    echo "Error: lib/repo-walker.sh is a library, not a command." >&2
    echo "Missing required configuration: ${missing[*]}" >&2
    echo "Run my-repos.sh or beacon-repos.sh instead." >&2
    exit 2
  fi
}

# The wrapper is the outermost frame in the source stack, so BASH_SOURCE[-1]
# names it even though this code lives in the library.
repo_walker_script_name() {
  basename "${BASH_SOURCE[-1]}"
}

repo_walker_usage() {
  cat <<EOF
Usage: $(repo_walker_script_name) [OPTIONS]

${REPO_WALKER_DESC}

Options:
  --check       Only report dirty repos (no pulls, no network access)
  --show-prs    List open PRs for each repo via gh pr list
  --quiet, -q   Suppress per-repo detail; show only summary
  --help, -h    Show this help message and exit
EOF
}

repo_walker_main() {
  repo_walker_require_config
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/repo-walker.bats`
Expected: PASS, 4 tests.

- [ ] **Step 5: Verify shellcheck and the non-executable bit**

Run: `shellcheck -S info lib/repo-walker.sh tests/repo-walker.bats`
Expected: no output.

Run: `chmod 644 lib/repo-walker.sh && chmod +x tests/repo-walker.bats`
Run: `ls -l lib/repo-walker.sh` — expect `-rw-r--r--`, no `x`.

- [ ] **Step 6: Commit**

```bash
git add lib/repo-walker.sh tests/repo-walker.bats tests/fixtures/repo-walker/.gitkeep
git commit -m "feat(repo-walker): add library skeleton with config validation

lib/repo-walker.sh is sourced by wrappers, never executed. Sourcing has no
side effects, so bats can load it and call functions directly.

Refs #122, #123"
```

---

### Task 2: Move the walk logic into the library, wrappers replace the old scripts

The behavior-preserving heart of the refactor. Output for existing flags must be
**byte-identical** afterward, which is what Step 2 and Step 6 verify.

**Files:**

- Modify: `lib/repo-walker.sh`
- Create: `my-repos.sh` (via `git mv` from `pull-my-repos.sh`, then rewritten)
- Create: `beacon-repos.sh` (via `git mv` from `pull-beacon-repos.sh`, then rewritten)
- Modify: `tests/repo-walker.bats`

**Interfaces:**

- Consumes: `repo_walker_require_config`, `repo_walker_usage`, `repo_walker_main`.
- Produces:
  - `repo_walker_indent()` — pipes stdin through `sed 's/^/    /'`.
  - `repo_walker_owner_repo(remote)` — echoes `owner/name` from a GitHub remote URL.
  - `repo_walker_show_prs(short, remote)` — the existing `show_prs_for_repo`, renamed.
  - `repo_walker_parse_args("$@")` — sets `REPO_WALKER_CHECK_ONLY`,
    `REPO_WALKER_QUIET`, `REPO_WALKER_SHOW_PRS`.
  - `REPO_WALKER_DEVDIR` honors `MY_REPOS_DIR` / `BEACON_REPOS_DIR` (set in wrappers).

- [ ] **Step 1: Capture the pre-refactor baseline**

The old script must still exist when this runs. `--check` output includes live dirty-tree
state that drifts between commits, so capture it immediately before comparing — never
reuse an older capture.

```bash
BASE="$(mktemp -d)"; echo "baseline dir: ${BASE}"
./pull-my-repos.sh --help        >"${BASE}/help.txt"        2>&1
./pull-my-repos.sh --check       >"${BASE}/check.txt"       2>&1
./pull-my-repos.sh --check --quiet >"${BASE}/check-quiet.txt" 2>&1
./pull-my-repos.sh --bogus       >"${BASE}/bogus.txt"       2>&1 || true
```

- [ ] **Step 2: Write the failing test**

Append to `tests/repo-walker.bats`:

```bash
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bats tests/repo-walker.bats`
Expected: FAIL on the five new tests — those functions do not exist yet.

- [ ] **Step 4: Move the logic**

Copy the entire body of `pull-my-repos.sh` lines 28–275 into `lib/repo-walker.sh`,
applying these transformations. Preserve every string, colour code, and spacing exactly —
byte-identical output is the acceptance criterion.

1. Wrap the linear body (old lines 125–275: counters, `while` loop, summary) in
   `repo_walker_main() { ... }`, replacing the existing stub. Call
   `repo_walker_require_config` then `repo_walker_parse_args "$@"` at its top.
2. Rename functions and the globals they touch:
   - `indent` → `repo_walker_indent`
   - `show_prs_for_repo` → `repo_walker_show_prs`
   - `CHECK_ONLY` → `REPO_WALKER_CHECK_ONLY`, `QUIET` → `REPO_WALKER_QUIET`,
     `SHOW_PRS` → `REPO_WALKER_SHOW_PRS`
   - `DEVDIR` → `REPO_WALKER_DEVDIR`, `ORGS` → `REPO_WALKER_ORGS`
   - Colour variables → `REPO_WALKER_GREEN`, `REPO_WALKER_YELLOW`, `REPO_WALKER_RED`,
     `REPO_WALKER_CYAN`, `REPO_WALKER_RESET`
3. Extract the `owner_repo` sed from inside `repo_walker_show_prs` into its own function:

```bash
repo_walker_owner_repo() {
  sed -E 's|.*github\.com[:/]||; s|\.git$||' <<<"$1"
}
```

   and have `repo_walker_show_prs` call it.
4. Move arg parsing (old lines 28–69) into `repo_walker_parse_args`, with `--help`
   calling `repo_walker_usage`. Declare the three flag globals with defaults at the top
   of the function so a second call cannot inherit stale state:

```bash
repo_walker_parse_args() {
  REPO_WALKER_CHECK_ONLY=false
  REPO_WALKER_QUIET=false
  REPO_WALKER_SHOW_PRS=false

  local arg
  for arg in "$@"; do
    case "${arg}" in
      --help | -h)
        repo_walker_usage
        exit 0
        ;;
      --check) REPO_WALKER_CHECK_ONLY=true ;;
      --show-prs) REPO_WALKER_SHOW_PRS=true ;;
      --quiet | -q) REPO_WALKER_QUIET=true ;;
      *)
        echo "Unknown argument: ${arg}" >&2
        exit 2
        ;;
    esac
  done

  # ... the three existing guard blocks (old lines 47-69) follow, unchanged
  # except for the renamed globals.
}
```

- [ ] **Step 5: Create the wrappers**

```bash
git mv pull-my-repos.sh my-repos.sh
git mv pull-beacon-repos.sh beacon-repos.sh
```

Then replace the entire contents of `my-repos.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# my-repos.sh — For each repo in ~/Developer owned by
# smartwatermelon or nightowlstudiollc: show status, pull if clean.
#
# Configuration only; all logic lives in lib/repo-walker.sh.
# Override the directory with MY_REPOS_DIR.

REPO_WALKER_DEVDIR="${MY_REPOS_DIR:-${HOME}/Developer}"
REPO_WALKER_ORGS="smartwatermelon|nightowlstudiollc"
REPO_WALKER_DESC="Pull all repos in ${REPO_WALKER_DEVDIR} owned by smartwatermelon or nightowlstudiollc."

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/repo-walker.sh
source "${SCRIPT_DIR}/lib/repo-walker.sh"

repo_walker_main "$@"
```

And `beacon-repos.sh` with the same file, differing only in these three lines:

```bash
REPO_WALKER_DEVDIR="${BEACON_REPOS_DIR:-${HOME}/Developer/beacon-biosignals}"
REPO_WALKER_ORGS="beacon-biosignals"
REPO_WALKER_DESC="Pull all repos in ${REPO_WALKER_DEVDIR} owned by beacon-biosignals."
```

with its header comment naming `beacon-repos.sh`, `~/Developer/beacon-biosignals`, and
`BEACON_REPOS_DIR`. **This corrects the path bug** — the old file said
`~/Developer/beacon`, which never existed.

- [ ] **Step 6: Verify byte-identical output**

```bash
diff <(sed 's/pull-my-repos\.sh/SCRIPT/' "${BASE}/help.txt") \
     <(./my-repos.sh --help | sed 's/my-repos\.sh/SCRIPT/')
./my-repos.sh --check       >/tmp/new-check.txt 2>&1
./my-repos.sh --check --quiet >/tmp/new-check-quiet.txt 2>&1
diff "${BASE}/check.txt" /tmp/new-check.txt
diff "${BASE}/check-quiet.txt" /tmp/new-check-quiet.txt
./my-repos.sh --bogus >/tmp/new-bogus.txt 2>&1 || true
diff "${BASE}/bogus.txt" /tmp/new-bogus.txt
```

Expected: no diff output from any command. The `--help` comparison normalizes only the
script's own name, which is the one intended change.

If `check.txt` differs solely because a repo's dirty state changed while you worked,
re-run Step 1's capture against `pull-my-repos.sh` from git (`git show HEAD:pull-my-repos.sh`)
and compare again — do not wave the diff away.

- [ ] **Step 7: Run the unit tests and shellcheck**

Run: `bats tests/repo-walker.bats`
Expected: PASS, 9 tests.

Run: `shellcheck -S info lib/repo-walker.sh my-repos.sh beacon-repos.sh`
Expected: no output.

- [ ] **Step 8: Verify the symlink path resolves**

This is the failure mode the spec calls most likely, and a naive form genuinely fails
here. `cd "$(dirname "${BASH_SOURCE[0]}")"` resolves to the directory of the *link*, not
its target, so a wrapper invoked via `~/.local/bin/my-repos` would look for
`~/.local/bin/lib/repo-walker.sh` and die with "No such file or directory". `realpath`
resolves the link first — verified on both machines, and the same idiom the repo's `ssh`
wrapper already uses. Test through a symlink, not by path:

```bash
ln -sf "$(pwd)/my-repos.sh" /tmp/my-repos-link
/tmp/my-repos-link --help
rm /tmp/my-repos-link
```

Expected: the usage block prints with `Usage: my-repos-link` (the invoked name) and no
"No such file or directory" error for `lib/repo-walker.sh`.

- [ ] **Step 9: Commit**

```bash
git add lib/repo-walker.sh my-repos.sh beacon-repos.sh tests/repo-walker.bats
git commit -m "refactor: extract shared core, rename to my-repos/beacon-repos

pull-my-repos.sh and pull-beacon-repos.sh were byte-identical except for
DEVDIR, ORGS, and name strings. Both are now five-line wrappers over
lib/repo-walker.sh.

Fixes the beacon path: it pointed at ~/Developer/beacon since #106, but
the repos are in ~/Developer/beacon-biosignals, so the script reported
Total: 0 and allup never pulled them. DEVDIR is now overridable via
MY_REPOS_DIR / BEACON_REPOS_DIR.

Output for --check, --quiet, --help, and the unknown-argument path is
byte-identical to the pre-refactor script apart from the script name.

Refs #122, #123"
```

---

### Task 3: Missing and empty directory warnings

Closes the silent-`Total: 0` hole that hid the beacon bug for months.

**Files:**

- Modify: `lib/repo-walker.sh`
- Modify: `tests/repo-walker.bats`

**Interfaces:**

- Consumes: `repo_walker_main`, `REPO_WALKER_DEVDIR`.
- Produces: `repo_walker_check_devdir()` — warns to stderr and returns 1 if
  `REPO_WALKER_DEVDIR` is not a directory; returns 0 otherwise. Exit status of the script
  stays 0 in both cases.

- [ ] **Step 1: Write the failing test**

Append to `tests/repo-walker.bats`:

```bash
@test "missing directory warns by name and exits 0" {
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/nope' '${REPO_ROOT}/my-repos.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${TMPDIR_T}/nope"* ]]
  [[ "${output}" == *"MY_REPOS_DIR"* ]]
}

@test "missing directory does not print a bare Total: 0" {
  run bash -c "MY_REPOS_DIR='${TMPDIR_T}/nope' '${REPO_ROOT}/my-repos.sh' --check"
  [[ "${output}" == *"Warning"* ]]
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/repo-walker.bats`
Expected: FAIL on the four new tests — currently a missing directory prints `Total: 0`
with no warning.

- [ ] **Step 3: Add the env-var name to wrapper config**

The warning must name the variable that overrides the path, which differs per wrapper.
Add to `my-repos.sh`, after the other config lines:

```bash
REPO_WALKER_DIRVAR="MY_REPOS_DIR"
```

and to `beacon-repos.sh`:

```bash
REPO_WALKER_DIRVAR="BEACON_REPOS_DIR"
```

Add `REPO_WALKER_DIRVAR` to the `missing` checks in `repo_walker_require_config`
alongside the existing three.

- [ ] **Step 4: Write the implementation**

Add to `lib/repo-walker.sh`:

```bash
repo_walker_check_devdir() {
  if [[ ! -d "${REPO_WALKER_DEVDIR}" ]]; then
    echo "Warning: repo directory not found: ${REPO_WALKER_DEVDIR}" >&2
    echo "         nothing to do. Set ${REPO_WALKER_DIRVAR} to override." >&2
    return 1
  fi
  return 0
}
```

In `repo_walker_main`, immediately after `repo_walker_parse_args "$@"`:

```bash
  if ! repo_walker_check_devdir; then
    return 0
  fi
```

And after the walk loop, before the summary block, warn on a zero-match walk:

```bash
  if ((total == 0)); then
    echo "Warning: no repos matched '${REPO_WALKER_ORGS}' under ${REPO_WALKER_DEVDIR}" >&2
    echo "         set ${REPO_WALKER_DIRVAR} if the path is wrong." >&2
  fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/repo-walker.bats`
Expected: PASS, 13 tests.

- [ ] **Step 6: Verify on this machine, which has no beacon directory**

Run: `./beacon-repos.sh --check; echo "exit: $?"`
Expected: the missing-directory warning naming `~/Developer/beacon-biosignals` and
`BEACON_REPOS_DIR`, and `exit: 0`. Exit 0 is the point — `allup` uses `|| return $?` and
must keep passing on this machine.

- [ ] **Step 7: Commit**

```bash
git add lib/repo-walker.sh my-repos.sh beacon-repos.sh tests/repo-walker.bats
git commit -m "feat(repo-walker): warn on missing or empty repo directory

Total: 0 read identically whether the path was wrong or there was
genuinely nothing to do, which is how the beacon path bug survived since
#106. Both cases now warn by name and cite the overriding env var.

Exits 0 deliberately: this machine will never have beacon repos, and a
hard error would fail allup on a correct configuration.

Refs #122"
```

---

### Task 4: `--show-issues`

**Files:**

- Modify: `lib/repo-walker.sh`
- Modify: `tests/repo-walker.bats`

**Interfaces:**

- Consumes: `repo_walker_owner_repo`, `repo_walker_indent`, `REPO_WALKER_QUIET`.
- Produces: `repo_walker_show_issues(short, remote)`; `REPO_WALKER_SHOW_ISSUES` global;
  `repo_walker_run_reports(short, remote)` dispatching every enabled report mode.

- [ ] **Step 1: Write the failing test**

Append to `tests/repo-walker.bats`:

```bash
@test "show_issues skips a non-GitHub remote" {
  run bash -c "source '${LIB}'; REPO_WALKER_QUIET=false \
    repo_walker_show_issues 'demo' 'git@gitlab.com:foo/bar.git'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not a GitHub remote"* ]]
}

@test "show_issues reports fetch failure without aborting" {
  fake="${TMPDIR_T}/bin"; mkdir -p "${fake}"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/repo-walker.bats`
Expected: FAIL — `repo_walker_show_issues` is not defined.

- [ ] **Step 3: Write the implementation**

Add to `lib/repo-walker.sh`, modelled exactly on `repo_walker_show_prs`:

```bash
repo_walker_show_issues() {
  local short="$1" remote="$2"
  local owner_repo issue_json issue_count

  if [[ "${remote}" != *github.com* ]]; then
    if ! "${REPO_WALKER_QUIET}"; then
      echo "  (not a GitHub remote, skipping issue lookup)"
    fi
    return
  fi

  owner_repo="$(repo_walker_owner_repo "${remote}")"

  if ! issue_json="$(gh -R "${owner_repo}" issue list --state open \
    --json number,title,labels,author,assignees 2>&1)"; then
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_RED}issue fetch failed${REPO_WALKER_RESET}"
    else
      echo -e "  ${REPO_WALKER_RED}✗ issue fetch failed${REPO_WALKER_RESET}"
      echo "${issue_json}" | repo_walker_indent
    fi
    return
  fi

  issue_count="$(jq 'length' <<<"${issue_json}")"

  if "${REPO_WALKER_QUIET}"; then
    if ((issue_count == 1)); then
      echo "  ${short}: ${issue_count} open issue"
    else
      echo "  ${short}: ${issue_count} open issues"
    fi
  else
    echo -e "  open issues: ${issue_count}"
    if ((issue_count > 0)); then
      jq -r '.[] | "    #\(.number)  \(.title)"
        + (if (.labels | length) > 0 then "  [\([.labels[].name] | join(","))]" else "" end)
        + "  by \(.author.login)"' <<<"${issue_json}"
    fi
  fi
}
```

The `labels` handling is the one real difference from the PR function: it is an array of
objects, and an empty array must render as nothing rather than `[]`.

- [ ] **Step 4: Add the flag and centralize report dispatch**

`repo_walker_show_prs` is called from **three** places (the main path plus two early
`continue` paths for status-check and branch-switch failures). Adding a second report
mode to all three by hand is how one gets missed, so route them through one function:

```bash
repo_walker_run_reports() {
  local short="$1" remote="$2"
  if "${REPO_WALKER_SHOW_PRS}"; then
    repo_walker_show_prs "${short}" "${remote}"
  fi
  if "${REPO_WALKER_SHOW_ISSUES}"; then
    repo_walker_show_issues "${short}" "${remote}"
  fi
}
```

Replace all three `if "${REPO_WALKER_SHOW_PRS}"; then repo_walker_show_prs ...; fi` blocks
with `repo_walker_run_reports "${short}" "${remote}"`.

In `repo_walker_parse_args`: add `REPO_WALKER_SHOW_ISSUES=false` to the defaults, a
`--show-issues) REPO_WALKER_SHOW_ISSUES=true ;;` case, and extend the three guard blocks
so each tests every network flag:

```bash
  if "${REPO_WALKER_CHECK_ONLY}" && "${REPO_WALKER_SHOW_ISSUES}"; then
    echo "Warning: --show-issues is ignored when --check is set (--check means no network access)" >&2
    REPO_WALKER_SHOW_ISSUES=false
  fi
```

The `--quiet` no-op note and the `gh`/`jq` preflight both become
`if "${REPO_WALKER_SHOW_PRS}" || "${REPO_WALKER_SHOW_ISSUES}"; then`, with the preflight
error text changed from `--show-prs requires` to `--show-prs/--show-issues require`.

- [ ] **Step 5: Add `--show-issues` to the usage block**

In `repo_walker_usage`, after the `--show-prs` line:

```
  --show-issues List open issues for each repo via gh issue list
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bats tests/repo-walker.bats`
Expected: PASS, 17 tests.

- [ ] **Step 7: Verify against real data**

Run: `./my-repos.sh --show-issues --quiet 2>&1 | head -20`
Expected: one `<repo>: N open issue(s)` line per repo. This repo should report at least
2 open issues (#122 and #123).

Run: `./my-repos.sh --show-prs --show-issues 2>&1 | head -30`
Expected: both an `open PRs:` and an `open issues:` block per repo.

- [ ] **Step 8: Commit**

```bash
git add lib/repo-walker.sh tests/repo-walker.bats
git commit -m "feat(repo-walker): add --show-issues

Mirrors --show-prs. Report modes now dispatch through
repo_walker_run_reports, which is called from all three sites --
including the two early-continue paths for status-check and
branch-switch failures, which would otherwise silently skip reports for
exactly the repos in trouble.

Closes #123"
```

---

### Task 5: `--show-dead-branches`

**Files:**

- Modify: `lib/repo-walker.sh`
- Modify: `tests/repo-walker.bats`

**Interfaces:**

- Consumes: `repo_walker_owner_repo`, `repo_walker_run_reports`.
- Produces: `repo_walker_default_branch(repo)`, `repo_walker_branch_upstream(repo,
  default, branch)`, `repo_walker_show_dead_branches(short, remote, repo)`;
  `REPO_WALKER_SHOW_DEAD_BRANCHES` global.

- [ ] **Step 1: Write the failing test**

Append to `tests/repo-walker.bats`. This builds a real git repo so `git cherry` is
exercised for real rather than mocked:

```bash
@test "branch_upstream detects a cherry-equivalent branch" {
  r="${TMPDIR_T}/r"; mkdir -p "${r}"
  git -C "${r}" init -q -b main
  git -C "${r}" config user.email t@t; git -C "${r}" config user.name t
  echo one >"${r}/f"; git -C "${r}" add f; git -C "${r}" commit -qm one
  git -C "${r}" switch -qc feature
  echo two >>"${r}/f"; git -C "${r}" add f; git -C "${r}" commit -qm two
  git -C "${r}" switch -q main
  git -C "${r}" cherry-pick -q feature
  run bash -c "source '${LIB}'; repo_walker_branch_upstream '${r}' main feature"
  [ "${status}" -eq 0 ]
}

@test "branch_upstream returns non-zero for a branch with unique work" {
  r="${TMPDIR_T}/r2"; mkdir -p "${r}"
  git -C "${r}" init -q -b main
  git -C "${r}" config user.email t@t; git -C "${r}" config user.name t
  echo one >"${r}/f"; git -C "${r}" add f; git -C "${r}" commit -qm one
  git -C "${r}" switch -qc feature
  echo unique >>"${r}/f"; git -C "${r}" add f; git -C "${r}" commit -qm unique
  run bash -c "source '${LIB}'; repo_walker_branch_upstream '${r}' main feature"
  [ "${status}" -ne 0 ]
}

@test "default_branch falls back to main without an origin HEAD" {
  r="${TMPDIR_T}/r3"; mkdir -p "${r}"
  git -C "${r}" init -q -b main
  run bash -c "source '${LIB}'; repo_walker_default_branch '${r}'"
  [ "${output}" = "main" ]
}

@test "parse_args accepts --show-dead-branches and --status" {
  run bash -c "source '${LIB}'; repo_walker_parse_args --status; \
    echo \"\${REPO_WALKER_SHOW_PRS} \${REPO_WALKER_SHOW_ISSUES} \${REPO_WALKER_SHOW_DEAD_BRANCHES}\""
  [ "${output}" = "true true true" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/repo-walker.bats`
Expected: FAIL — the three new functions and `--status` do not exist.

- [ ] **Step 3: Write the helper functions**

```bash
repo_walker_default_branch() {
  local repo="$1" branch
  branch="$(git -C "${repo}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||')"
  [[ -n "${branch}" ]] || branch="main"
  echo "${branch}"
}

# Signal 1: every commit on <branch> has an equivalent already upstream.
# `git cherry` prefixes such commits with '-' and unique ones with '+'.
repo_walker_branch_upstream() {
  local repo="$1" default="$2" branch="$3" cherry
  cherry="$(git -C "${repo}" cherry "${default}" "${branch}" 2>/dev/null)" || return 1
  [[ -n "${cherry}" ]] || return 1
  ! grep -q '^+' <<<"${cherry}"
}
```

- [ ] **Step 4: Write the report function**

```bash
repo_walker_show_dead_branches() {
  local short="$1" remote="$2" repo="$3"
  local owner_repo default current branch pr_json pr_num merged_at
  local base changed differing
  local -a dead=() suspect=() unpushed=()

  if [[ "${remote}" != *github.com* ]]; then
    if ! "${REPO_WALKER_QUIET}"; then
      echo "  (not a GitHub remote, skipping dead-branch lookup)"
    fi
    return
  fi

  owner_repo="$(repo_walker_owner_repo "${remote}")"
  default="$(repo_walker_default_branch "${repo}")"
  current="$(git -C "${repo}" branch --show-current 2>/dev/null || true)"

  while IFS= read -r branch; do
    [[ -n "${branch}" ]] || continue
    [[ "${branch}" != "${default}" ]] || continue
    [[ "${branch}" != "${current}" ]] || continue

    local sha
    sha="$(git -C "${repo}" rev-parse --short "${branch}" 2>/dev/null || echo "?")"

    # Signal 1 — offline, conclusive when it fires.
    if repo_walker_branch_upstream "${repo}" "${default}" "${branch}"; then
      dead+=("${branch}|${sha}|cherry-equivalent")
      continue
    fi

    # Signal 2 — squash merges are invisible to signal 1.
    if ! pr_json="$(gh -R "${owner_repo}" pr list --state merged --head "${branch}" \
      --json number,mergedAt,title 2>&1)"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ merged-PR lookup failed for ${branch}${REPO_WALKER_RESET}"
        echo "${pr_json}" | repo_walker_indent
      fi
      continue
    fi

    if [[ "$(jq 'length' <<<"${pr_json}")" -eq 0 ]]; then
      unpushed+=("${branch}|${sha}")
      continue
    fi

    pr_num="$(jq -r '.[0].number' <<<"${pr_json}")"
    merged_at="$(jq -r '.[0].mergedAt' <<<"${pr_json}" | cut -d'T' -f1)"

    # Signal 3 — a merged PR does not prove the branch holds no extra work.
    base="$(git -C "${repo}" merge-base "${default}" "${branch}" 2>/dev/null || true)"
    differing=""
    if [[ -n "${base}" ]]; then
      while IFS= read -r changed; do
        [[ -n "${changed}" ]] || continue
        if ! git -C "${repo}" diff --quiet "${default}" "${branch}" -- "${changed}" 2>/dev/null; then
          differing+="${changed} "
        fi
      done < <(git -C "${repo}" diff --name-only "${base}" "${branch}" 2>/dev/null || true)
    fi

    if [[ -n "${differing}" ]]; then
      suspect+=("${branch}|${sha}|${pr_num}|${merged_at}|${differing}")
    else
      dead+=("${branch}|${sha}|PR #${pr_num}, merged ${merged_at}")
    fi
  done < <(git -C "${repo}" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)

  if "${REPO_WALKER_QUIET}"; then
    if ((${#dead[@]} == 1)); then
      echo "  ${short}: ${#dead[@]} dead branch"
    else
      echo "  ${short}: ${#dead[@]} dead branches"
    fi
    return
  fi

  echo -e "  dead branches: ${#dead[@]}"
  local entry
  for entry in "${dead[@]}"; do
    IFS='|' read -r branch sha why <<<"${entry}"
    echo "    git -C ${repo} branch -D ${branch}    # ${why} (tip ${sha})"
  done
  for entry in "${suspect[@]}"; do
    IFS='|' read -r branch sha pr_num merged_at differing <<<"${entry}"
    echo -e "    ${REPO_WALKER_YELLOW}? ${branch}${REPO_WALKER_RESET} (tip ${sha}) PR #${pr_num} merged ${merged_at}, but files differ:"
    echo "        ${differing}"
  done
  for entry in "${unpushed[@]}"; do
    IFS='|' read -r branch sha <<<"${entry}"
    echo -e "    ${REPO_WALKER_CYAN}↑ ${branch}${REPO_WALKER_RESET} (tip ${sha}) no PR — unpushed work"
  done
}
```

Tip SHAs print for every category: after a `-D`, the SHA is the only reflog recovery path.
Nothing here deletes a branch.

**Cost note.** Signal 1 is offline and short-circuits, so only branches it does *not*
resolve reach the `gh` call — one API round trip each. A repo with many stale branches
(arich-mac's `infra` has 6 local branches) can therefore issue several calls per repo, and
`--status` runs this alongside `--show-prs` and `--show-issues`. That is acceptable for an
opt-in flag, but it is why none of these modes are on by default and why `--check`
suppresses all of them.

- [ ] **Step 5: Wire up the flag, `--status`, and dispatch**

In `repo_walker_parse_args`: add `REPO_WALKER_SHOW_DEAD_BRANCHES=false` to the defaults
and these cases:

```bash
      --show-dead-branches) REPO_WALKER_SHOW_DEAD_BRANCHES=true ;;
      --status)
        REPO_WALKER_SHOW_PRS=true
        REPO_WALKER_SHOW_ISSUES=true
        REPO_WALKER_SHOW_DEAD_BRANCHES=true
        ;;
```

Add the matching `--check` suppression block, and include
`REPO_WALKER_SHOW_DEAD_BRANCHES` in the `--quiet` no-op test and the `gh`/`jq` preflight
condition.

`repo_walker_run_reports` needs the repo path, which it does not currently take. Change
its signature to `repo_walker_run_reports(short, remote, repo)`, update all three call
sites to pass `"${repo}"`, and add:

```bash
  if "${REPO_WALKER_SHOW_DEAD_BRANCHES}"; then
    repo_walker_show_dead_branches "${short}" "${remote}" "${repo}"
  fi
```

Add both flags to `repo_walker_usage`:

```
  --show-dead-branches
                List local branches whose PRs have merged (report only)
  --status      Shorthand for --show-prs --show-issues --show-dead-branches
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bats tests/repo-walker.bats`
Expected: PASS, 21 tests.

- [ ] **Step 7: Validate against a known-dead branch**

A "0 dead branches" result proves nothing unless detection is confirmed to fire on a
branch known to be dead. This repo has one: `claude/fix-scripts-log-show-false-ok-i112`,
whose PR #116 was squash-merged.

```bash
git branch -a | grep fix-scripts-log-show-false || \
  echo "MISSING — recreate it or pick another squash-merged branch before trusting results"
./my-repos.sh --show-dead-branches 2>&1 | grep -A5 'scripts'
```

Expected: that branch is listed as dead, attributed either to `cherry-equivalent` or to
`PR #116`. Verified behavior on this branch as of writing — **both** signals fire:

```bash
git cherry main claude/fix-scripts-log-show-false-ok-i112
# -> "- 96defff..."  (leading '-' = equivalent patch already upstream; signal 1 fires)

gh -R smartwatermelon/scripts pr list --state merged \
   --head claude/fix-scripts-log-show-false-ok-i112 --json number,mergedAt,title
# -> [{"number":116,"mergedAt":"2026-08-08T00:17:29Z",...}]  (signal 2 fires)
```

Signal 1 short-circuits, so this branch exercises the cherry path and is reported as
`cherry-equivalent`. It does **not** prove signal 2 in isolation — that is covered by the
`gh` call above returning PR #116 directly, and by Task 5 Step 1's unit tests. Do not
expect `+` prefixes here.

- [ ] **Step 8: Commit**

```bash
git add lib/repo-walker.sh tests/repo-walker.bats
git commit -m "feat(repo-walker): add --show-dead-branches and --status

git branch --merged is useless against squash merges: the original
commits never land in main, so it lists nothing in exactly the repos with
the most stale branches. Three signals instead -- git cherry, merged-PR
lookup, and a per-file content check -- reported as three categories
rather than one boolean.

Reports only; never deletes. Tip SHAs print because they are the reflog
recovery path after a -D.

Closes #122"
```

---

### Task 6: Documentation

**Files:**

- Modify: `README.md:42-43` (script rows), `README.md` Conventions and Subdirectories
- Modify: `CLAUDE.md` (Script Categories, File Locations & Dependencies)

**Interfaces:**

- Consumes: the final flag set and file layout from Tasks 1–5.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Update the two script rows in `README.md`**

Replace the `pull-my-repos.sh` and `pull-beacon-repos.sh` rows:

```markdown
| `my-repos.sh` | For every repo in `~/Developer` owned by `smartwatermelon` or `nightowlstudiollc`: show status, pull if clean. `--check` for offline dirty-report only; `--show-prs`, `--show-issues`, and `--show-dead-branches` report open PRs, open issues, and merged-but-undeleted local branches; `--status` enables all three; `--quiet` trims output. Override the directory with `MY_REPOS_DIR`. |
| `beacon-repos.sh` | Same flags as `my-repos.sh`, for repos in `~/Developer/beacon-biosignals` owned by `beacon-biosignals`. Both are thin wrappers over `lib/repo-walker.sh`. Override the directory with `BEACON_REPOS_DIR`. |
```

- [ ] **Step 2: Add the env-var convention**

In `README.md` under `## Conventions`, after the "Shared helpers" bullet:

```markdown
- Repo-walking scripts take their target directory from an env var with a
  sensible default: `MY_REPOS_DIR` (`my-repos.sh`), `BEACON_REPOS_DIR`
  (`beacon-repos.sh`). A missing directory warns and exits 0 rather than
  failing, so `allup` still passes on a machine that legitimately lacks one.
```

- [ ] **Step 3: Add `lib/` to Subdirectories**

In `README.md` under `## Subdirectories`, before the `docs/plans/` bullet:

```markdown
- `lib/` — shared bash libraries, sourced by scripts rather than executed.
  Not executable, not symlinked into `~/.local/bin`. `repo-walker.sh` backs
  `my-repos.sh` and `beacon-repos.sh`.
```

- [ ] **Step 4: Update `CLAUDE.md`**

In **Script Categories → Development Tools**, replace `pull-my-repos.sh` with
`my-repos.sh`, `beacon-repos.sh`.

In **File Locations & Dependencies**, after the existing symlink bullet:

```markdown
- Files under `lib/` are sourced libraries, not commands: mode `644`, no
  shebang execution, and deliberately not symlinked into `~/.local/bin`.
  `lib/repo-walker.sh` holds the logic for `my-repos.sh` and `beacon-repos.sh`,
  which are configuration-only wrappers.
```

- [ ] **Step 5: Verify no stale references remain**

```bash
grep -rn 'pull-my-repos\|pull-beacon-repos' README.md CLAUDE.md
```

Expected: no output. (Hits inside `docs/plans/` are historical design docs and are
correct to leave alone.)

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: update README and CLAUDE.md for the wrapper rename

Documents the new flags, the MY_REPOS_DIR / BEACON_REPOS_DIR overrides,
and lib/ as a sourced-library directory whose contents are deliberately
not executable or symlinked.

Refs #122, #123"
```

---

### Task 7: Full verification and PR

**Files:** none modified — verification only.

**Interfaces:**

- Consumes: everything from Tasks 1–6.
- Produces: a pushed branch and an open PR.

- [ ] **Step 1: Run the full test suite**

Protocol 3 requires the full suite, not just the file you touched:

```bash
bats tests/repo-walker.bats tests/smb-mount.bats tests/ssh-wrapper.bats
```

Expected: all pass. If `smb-mount.bats` or `ssh-wrapper.bats` fail, check whether they
failed before this work — do not claim a pre-existing failure as passing, and do not
silence it.

- [ ] **Step 2: Shellcheck everything**

```bash
shellcheck -S info lib/repo-walker.sh my-repos.sh beacon-repos.sh tests/repo-walker.bats
for s in *.sh; do shellcheck -S info "${s}" || echo "FAILED: ${s}"; done
```

Expected: no output, no `disable` directives anywhere.

- [ ] **Step 3: Verify file modes**

```bash
ls -l my-repos.sh beacon-repos.sh lib/repo-walker.sh
```

Expected: `755` on both wrappers, `644` on the library. The pre-commit hook rejects
non-executable scripts, so a wrong mode blocks the commit.

- [ ] **Step 4: Verify on arich-mac against the real beacon repos**

Non-interactive `ssh` does not source the profile, so `gh` is absent from `PATH` and
`bash -lc` resolves to macOS bash 3.2 — under which `gh-wrapper.sh` fails on `mapfile`.
Use the bash 5 path explicitly:

```bash
ssh arich-mac.local '/opt/homebrew/bin/bash -lc "
  cd ~/Developer/scripts &&
  git fetch -q origin claude/shared-repo-core-i122-i123-f16a6166 &&
  git checkout -q FETCH_HEAD &&
  ./beacon-repos.sh --check
"'
```

Expected: five `beacon-biosignals` repos walked — `beabot`, `infra`, `knowledge-base`,
`platform-datastore`, `platform-production` — and `git-pkgs-proxy` **absent**, since it
belongs to `andrewmrich` and must be filtered out by `REPO_WALKER_ORGS`. A `Total: 0`
there means the path fix did not take.

Network report modes cannot run over SSH: `gh` stores its token in the **keyring**, which
an unattended session cannot unlock, so calls return `HTTP 401`. That is expected and not
a fault — those paths are verified on this machine. Do not report it as a failure.

Leave that checkout on a detached HEAD; the user updates it themselves after merge.

- [ ] **Step 5: Pre-commit verification block**

Output this before pushing, per Protocol 4:

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: claude/shared-repo-core-i122-i123-f16a6166 — NOT main
□ Tests: [bats result]
□ Code review: [hook verdict]
□ Commit message: [format verified]
VERDICT: [READY TO COMMIT / BLOCKED - reason]
```

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin claude/shared-repo-core-i122-i123-f16a6166
gh pr create --title "refactor: shared repo-walker core, rename, --show-issues, --show-dead-branches" --body "$(cat <<'EOF'
## Summary

Extracts the duplicated logic behind `pull-my-repos.sh` and `pull-beacon-repos.sh` into
`lib/repo-walker.sh`, renames both to `my-repos.sh` / `beacon-repos.sh`, and adds
`--show-issues`, `--show-dead-branches`, and `--status`.

The two scripts were byte-identical except for `DEVDIR`, `ORGS`, and name strings, so
implementing both issues as written would have meant four implementations of two features.

## Bug found along the way

`pull-beacon-repos.sh` has pointed at `~/Developer/beacon` since #106, but the repos live
in `~/Developer/beacon-biosignals`. It reported `Total: 0` while five repos sat one
directory over, so `allup` has never pulled them. `DEVDIR` is now overridable, and a
missing or zero-match directory warns by name instead of printing a bare `Total: 0`.

## Not in this PR

`allup` in `smartwatermelon/dotfiles` still calls the old names. It guards with
`command -v`, so removing the old symlinks before that lands would make `allup` **skip
repo pulls and still report success**. Sequence: this PR → dotfiles PR → symlink cleanup
on both machines.

## Testing

- `tests/repo-walker.bats` — 21 tests
- `--check`, `--check --quiet`, `--help`, and the unknown-argument path verified
  byte-identical to the pre-refactor script
- Dead-branch detection validated against `claude/fix-scripts-log-show-false-ok-i112`
  (PR #116, squash-merged) — caught by signal 2, missed by signal 1, which is the case
  the design exists for
- Beacon wrapper verified on arich-mac against the five real repos, correctly skipping
  `git-pkgs-proxy` (wrong org)

Spec: `docs/plans/2026-08-19-shared-repo-core-design.md`

Closes #122
Closes #123
EOF
)"
```

- [ ] **Step 7: Surface the PR to the user**

Protocol 6 requires reporting any new PR in the same turn: repo, number, URL, and one
line on what it addresses. Then run the post-push loop:

```bash
bash ~/.claude/scripts/post-push-status.sh <PR#>
```

Do not merge. Merging needs green CI **and** a merge-lock the user creates.

---

### Task 8: dotfiles — update `allup`

**A separate repository.** Do not start until Task 7's PR is merged: while the scripts PR
is open, `my-repos` does not exist on disk yet, and pointing `allup` at it early creates
the same silent-skip window in reverse.

**Files:**

- Modify: `~/Developer/dotfiles/bash/functions.sh:845` (comment), `:880-881` (calls)

**Interfaces:**

- Consumes: `my-repos` / `beacon-repos` commands from the merged scripts PR.
- Produces: nothing.

- [ ] **Step 1: Branch**

```bash
git -C ~/Developer/dotfiles switch main
git -C ~/Developer/dotfiles pull
git -C ~/Developer/dotfiles checkout -b claude/allup-repo-rename-f16a6166
git -C ~/Developer/dotfiles branch --show-current   # must NOT be main
```

- [ ] **Step 2: Update the calls**

At `bash/functions.sh:880-881`, replace:

```bash
    if command -v pull-my-repos &>/dev/null; then pull-my-repos || return $?; fi
    if command -v pull-beacon-repos &>/dev/null; then pull-beacon-repos || return $?; fi
```

with:

```bash
    if command -v my-repos &>/dev/null; then my-repos || return $?; fi
    if command -v beacon-repos &>/dev/null; then beacon-repos || return $?; fi
```

- [ ] **Step 3: Update the comment**

At `:845`, replace `# pull-my-repos and pull-beacon-repos are from ~/Developer/scripts, symlinked into ~/.local/bin`
with:

```bash
# my-repos and beacon-repos are from ~/Developer/scripts, symlinked into ~/.local/bin
```

- [ ] **Step 4: Verify no stale references**

```bash
grep -rn 'pull-my-repos\|pull-beacon-repos' ~/Developer/dotfiles/bash/ ~/Developer/dotfiles/README.md
```

Expected: no output. `dotfiles/README.md` was checked during design and mentions neither.

- [ ] **Step 5: Shellcheck and the existing allup test**

```bash
shellcheck -S info ~/Developer/dotfiles/bash/functions.sh
bash ~/Developer/dotfiles/bash/tests/test-allup-continue-state.sh
```

Expected: clean, and the state-machine test passes. That test guards the
`--continue` skip-pulls logic this task touches the neighborhood of.

- [ ] **Step 6: Verify `allup` resolves the new commands**

`functions.sh` is symlinked from `~/.config/bash/`, so the edit is live in a new shell.
Bash caches command locations, and `command -v` reads that same cache — so it will report
stale paths. Use `which`:

```bash
bash -lc 'hash -r; which my-repos; which beacon-repos'
```

Expected: both resolve under `~/.local/bin`. If either is missing, the scripts PR has not
been deployed via symlink yet — do **not** proceed to commit, because `command -v` would
silently skip that pull.

- [ ] **Step 7: Commit and PR**

```bash
git -C ~/Developer/dotfiles add bash/functions.sh
git -C ~/Developer/dotfiles commit -m "fix(allup): call my-repos/beacon-repos after rename

The scripts were renamed in smartwatermelon/scripts. allup guards these
calls with command -v, so a stale name means allup skips the repo pulls
and still exits 0 -- silent, not loud. Updated together with the comment
naming them."
git -C ~/Developer/dotfiles push -u origin claude/allup-repo-rename-f16a6166
gh -R smartwatermelon/dotfiles pr create --title "fix(allup): call my-repos/beacon-repos after rename" --body "Follows smartwatermelon/scripts#<PR>. allup guards with \`command -v\`, so stale names would make it skip repo pulls while still reporting success."
```

Surface the PR to the user. Do not merge without green CI and a merge-lock.

---

### Task 9: Symlink cleanup (manual, after both PRs merge)

**Not a git operation.** Runs on two machines, and only once both PRs are merged. Present
these commands to the user rather than assuming authority to reshape their `~/.local/bin`.

- [ ] **Step 1: This machine**

```bash
ln -sf ~/Developer/scripts/my-repos.sh     ~/.local/bin/my-repos
ln -sf ~/Developer/scripts/beacon-repos.sh ~/.local/bin/beacon-repos
rm -f ~/.local/bin/pull-my-repos ~/.local/bin/pull-beacon-repos
hash -r
```

- [ ] **Step 2: Verify in a new shell**

```bash
which my-repos beacon-repos
my-repos --check --quiet
beacon-repos --check   # expect the missing-directory warning, exit 0
```

`which`, not `command -v`: the latter consults bash's hash table and will report a stale
path even after the symlink changes.

- [ ] **Step 3: arich-mac**

The user handles this one — they said they would update that checkout themselves. The
commands are the same, with `git -C ~/Developer/scripts pull` first, and
`beacon-repos --check` should walk five repos rather than warn.

- [ ] **Step 4: Confirm `allup` still works end to end**

```bash
bash -lc 'hash -r; allup --continue'
```

Expected: repo pulls run rather than being skipped. A run that completes suspiciously
fast, with no per-repo output, means `command -v` found nothing — the exact silent
failure this ordering exists to prevent.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Shared core + wrapper contract | 1, 2 |
| `SCRIPT_DIR` through symlink | 2 (Step 8) |
| `usage()` prints wrapper name | 1 |
| Beacon path bug + configurable `DEVDIR` | 2 (Step 5) |
| Missing/empty directory warning | 3 |
| `--show-issues` | 4 |
| Three-call-site dispatch bug | 4 (Step 4) |
| `--show-dead-branches`, three signals, three categories | 5 |
| `--status` | 5 (Step 5) |
| Cross-cutting guards (`--check`, `--quiet`, preflight) | 4 (Step 4), 5 (Step 5) |
| Documentation (README, CLAUDE.md) | 6 |
| `dotfiles/README.md` needs no change | 6 (Step 5 note), 8 (Step 4) |
| Byte-identical regression check | 2 (Steps 1, 6) |
| Known-dead-branch validation | 5 (Step 7) |
| arich-mac real-data testing | 7 (Step 4) |
| Rollout ordering / silent-skip hazard | 7, 8, 9 |

No gaps.

**Placeholder scan:** No `TBD`/`TODO`, no "add error handling", no "similar to Task N".
Every code step carries real code.

**Type consistency:** `repo_walker_run_reports` is introduced in Task 4 with signature
`(short, remote)` and changed to `(short, remote, repo)` in Task 5 Step 5 — the change is
called out explicitly, with instructions to update all three call sites.
`REPO_WALKER_DIRVAR` is added in Task 3 Step 3 and added to `require_config`'s checks in
the same step, so Task 1's four-variable validation stays consistent. Colour globals are
renamed once, in Task 2 Step 4, and used under the new names everywhere after.

**One known ordering constraint:** Task 3's tests invoke `my-repos.sh` as a subprocess
rather than sourcing the library, because the missing-directory path is only reachable
through `repo_walker_main`. That requires Task 2 to be complete, which it is.
