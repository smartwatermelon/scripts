# SSH Wrapper: Spec and Implementation Plan

**Status:** spec, not yet implemented
**Date:** 2026-04-16

## Context

`~/.local/bin/ssh` intercepts all `ssh` invocations. For hosts that have a
`# op: VARNAME=op://...` annotation in `~/.ssh/config`, it fetches the named
secret from 1Password via `op read` and exports it before handing off to the
real `ssh` binary. For all other hosts it passes through transparently.

### Reference wrappers

Two existing wrappers inform this design. Both are linear scripts (no
`main "$@"` wrapper function):

- **`gh`** — bash function in `~/Developer/dotfiles/bash/functions.sh`
  (symlinked to `~/.config/bash/functions.sh`). A shell-script fallback for
  non-bash shells lives at `~/.local/bin/gh`. There is a standing plan to
  extract the bash function into a script.
- **`claude-wrapper`** — script at `~/Developer/claude-wrapper/bin/`,
  aliased to `claude` and also symlinked from `~/.local/bin/`.

---

## Repository

`~/Developer/scripts`

New file: `ssh` (symlinked to `~/.local/bin/ssh`, consistent with other
scripts in this repo).

The symlink must be created as part of installation; `~/.local/bin` must
appear in `$PATH` **before** `/opt/homebrew/bin` and `/usr/bin` for the
wrapper to intercept calls.

---

## Annotated ssh_config Convention

The wrapper keys off a structured comment in `~/.ssh/config`:

```
Host mimolette
  # op: OP_SERVICE_ACCOUNT_TOKEN="op://Personal/1Password Service Account Auth Token/credential"
  SendEnv OP_SERVICE_ACCOUNT_TOKEN
  HostName mimolette.local
  IdentityFile ~/.ssh/id_ed25519_mimolette
```

- The comment line must match exactly: `# op: VARNAME=op://...`
- One comment line per variable; multiple lines are supported for multiple
  vars
- `SendEnv` line is still required — the wrapper only handles the export;
  `sshd` and `ssh_config` handle forwarding/acceptance
- `VARNAME` must match `[A-Z_][A-Z0-9_]*`
- The value is the literal `op://...` reference string, passed verbatim to
  `op read`

---

## Wrapper Behavior

### Happy path (annotated host)

1. Parse argv to extract the target hostname (strip `user@` prefix if
   present; skip flags and their arguments; lowercase the result)
