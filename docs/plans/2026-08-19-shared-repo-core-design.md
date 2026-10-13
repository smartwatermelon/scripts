# Shared repo-walker core, wrapper rename, and two new report modes

**Date:** 2026-08-19
**Issues:** [#122](https://github.com/smartwatermelon/scripts/issues/122), [#123](https://github.com/smartwatermelon/scripts/issues/123)
**Status:** Awaiting review

## Problem

`pull-my-repos.sh` and `pull-beacon-repos.sh` are 275 lines each and **byte-identical
except for six lines**: `DEVDIR`, `ORGS`, three name strings in comments/usage, and one
word in a comment ("orgs" vs "org"). Every feature added to one must be added, reviewed,
and tested twice.

Issues #122 and #123 each add a report mode to `pull-my-repos.sh`. Implementing them as
written would duplicate both features across both files — four implementations of two
features. Issue #123 also renames the script, on the grounds that "pull" describes only
one of its modes.

Three things follow from that, and they set the scope of this design:

1. The duplication should be removed before new features land, not after.
2. The rename spans a second repository (`smartwatermelon/dotfiles`), because `allup`
   invokes both scripts by name.
3. `allup`'s invocation is guarded by `command -v`, which turns a missed rename into a
   **silent** failure rather than a loud one. This drives the merge ordering.

## The silent-skip hazard

`~/Developer/dotfiles/bash/functions.sh:880-881`:

```bash
if command -v pull-my-repos &>/dev/null; then pull-my-repos || return $?; fi
if command -v pull-beacon-repos &>/dev/null; then pull-beacon-repos || return $?; fi
```

If the `pull-my-repos` symlink is removed before `allup` is updated, `command -v` returns
false, the branch is skipped, and **`allup` completes successfully having pulled
nothing**. There is no error, no warning, and no output distinguishing it from a run where
every repo was already up to date. The repo sync — the entire point of `allup` — would
stop happening, and the first symptom would be stale repos noticed by accident days later.

`~/.config/bash/functions.sh` is a symlink into the dotfiles repo, so an edit to the repo
file takes effect in new shells immediately; there is no separate install step and no
staging buffer.

This hazard dictates the ordering in "Rollout" below. It is the single most important
constraint in this design.

## Goals

- One implementation of the repo-walking logic, consumed by two commands.
- `--show-issues` (#123) and `--show-dead-branches` (#122), each written once.
- `--status` shorthand enabling all network report modes.
- Rename `pull-my-repos.sh` → `my-repos.sh`, `pull-beacon-repos.sh` → `beacon-repos.sh`.
- `allup` updated to the new names, with no window in which it silently skips pulls.
- README and CLAUDE.md updated in both repos, so no doc outlives the rename.
- Fix the beacon path bug, and make `DEVDIR` configurable so it cannot recur silently.

## Non-goals

- **No branch deletion.** `--show-dead-branches` reports and suggests; it never runs
  `git branch -D`. Deletion requires `-D` (force) because squash merges leave branches
  permanently "unmerged" to git, and a wrong `-D` loses work.
- No change to pull/check/PR behavior. This is a refactor plus two additive flags;
  existing output for existing flags stays byte-identical.
- No new dependencies beyond the `gh`/`jq` already required by `--show-prs`.

## Live bug: beacon script has never worked

`pull-beacon-repos.sh` sets `DEVDIR="${HOME}/Developer/beacon"`, but the beacon repos
live in `~/Developer/beacon-biosignals/`. Verified by running the deployed script on
arich-mac, where it reports `Total: 0` while five `beacon-biosignals` repos sit one
directory over.

`git log -L 71,71:pull-beacon-repos.sh` shows the path has been wrong since the file was
introduced in #106 — nothing regressed, it never worked. `allup` calls it, so beacon
repos have never been pulled by `allup` on that machine.

This is the **same failure shape as the `allup` hazard**: a command that exits 0 and
prints a plausible "nothing to do" while doing nothing. Two design consequences:

1. **`DEVDIR` becomes configurable** rather than hardcoded, so a per-machine path
   mismatch does not require editing a tracked file.
2. **A missing or empty target directory warns by name**, rather than reporting a bare
   `Total: 0`. This is what turns the next occurrence of this bug from silent into
   obvious, without failing `allup` on machines that legitimately lack a directory.

### Configuration

Each wrapper takes its directory from an environment variable, falling back to a default:

| Wrapper | Env var | Default |
|---|---|---|
| `my-repos.sh` | `MY_REPOS_DIR` | `~/Developer` |
| `beacon-repos.sh` | `BEACON_REPOS_DIR` | `~/Developer/beacon-biosignals` |

```bash
REPO_WALKER_DEVDIR="${BEACON_REPOS_DIR:-${HOME}/Developer/beacon-biosignals}"
```

Zero-config on a machine matching the default; one env var otherwise. No `--dir` flag —
this is set once per machine, not per invocation, so a flag would be verbose for the
common case and add surface area to document and test.

### Missing-directory behavior

A missing directory is **a warning with exit 0**, not an error. Two distinct cases,
deliberately given different treatment:

| Case | Behavior | Why |
|---|---|---|
| Directory does not exist | Warn on stderr, exit 0 | A legitimate machine state — this laptop will never have beacon repos |
| Directory exists but walk finds 0 matching repos | Warn on stderr, exit 0 | The bug case: path exists but `ORGS` matched nothing |

```
Warning: repo directory not found: /Users/andrewrich/Developer/beacon-biosignals
         nothing to do. Set BEACON_REPOS_DIR to override.
```

Exit 0 keeps `allup` working on machines that legitimately lack a directory. This laptop
has no beacon repos and never will — a hard error there would fail `allup` permanently on
a *correct* configuration, and a failure you must learn to ignore is worse than no
failure at all, because it trains you to ignore real ones.

**What still prevents the original bug.** The bug hid because `Total: 0` looks identical
to "nothing to do". The fix is not a non-zero exit; it is making the two distinguishable:

- A missing directory says so **by name**, rather than reporting a clean `Total: 0`.
- A directory that exists but matches no repos also warns — that is the exact shape of
  the beacon bug, and it stays loud even though it exits 0.
- Both warnings name the env var that overrides the path, so the fix is in the message.

The summary line is never the only signal. `Total: 0` on its own is no longer reachable
without an accompanying warning explaining which of the two happened.

## Architecture

### Layout

| Path | Role | Executable | Symlinked into `~/.local/bin` |
|---|---|---|---|
| `lib/repo-walker.sh` | All logic | No (`644`) | No — library, not a command |
| `my-repos.sh` | `~/Developer`, smartwatermelon\|nightowlstudiollc | Yes (`755`) | Yes, as `my-repos` |
| `beacon-repos.sh` | `~/Developer/beacon`, beacon-biosignals | Yes (`755`) | Yes, as `beacon-repos` |

`lib/repo-walker.sh` is deliberately **not** executable and **not** symlinked. It is not a
command; running it directly with no configuration set is a usage error, and it will say
so and exit 2 rather than walking a default directory.

### Wrapper contract

A wrapper sets three variables and sources the core. Complete text of `my-repos.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# my-repos.sh — For each repo in ~/Developer owned by
# smartwatermelon or nightowlstudiollc: show status, pull if clean.
#
# Configuration for lib/repo-walker.sh, which holds all logic.

REPO_WALKER_DEVDIR="${MY_REPOS_DIR:-${HOME}/Developer}"
REPO_WALKER_ORGS="smartwatermelon|nightowlstudiollc"
REPO_WALKER_DESC="Pull all repos in ~/Developer owned by smartwatermelon or nightowlstudiollc."

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/repo-walker.sh
source "${SCRIPT_DIR}/lib/repo-walker.sh"
```

`beacon-repos.sh` is the same five values with beacon's directory, org, and description.

Three details this pins down:

**Resolving `SCRIPT_DIR` through the symlink.** Wrappers are invoked via
`~/.local/bin/my-repos`, a symlink. `dirname "${BASH_SOURCE[0]}"` gives the directory of
the *link*, so `cd`-and-`pwd` alone lands in `~/.local/bin`, where `lib/repo-walker.sh`
does not exist — verified to fail exactly that way. `realpath` resolves the link first,
which is why it appears above; the repo's own `ssh` wrapper uses the same idiom
(`SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"`), and `realpath` is at `/bin/realpath` on
both machines. `BASH_SOURCE[-1]` still reports the *invoked* name, so `usage()` prints
what the user typed.

**`usage()` prints the wrapper's name.** The core derives it as
`"$(basename "${BASH_SOURCE[-1]}")"` — the outermost frame in the source stack, which is
the wrapper, not the library. So `my-repos --help` says `Usage: my-repos.sh [OPTIONS]`
and beacon's says `beacon-repos.sh`. `REPO_WALKER_DESC` supplies the one-line summary.

**`set -euo pipefail` crosses the source boundary.** Shell options are process-global, not
per-file, so the wrapper's `set -euo pipefail` governs the sourced core. The core does not
re-set them; it validates that its three required variables are set and non-empty, and
exits 2 with a clear message if not.

**Naming.** Every core-owned global is prefixed `REPO_WALKER_`, so a wrapper can never
shadow a core internal by accident.

### Why source, not exec

Sourcing keeps configuration in plain variables with no argument parsing between wrapper
and core, and leaves the core free to consume `"$@"` as the *user's* flags rather than a
mix of config and user input. The alternative — `exec lib/repo-walker.sh --devdir ... --orgs ... "$@"` —
would require the core to distinguish its own configuration flags from user flags, which
is more surface area for no benefit. Sourcing also keeps a single process, so `set -e`
semantics and exit codes behave exactly as they do today.

## Feature: `--show-issues` (#123)

`show_issues_for_repo()` mirrors `show_prs_for_repo()` exactly: same non-GitHub-remote
skip, same `owner_repo` extraction, same non-fatal failure handling (`return`, never
`exit`, so one bad repo does not abort the run).

```bash
gh -R "${owner_repo}" issue list --state open \
   --json number,title,labels,author,assignees
```

Output, matching the PR block's shape:

- **Normal:** `open issues: N`, then `#123  Title  [bug,ci] by author`
- **Quiet:** `<repo>: N open issue<s>`, with the same singular/plural handling

**Rendering difference from PRs.** `labels` and `assignees` are arrays of objects, not
scalars — unlike every field `--show-prs` uses. The jq expression maps to `.name`/`.login`
and joins, and **omits the bracket group entirely when the array is empty** rather than
printing a bare `[]`:

```jq
.[] | "    #\(.number)  \(.title)" +
      (if (.labels | length) > 0 then "  [\([.labels[].name] | join(","))]" else "" end) +
      "  by \(.author.login)"
```

## Feature: `--show-dead-branches` (#122)

### Why `git branch --merged` is not usable

Squash merge is the only merge command the workflow permits. It replays a branch's changes
as one new commit with a new hash, so the branch's original commits never appear in the
default branch's history. Consequently `git branch --merged main` lists **nothing**,
`git rev-list --count main..<branch>` reports commits that are in fact already upstream,
and `git branch -d` always refuses. A `--merged`-based implementation reports zero dead
branches precisely in the repos that have the most.

### Three signals, cheapest first

Per branch, **excluding the default branch and the currently-checked-out branch**:

1. **`git cherry <default> <branch>`** — a `-` prefix marks a patch with an equivalent
   already upstream. Offline, conclusive when it fires.
2. **Merged-PR lookup** — `gh -R "$owner_repo" pr list --state merged --head "$branch"
   --json number,mergedAt,title`. Catches squash-merges that signal 1 misses. Verified to
   return `[]` with exit 0 for a branch with no PR, so absence needs no special-casing.
3. **Per-file content check**, only for branches matched by signal 2 alone:

   ```bash
   base=$(git merge-base "$default" "$branch")
   git diff --name-only "$base" "$branch"   # then git diff --quiet per file
   ```

   Differing files are usually just branch age. But this is what distinguishes a branch
   holding real unmerged work from a genuinely dead one, so it is reported rather than
   collapsed away.

### Three categories, never one boolean

| Category | Meaning | Output |
|---|---|---|
| **Dead** | Signal 1, or signal 2 with no differing files | `git -C <repo> branch -D <branch>    # PR #152, merged 2026-08-08` |
| **Merged PR, files differ** | Signal 2 positive, signal 3 found differences | Branch, PR, and the differing file list — for a human to look at |
| **Unpushed work** | No PR, commits not in default branch | Flagged as its own category |

The reasons differ in strength, so collapsing them to "dead: yes/no" would either hide
real work or over-report. Tip SHAs are printed for every reported branch: after a `-D`,
the SHA is the only reflog recovery path.

**Report only.** The script prints the suggested command; the human runs it.

**Quiet mode:** `<repo>: 7 dead branches`.

## Feature: `--status`

Sets `SHOW_PRS`, `SHOW_ISSUES`, and `SHOW_DEAD_BRANCHES` all true — "everything
outstanding across my repos". Being purely a shorthand, it inherits each flag's own
`--check` suppression and preflight behavior with no special-casing.

## Cross-cutting flag handling

Three existing guards test `SHOW_PRS` alone and must generalize to "any network flag",
or `--show-issues` used by itself would skip its warning and its dependency check:

1. **`--check` suppression.** `--check` promises no network access. Each network flag is
   suppressed with its own named warning.
2. **`--quiet` no-op note.** Currently fires without `--check`/`--show-prs`.
3. **`gh`/`jq` preflight.** Currently gated on `SHOW_PRS`.

**Easily-missed call sites.** `show_prs_for_repo` is invoked at **three** points, not one:
the main path at `:250`, plus two early-`continue` paths — status-check failure (`:160`)
and branch-switch failure (`:196`). The new report modes must be called at all three, or
they would silently skip exactly the repos that are in trouble. The core will route all
three through a single `run_report_modes_for_repo()` helper so a future flag cannot
reintroduce this bug.

## Documentation updates

In scope, not a follow-up. Three places describe this code and all three go stale on
merge.

### `scripts/README.md`

- **`## Scripts` → Development workflow** — the `pull-my-repos.sh` and
  `pull-beacon-repos.sh` rows are renamed to `my-repos.sh` / `beacon-repos.sh` and
  extended with `--show-issues`, `--show-dead-branches`, and `--status`. The beacon row
  currently reads "Same as `pull-my-repos.sh` but for repos in `~/Developer/beacon`" —
  both halves are wrong after this work: it is a wrapper over a shared core, and the
  path was never right. It gets a real description and the corrected path.
- **`## Conventions`** — a line for the env-var overrides (`MY_REPOS_DIR`,
  `BEACON_REPOS_DIR`), alongside the existing notes on logs, secrets, and shared helpers.
  This is where a future reader looks for cross-cutting behavior.
- **`## Subdirectories`** — a `lib/` entry. The section already lists `docs/plans/`,
  `tests/`, and `LaunchAgents/`; a shared-library directory belongs in that list, with a
  note that it holds sourced code rather than executables.

### `scripts/CLAUDE.md`

The **Script Categories** list names `pull-my-repos.sh` under Development Tools, and
**File Locations & Dependencies** states scripts are symlinked from `~/.local/bin/`.
Both need the new names, and the latter needs the distinction that `lib/repo-walker.sh`
is deliberately *not* symlinked or executable — otherwise the next contributor
reasonably assumes every `.sh` here is a command.

The **Common Patterns → Error Handling & Safety** section lists the approved exception
for `smb-mount.sh` omitting `-e`. No change needed: the wrappers and core all keep
`set -euo pipefail`, and the core inherits it across the `source` boundary.

### `dotfiles/README.md`

Checked: it does not mention `pull-my-repos`, `pull-beacon-repos`, or `allup`, so it
needs no change. The only dotfiles edit is `bash/functions.sh` itself (the `allup` body
at `:880-881` and its comment at `:845`). Recorded here so the next reader does not
re-derive the same negative.

## Rollout

Ordering is dictated by the silent-skip hazard. **Old symlinks stay in place until
`allup` no longer references them.**

### PR 1 — `smartwatermelon/scripts`

Shared core, both wrappers, both features, `--status`, README updates.
Closes #122 and #123. `git mv` preserves history and the `+x` bit.

At merge time both old and new symlinks exist, so `allup` keeps working untouched.

### PR 2 — `smartwatermelon/dotfiles`

Update `functions.sh:880-881`:

```bash
if command -v my-repos &>/dev/null; then my-repos || return $?; fi
if command -v beacon-repos &>/dev/null; then beacon-repos || return $?; fi
```

Also update the comment at `:845`, which names the old scripts.

Verified while **both** names still resolve, so a mistake here is recoverable rather than
silent.

### Step 3 — local cleanup, after PR 2 is merged and verified

Not a git operation:

```bash
ln -s ~/Developer/scripts/my-repos.sh     ~/.local/bin/my-repos
ln -s ~/Developer/scripts/beacon-repos.sh ~/.local/bin/beacon-repos
rm ~/.local/bin/pull-my-repos ~/.local/bin/pull-beacon-repos
hash -r
```

`hash -r` is required. Bash caches command locations per session, and `command -v` and
`type` consult that same cache — so both will report the stale path and neither will
reveal the problem. Only `which` (a fresh PATH scan) or `hash -t` shows the true state.
Verify with `which my-repos` in a **new** shell before trusting any result.

**Clean break:** `pull-my-repos` and `pull-beacon-repos` stop working at this step, by
choice.

**Both machines need this.** arich-mac has its own `pull-my-repos` and
`pull-beacon-repos` symlinks in `/Users/arich/.local/bin`, and its own checkout of this
repo. Step 3 runs there too, after `git pull` — otherwise arich-mac keeps the old names
against a repo that no longer has them, and `command -v` sends `allup` down the silent
skip path.

### Step 4 — verify

Run `my-repos --check` and `beacon-repos --check` on both machines. Expected:

- **This laptop:** `beacon-repos` prints the missing-directory warning and exits 0;
  `allup` continues to pass. No env var needed.
- **arich-mac:** `beacon-repos` walks the five `beacon-biosignals` repos and skips
  `git-pkgs-proxy`. A `Total: 0` there would mean the path fix did not take.

## Testing

The refactor's central risk is that a core bug now breaks **both** commands at once, so
the existing behavior is verified before the new flags are.

**Regression — output must be byte-identical.** Capture `--check`, `--check --quiet`,
`--show-prs`, and `--help` from the current `pull-my-repos.sh` *before* the refactor, then
diff against `my-repos.sh` after. Any difference outside the script's own name is a bug.

**Symlink resolution.** Invoke through `~/.local/bin/my-repos`, not by path — this is
where `SCRIPT_DIR` breaks if `BASH_SOURCE` is handled wrong. Also confirm the core exits 2
with a clear message when run directly with no configuration.

**Dead-branch detection against a known-positive.** `smartwatermelon/scripts` currently
holds `claude/fix-scripts-log-show-false-ok-i112`, whose PR #116 was squash-merged. A
clean "0 dead branches" result proves nothing unless detection is first confirmed to fire
on a branch known to be dead — validate against this branch specifically, and confirm
signal 1 (`git cherry`) misses it while signal 2 catches it, which is the exact case that
motivates the design.

**Edge cases** in a scratch repo under the session scratchpad: non-GitHub remote,
`gh` fetch failure (non-fatal, run continues), repo with no branches beyond default,
detached HEAD, empty label/assignee arrays, and a branch whose name needs quoting.

**Static analysis.** `shellcheck -S info` clean on all three files, with **no `disable`
directives**. The core needs `# shellcheck source=lib/repo-walker.sh` on the wrappers'
`source` lines — a source-path hint, not a suppression. Confirm `+x` on both wrappers and
`644` on the library before commit; the pre-commit hook rejects non-executable scripts.

### Remote testing on arich-mac.local

`arich-mac.local` is reachable over passwordless SSH and holds the real beacon repos, so
the beacon wrapper is verified against production data rather than a synthetic fixture.
Note its home directory is `/Users/arich`, not `/Users/andrewrich`.

What that machine provides:

- **Five `beacon-biosignals` repos** under `~/Developer/beacon-biosignals/` — `beabot`,
  `infra`, `knowledge-base`, `platform-datastore`, `platform-production`.
- **A negative case for the `ORGS` filter.** `git-pkgs-proxy` sits in the same directory
  but its origin is `andrewmrich/git-pkgs-proxy` — it must be skipped. This is a real
  in-tree repo, better evidence than a constructed fixture.
- **`infra` has 6 local branches**, exercising the dead-branch walk and `git cherry`.

**Running commands over SSH requires a login shell with bash 5.** Non-interactive `ssh`
does not source the profile, so `gh` is absent from `PATH` and `bash -lc` picks up macOS's
bash 3.2 — under which `gh-wrapper.sh` dies on `mapfile` (a bash 4+ builtin). Neither is a
fault on arich-mac; both are artifacts of how the command is invoked. Test with:

```bash
ssh arich-mac.local '/opt/homebrew/bin/bash -lc "my-repos --check"'
```

`gh` there is 2.97.0 and works correctly under bash 5.

**`gh` on arich-mac is fully authenticated — but not from a non-interactive SSH
session.** Interactively, `gh auth status` shows two accounts (`andrewmrich` active,
`smartwatermelon`) logged in via the **keyring** backend. Over `ssh`, the same command
reports both tokens invalid and an API call returns `HTTP 401`, because the session
cannot unlock the login keychain. `~/.config/gh/hosts.yml` holds only account metadata
(113 bytes, no token) and neither `GH_TOKEN` nor `GITHUB_TOKEN` is set, so there is no
fallback credential for `gh` to find.

The account is healthy; the credential is simply unreachable from an unattended session.
Two ways to exercise the network paths there if wanted:

- Run the command in an interactive shell on arich-mac directly, or
- Export `GH_TOKEN` for a single SSH invocation, which bypasses the keyring.

Neither is required: every network path is verified on this machine, where `gh` is
authenticated and reachable.

Split of coverage:

| Behavior | arich-mac | this machine |
|---|---|---|
| Walk, `ORGS` filter, `--check`, pull | Yes — real beacon repos | Yes — smartwatermelon repos |
| Missing-directory warning | No — directory exists | Yes — no beacon dir here |
| `--show-prs`, `--show-issues`, dead-branch signal 2 | Not over SSH — keyring locked | Yes |

Nothing in the plan blocks on this: every network path is verified on this machine. The
beacon repos remain available as a second real dataset for anyone running those checks
interactively on arich-mac.

## Risks

| Risk | Mitigation |
|---|---|
| `allup` silently skips pulls | Old symlinks outlive the dotfiles change; cleanup is last |
| Core bug breaks both commands | Byte-identical regression diff before new flags |
| `SCRIPT_DIR` fails through symlink | Explicitly tested via `~/.local/bin`, not by path |
| Squash-merged branches undetected | Signal 2 validated against known-dead branch #116 |
| Real work misreported as dead | Signal 3 separates it into its own category; no deletion |
| Stale bash hash after symlink swap | `hash -r` + `which` in a new shell; `command -v` will lie |
| Missing dir silently reports `Total: 0` | Named warning on stderr; `Total: 0` alone is unreachable |
| Warning ignored, real breakage missed | Zero-match warns too, so the beacon bug shape stays loud |

## Open follow-ups

Not in scope, worth filing separately:

- `--show-dead-branches` and `--show-prs` each make a `gh` call per repo. They query
  different `--state` values, so sharing one call was considered and rejected as coupling
  for little gain — revisit if per-repo latency becomes noticeable.
- `pull-beacon-repos.sh` was a copy of its sibling for a second org. If a third org ever
  needs one, the wrapper-over-core shape means adding a five-line file — worth confirming
  that stays true rather than growing per-wrapper logic.
