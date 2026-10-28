# Plan: dotall-fleet, a simple replacement for allup-fleet

**Status:** paused 2026-10-27, waiting on the permission policy
(`smartwatermelon/dev-env` `docs/plans/2026-10-27-permission-policy.md`)
**Date:** 2026-10-27
**Author:** arich (drafted by Claude Code)

## Problem

`allup-fleet.sh` runs `allup` on every host in tmux panes. It is too
complicated and does not work, and it was built without basic acceptance
tests. What is actually needed is smaller: after a change to dotfiles,
claude-config or another core repo, sync the GitHub repos and refresh the dev
environment on every Mac.

`allup` is out of scope. It does much more, it should run on a schedule,
alert when it cannot finish, and fix itself. That is a separate effort.

## Scope

1. For each host, enumerated the same way as lock-sync
   (`~/Developer/lock-sync/bin/list-clients`):
   1. If the host is unavailable, warn and continue.
   2. Run `ssh <host>.local "bash -lic 'my-repos && dotall'"`.

No exit-code handling beyond the warning, no retries, no auto-correction, no
tmux.

## Facts checked on 2026-10-27

- `list-clients` returns `asiago.local`, `mimolette.local`, `tilsit.local`,
  `arich-mac.local`. It reads the Synergy config, so the script runs on ASIAGO
  only.
- **SSH users come from `~/.ssh/config`, not from lock-sync's config.**
  lock-sync's `~/.config/lock-sync/config` sets `tilsit.local operator`, the
  screen-lock user. `~/.ssh/config` maps `tilsit` to `andrewrich` and
  `arich-mac` to `arich`, so a bare `ssh <host>` picks the right dev user.
- `dotall` is an alias (`dotfiles && dotclaude`, `dotfiles/bash/aliases.sh`).
  Aliases expand only in an interactive shell, so the `-i` in `bash -lic` is
  required.
- Acceptance test, by hand: `ssh -n tilsit.local "bash -lic 'my-repos &&
  dotall'"` ran to the end (claude-config deployed). No prompt needed a TTY.
  `arich-mac` was off and is untested; its `~/.ssh/config` entry sets the
  user.

## Decisions

- Replace `allup-fleet.sh`, `tests/allup-fleet.bats` and the README row.
- Name: `dotall-fleet`, because it no longer runs `allup`.
- ASIAGO updates itself with a plain `ssh asiago.local` (needs Remote Login
  on). No special case for the local host.
- Hosts run one after another. A failed or unreachable host gets a warning;
  the run continues and exits 1 at the end with the list of failed hosts.

## Blocked on

The permission policy names two items that decide whether this can run from
a Claude session:

1. **`.local` names do not resolve inside the sandbox** when `ssh` is not the
   leading command (here it runs inside a script). Options: add the script to
   `excludedCommands`, or find why mDNS fails in the sandbox. Test this first.
2. **The classifier denied `ssh tilsit.local 'git pull'`** once as "Remote
   Shell Writes". The policy proposes `autoMode.allow` prose for dev-sync
   commands on the personal LAN hosts; `arich-mac.local` stays read-only.
   Note: `my-repos && dotall` on `arich-mac` writes to that machine. Decide
   whether the fleet run skips it or whether its read-only rule changes.

From a plain terminal, neither applies.

## Steps when resumed

1. Settle the two blockers above.
2. Create a worktree with the procedure in the permission policy.
3. Add the script and tests below. Run `shellcheck -S info` and the bats file.
4. `git rm` `allup-fleet.sh` and `tests/allup-fleet.bats`; update the README.
5. Acceptance test on the real fleet, from a terminal and from a Claude
   session: all reachable hosts sync; an off host warns and the rest run.
6. Re-point the symlink (outside the sandbox):
   `ln -sfn ~/Developer/scripts/dotall-fleet.sh ~/.local/bin/dotall-fleet`
   and remove `~/.local/bin/allup-fleet`.

The branch `claude/feat-dotall-fleet-cbe34707` exists from the first attempt
and holds no commits beyond `main`. Andrew chose to leave it.

## Draft script (shellcheck clean)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Sync GitHub repos and refresh the dev environment on every Synergy client:
# runs `my-repos && dotall` on each host from lock-sync's list-clients, in turn.
# An unreachable or failing host gets a warning; the rest still run.
# SSH users come from ~/.ssh/config, not lock-sync's config (that one names
# the screen-lock user, e.g. operator on tilsit).

list_clients="${LIST_CLIENTS:-${HOME}/Developer/lock-sync/bin/list-clients}"
# -i: dotall is an alias, and aliases only expand in an interactive shell.
remote="bash -lic 'my-repos && dotall'"

hosts="$("${list_clients}")" || {
  echo "dotall-fleet: list-clients failed" >&2
  exit 1
}
if [[ -z "${hosts}" ]]; then
  echo "dotall-fleet: list-clients found no hosts" >&2
  exit 1
fi

failed=()
while IFS= read -r host; do
  [[ -n "${host}" ]] || continue
  printf '\n=== %s ===\n' "${host}"
  # -n: without it ssh reads the remaining hosts off this loop's stdin.
  rc=0
  ssh -n -o ConnectTimeout=5 "${host}" "${remote}" || rc=$?
  if ((rc != 0)); then
    echo "dotall-fleet: WARN ${host} failed or unreachable (rc=${rc}); continuing" >&2
    failed+=("${host}")
  fi
done <<<"${hosts}"

if ((${#failed[@]} > 0)); then
  printf '\ndotall-fleet: failed: %s\n' "${failed[*]}" >&2
  exit 1
fi
```

## Draft tests (5 of 5 passed locally, stubs only)

`tests/dotall-fleet.bats` stubs `ssh` (it logs each call and exits 255 for
hosts in `STUB_FAIL`) and `list-clients` (`LIST_CLIENTS`). Cases:

1. Each host gets `ssh -n` with `bash -lic 'my-repos && dotall'`.
2. Hosts are passed bare (no `user@`), so `~/.ssh/config` picks the user.
3. An unreachable host warns with its exit code, the next host still runs,
   and the script exits 1 naming the failed host.
4. A `list-clients` failure exits 1 without running ssh.
5. An empty host list exits 1 without running ssh.