2. Scan `~/.ssh/config` for `Host` blocks whose pattern(s) match the target
   (see [Matching semantics](#matching-semantics))
3. Collect all `# op: VARNAME=ref` annotations from matching blocks,
   resolving conflicts by specificity rank
4. For each resolved `VARNAME=ref`, call `op read "$ref"`, trim trailing
   whitespace, and export the result
5. `exec` the real `ssh` binary with the original argv unchanged

### Pass-through (unannotated or unknown host)

If no `# op:` lines are found for the target host — or if the target isn't
in `~/.ssh/config` at all, or if the config file doesn't exist — skip
steps 3–4 and go straight to `exec`. Pass-through must be transparent: no
stderr output, no latency beyond parsing.

### Failure handling

If `op read` fails for any resolved annotation, print a message to stderr
identifying the `VARNAME`, the op reference, and the likely cause, then
exit non-zero. Do not fall through to `exec` with a missing variable.

Distinguish the following cases in error output:

| Condition | Detection | Message |
|---|---|---|
| `op` binary not installed | `command -v op` fails | `[ssh-wrapper] op CLI not installed; cannot resolve $VARNAME` |
| `op` not signed in / session expired | `op read` stderr contains `not currently signed in` or exit 1 with empty stdout | `[ssh-wrapper] op session expired; run 'eval $(op signin)' and retry` |
| Reference not found / unauthorized | other `op read` failure | `[ssh-wrapper] op read failed for $VARNAME ($ref): <stderr>` |

---

## Finding the Real ssh Binary

The wrapper must not call itself recursively. Resolve the wrapper's own
canonical path, then scan `type -ap ssh`, skipping any candidate whose
canonical path matches the wrapper's. First non-self match wins.

### `realpath` dependency

Use `realpath "$path"` for canonical resolution. If `command -v realpath`
fails, run `brew install coreutils`. Restrict the code to portable usage:
positional arguments only, no GNU-only flags (`--canonicalize-existing`,
`-m`, `-s`, long options). This works whether the local `realpath` is
BSD or GNU (from coreutils); the wrapper never hardcodes the path.

The wrapper should not pin itself to a specific macOS version; detect
`realpath` at install/first-run time and point the user at
`brew install coreutils` if it's missing, rather than gating on OS
version.

Fallback candidates in order if `type -ap` finds nothing else:

- `/opt/homebrew/bin/ssh`
- `/usr/bin/ssh`

If neither fallback exists, exit non-zero with a clear error.

---

## Target Host Parsing

The parser's only job is to extract the hostname. All flags and arguments
— known or unknown — are passed through to the real `ssh` binary
unchanged. The wrapper never interprets or rewrites them.

### Rules

1. **Case insensitivity** — Lowercase both the extracted hostname and the
   `Host` pattern before comparison.
2. **`--` terminator** — Everything after `--` is treated as
   post-hostname (command and its args). The first token before `--` that
   is neither a flag nor a flag-value is the destination.
3. **Argument-consuming flags** — These flags consume the next token as
   their value when written with a space:
   `-B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w`
4. **Bundled flag-values** — `-p22`, `-oFoo=bar` etc. are single tokens
   and do not consume the next arg.
5. **Long options** — OpenSSH `ssh(1)` does not use GNU-style `--long`
   options, but if one appears, pass it through without special handling.
6. **Destination extraction** — The first token that is not a flag, not a
   flag-value, and not preceded by a flag that consumes it, is the
   destination. Strip leading `user@` if present.
7. **Anything after the destination** is a remote command; do not inspect
   it.

### Examples

| Input | Extracted host |
|---|---|
| `ssh mimolette` | `mimolette` |
| `ssh user@mimolette` | `mimolette` |
| `ssh -p 2222 mimolette ls` | `mimolette` |
| `ssh -p2222 mimolette` | `mimolette` |
| `ssh -L 8080:localhost:80 mimolette` | `mimolette` |
| `ssh -- mimolette --help` | `mimolette` |
| `ssh -i ~/.ssh/foo -J bastion user@MIMOLETTE cmd` | `mimolette` (lowercased) |

---

## Matching Semantics

### Host pattern matching

Within each `Host` line, whitespace-separated tokens are individual
patterns. The block matches the target if **any** token matches.

Supported glob metacharacters:

- `*` — matches any sequence of characters (including empty)
- `?` — matches a single character

Negation patterns (`!foo`) and character classes are not supported;
treat them as literal.

### Specificity ranks

Each matching block gets a rank:

| Pattern shape | Rank |
|---|---|
| Bare `*` (or any token that is `*` alone) | 0 (least specific) |
| Contains `*` or `?` but not bare `*` | 1 |
| Exact literal match | 2 (most specific) |

If one Host line has multiple patterns (`Host foo bar`) and more than one
matches, the block's rank is the **highest** rank of its matching tokens.

### Merge rule

For each `VARNAME`:

1. Collect all `(VARNAME, value, rank)` tuples from blocks matching the
   target.
2. Keep the tuple with the highest rank.
3. If multiple tuples share the highest rank, the one appearing latest in
   the file wins.

> **Deliberate departure from OpenSSH.** OpenSSH's own `ssh_config`
> resolution is first-match-wins per option, processed top-to-bottom.
> This spec uses **last**-match-wins at equal specificity because
> `# op:` annotations are a wrapper-only extension and "override by
> appending below" reads more naturally when users add host-specific
> blocks to the end of an existing config. Do not "fix" this toward
> OpenSSH convention without updating this section — the tie-breaker
> is intentional, not an oversight.

### Example

```
Host *
  # op: FOO=op://shared/foo
  # op: BAR=op://shared/bar

Host *.internal
  # op: FOO=op://internal/foo

Host mimolette
  # op: BAR=op://specific/bar
```

For target `mimolette`:

- `FOO` → `op://shared/foo` (only `Host *` matches; `*.internal` doesn't)
- `BAR` → `op://specific/bar` (rank 2 beats rank 0)

For target `web.internal`:

- `FOO` → `op://internal/foo` (rank 1 beats rank 0)
- `BAR` → `op://shared/bar` (only `Host *` matches)

---

## ssh_config Parsing

Read `~/.ssh/config` line by line. Blocks are delimited by `Host` keyword
lines (case-insensitive per OpenSSH convention). Within each block,
collect lines matching:

```
^[[:space:]]*#[[:space:]]*op:[[:space:]]*([A-Z_][A-Z0-9_]*)=(op://.+)$
```

The value capture `(op://.+)` may include trailing whitespace
(e.g., an accidental space before end-of-line); the implementation
must right-trim the captured value before passing it to `op read`.
Same goes for the `op read` response itself — see step 4 of the
happy path.

> **Note on scope.** Full ssh_config semantics are out of scope. See
> [Out of Scope](#out-of-scope). The user's current `~/.ssh/config` is
> flat (no `Include` directives), so single-file parsing is sufficient.

---

## Code Standards

- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -euo pipefail`
- Must pass `shellcheck -S info` with no findings
- Linear script structure (config at top, linear body, `exec` at bottom)
  — matches `gh` and `claude-wrapper`; no `main "$@"` wrapper
- `exec` the real binary as the final step (no subprocess)
- Executable bit (`chmod +x`) required before commit — pre-commit hook
  rejects non-executable `.sh` scripts
- Counter increments: use `((var += 1))`, never `((var++))`. Under
  `set -euo pipefail`, `((var++))` exits when `var` starts at 0 because
  the post-increment expression evaluates to 0 and bash treats that as
  a command failure. This applies anywhere a counter might start at
  zero (e.g., iterating annotation matches).

---

## Files to Create or Modify

| File | Action |
|---|---|
| `~/Developer/scripts/ssh` | **Create** — the wrapper script |
| `~/.local/bin/ssh` | **Create symlink** → `~/Developer/scripts/ssh` |
| `docs/plans/2026-04-16-ssh-wrapper-spec.md` | **Create** — this document |

---

## Testing

### Pre-flight

1. `command -v ssh` resolves to `~/.local/bin/ssh`, not
   `/opt/homebrew/bin/ssh`. If not, fix `$PATH` order first.
2. `shellcheck -S info ~/Developer/scripts/ssh` — no findings.
3. `bash -n ~/Developer/scripts/ssh` — syntax check.

### Functional

4. **Pass-through (unannotated host):**
   `ssh some-unannotated-host echo hello` works identically to
   `/opt/homebrew/bin/ssh some-unannotated-host echo hello`.

5. **Pass-through (unknown host):**
   `ssh host-not-in-config echo hello` does not error in the wrapper;
   lets real `ssh` produce its own error.

6. **Injection (end-to-end):**

   ```
   OP_SERVICE_ACCOUNT_TOKEN=DUMMY ssh -v mimolette.local hostname |& \
     grep 'setting env OP_SERVICE_ACCOUNT_TOKEN'
   ```

   Must print a line like
   `debug1: channel 0: setting env OP_SERVICE_ACCOUNT_TOKEN = "..."`.
   Absence indicates `sshd` lacks `AcceptEnv` for the variable.

7. **Injection (client-side confirmation):**
   `bash -x ~/Developer/scripts/ssh mimolette true 2>&1 | grep '^+ export OP_'`
   shows the export line firing before `exec`.

8. **Failure mode — bad op ref:**
   Temporarily break the `op://` reference; wrapper exits non-zero with a
   descriptive message and never invokes real `ssh`.

9. **Failure mode — op not signed in:**
   `op signout`, then `ssh mimolette`. Wrapper emits the "session
   expired" hint.

10. **Merge semantics — multiple matching blocks:**
    Add a temporary `Host *` block with `# op: OP_SERVICE_ACCOUNT_TOKEN=op://bogus/value`
    before the `Host mimolette` block. Confirm the mimolette-specific
    value wins (use a readable dummy value and inspect with `ssh -v`).

11. **Multi-name Host line:**
    `Host mimolette asiago` with a single `# op:` annotation — both names
    resolve identically.

### Host-side dependency

`sshd` on the target must have `AcceptEnv VARNAME` for the variable to
arrive. MIMOLETTE's `sshd_config.d/100-macos.conf` already handles this
for `OP_SERVICE_ACCOUNT_TOKEN`. Test 6 is the canonical verification.

---

## Out of Scope

- `Include` directive handling in ssh_config (current config is flat)
- `Match` block handling
- Negation patterns (`!foo`) and character classes in `Host` patterns
- `~/.ssh/config.d/` or system-level `sshd_config` parsing
- Caching resolved secrets across invocations
- Rewriting `git`'s `core.sshCommand` or `GIT_SSH` — callers that bypass
  `$PATH` also bypass this wrapper by design

---

## Open Questions

None at spec sign-off. Re-open if `~/.ssh/config` ever gains `Include`
directives or if a use case emerges for negation patterns.
