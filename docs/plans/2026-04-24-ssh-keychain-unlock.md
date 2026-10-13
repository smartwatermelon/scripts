# SSH Wrapper: Remote Keychain Unlock on Connect

**Status:** implemented. Amended 2026-09-10 — the master is now keyed on
the target host and reused across invocations (see "Master reuse" below);
the original PID-keyed socket made every connect pay a TouchID prompt.
**Date:** 2026-04-24
**Amends:** `2026-04-16-ssh-wrapper-spec.md`

## Context

When an SSH session on macOS attaches to a user account, the login keychain
is locked unless a GUI session unlocks it. Utilities invoked over SSH that
need keychain-backed credentials (Safari autofill, Xcode signing cert,
Slack tokens, Git credential helper, etc.) fail silently or prompt for a
password that cannot be typed in a headless shell.

Apple does not unlock the login keychain on SSH login by design
(login keychain password would need to live in a place SSH can reach).

This amendment extends the existing `ssh` wrapper to optionally unlock
the remote's login keychain on connect. The remote keychain password is
fetched from 1Password **on the client** (TouchID-gated, Personal vault),
then handed to the remote's `security -i` REPL via a multiplexed SSH
channel. The password is never in argv, env, or history on either side.

The design is the one sketched in the 2026-04-23 Claude Desktop
conversation; this doc is the integration plan for the existing wrapper.

## Goal

Single-host scope: `ssh mimolette.local` should Just Work — login
keychain unlocked when the interactive shell appears, no keystrokes
required beyond the TouchID prompt that `op read` triggers.

Non-goals:

- Unlocking keychains other than the default login keychain
- Multi-host rollout (design supports it; we only annotate one host now)
- Client-side keychain unlock (only the remote is unlocked)

## Annotation

A new structured-comment form, parsed independently of `# op: VAR=…`:

```
Host mimolette.local
    # op: OP_SERVICE_ACCOUNT_TOKEN="op://Personal/1Password Service Account Auth Token/credential"
    # op-keychain: op://Personal/MIMOLETTE/password
    SendEnv OP_SERVICE_ACCOUNT_TOKEN
```

Grammar:

```
^[[:space:]]*#[[:space:]]*op-keychain:[[:space:]]*(.+)$
```

The capture is then right-trimmed of whitespace, passed through
`_strip_quotes` (same helper as `# op:` values), and post-validated to
start with `op://`. Values that do not start with `op://` after quote
stripping are silently skipped rather than surfaced as secret refs.

- One annotation per Host block. If multiple appear in matching blocks,
  apply the same specificity rank + last-wins merge as `# op:`
  annotations (see 2026-04-16 spec §Matching Semantics).
- No `VAR=` prefix: the payload is a bare `op://` reference. The target
  keychain is implicit (the default login keychain).
- Hosts with `# op-keychain:` but no `# op:` are supported; the two
  annotations are orthogonal.

## Wrapper flow

The existing wrapper (`~/Developer/scripts/ssh`) already:

1. Extracts target host from argv.
2. Resolves `# op:` annotations → exports variables.
3. `exec`s the real ssh.

This plan inserts a new step between (2) and (3) when an
`# op-keychain:` annotation matches and the invocation is eligible:

```
2.5. If op-keychain ref resolved AND argv has no -O:
     a. sock=${SSH_WRAPPER_CM_DIR:-~/.ssh/cm}/unlock-<host>.sock
        (host sanitized: chars outside [A-Za-z0-9._-] become '_')
     a1. If `-O check` reports a live master on that socket: return the
         sock immediately. NO op read, so NO TouchID prompt. Safe because
         every session riding this master shares the sshd session the
         unlock already ran in.
     a2. Otherwise take the creation lock (mkdir "$sock.lock"), arming the
         cleanup trap immediately so a signal releases it, then RE-CHECK
         for a live master (a racer may have won in between). If the lock
         is held by someone else, poll for their master (up to 90s, or
         until their lock disappears) and reuse it rather than prompting.
         A lock older than 60s is treated as orphaned and broken.
     a3. rm -f a stale socket file (ssh will not overwrite one, and
         would silently decline to multiplex).
     b. op read "$ref"  (TouchID prompt on client) — fetch password FIRST
        - if fails: warn, fall through to plain exec. Done before any
          trap setup so _fetch_op's internal trap management does not
          clobber ours.
     c. Set globals _KC_SOCK/_KC_HOST/_KC_REAL_SSH; install cleanup trap:
        trap _keychain_cleanup EXIT INT TERM HUP
        where _keychain_cleanup invokes `-O exit` and removes the socket.
     d. "$REAL_SSH" -fNM -o ControlPath=$sock -o ControlPersist=4h $host
        - if master fails: warn, call _keychain_cleanup, clear trap,
          fall through to plain exec
     e. printf 'unlock-keychain -p %s\n' "$pw" \
          | "$REAL_SSH" -o ControlPath=$sock $host 'exec security -i' \
          (stdout discarded, stderr captured for warning)
        - No keychain name: the CLI targets the remote's default
          keychain. Passing the bare shorthand `login` does not
          resolve on all macOS versions; using the default is
          portable and matches what a GUI login unlocks.
        - If security -i exits non-zero: warn (including the captured
          stderr one-lined for readability), continue — master still
          good, user's session proceeds.
     f. Clear the trap, release the creation lock (only now that the
        master is actually up), return the sock path to the caller.
3.   If sock non-empty: exec "$REAL_SSH" -o ControlPath=$sock "$@"
     Else:              exec "$REAL_SSH" "$@"
```

### Why `ControlPersist` (and why not 60s)

Bash EXIT traps do not fire after `exec` replaces the process image, so
a trap-based cleanup of the master would leak both the socket and the
background `ssh -fNM` process once the user's session ends.
`ControlPersist` tells OpenSSH to auto-exit the master after the last
client channel disconnects, which gives us a clean `exec` path with no
bash wrapper lingering. The trap is retained for the pre-exec dance
(master-open + op-read + unlock-pipe window); it is cleared explicitly
before returning the socket to the caller.

The original value was 60 seconds, which — combined with the PID-keyed
socket — meant no invocation ever reused a master. **ControlPersist is
the prompt budget:** one `op read`, and therefore one TouchID modal, per
persist window. 60s expired between back-to-back connects, so scripted
or agent-driven use (Claude Code running many short `ssh` commands) fired
a modal per connect. The default is now `4h`, overridable via
`SSH_WRAPPER_CONTROL_PERSIST`.

### Master reuse (2026-09-10 amendment)

The socket is keyed on the **target host**, not the wrapper's PID, so
consecutive invocations share one master. When `ssh -O check` reports it
alive the wrapper returns that socket immediately and never calls
`op read` — no modal. Skipping the re-unlock is safe: every session
riding the master shares the sshd session the unlock already ran in.

Measured on mimolette.local, 2026-09-10: first connect 4.3s (one
prompt), subsequent connects 0.25s with zero prompts.

#### Why the creation lock is mandatory

`ssh -fNM` against an **already-live** socket exits **0** while printing
"ControlSocket ... already exists, disabling multiplexing", and leaves a
stray backgrounded ssh behind. Exit status therefore cannot distinguish
"I created the master" from "someone beat me to it". Verified empirically
2026-09-10. Since agent tooling issues Bash calls concurrently, master
creation must be serialized: `mkdir "$sock.lock"` is the primitive
(atomic on every filesystem, and macOS ships no `flock(1)`). After
acquiring it the wrapper re-checks for a live master, because a racer may
have finished in the interval. Verified with 6 parallel cold connects:
one master, one prompt, no stray processes, no leftover lock.

#### Lock release, and why the breaker is the real guarantee

The cleanup trap is armed the moment the lock is taken (not after the
master exists), so an interrupt during the TouchID prompt or the master
open still releases it. Note the trap lives in the `$( )` subshell that
runs `_unlock_remote_keychain`, so signalling only the wrapper's PID does
not exercise it — Ctrl-C and terminal-close signal the whole process
group, which does. A test that signals just the parent PID will report a
spurious "leak"; signal the group (`set -m`, then `kill -HUP -- -$PID`).

No trap can fire on SIGKILL, a panic, or a power loss, so the lock also
carries a **staleness breaker**: a lock dir older than 60 seconds is
assumed orphaned and broken. That, not the trap, is what guarantees the
lock cannot wedge every future connect. (`find -mmin +1` on BSD find
rounds age up to the next whole minute, so the effective threshold is
>60s. macOS-only script, so BSD semantics are fine.)

Residual, accepted: a lock orphaned less than 60s ago makes concurrent
connects wait until the breaker trips before proceeding. Bounded and
self-healing.

#### Why the wait budget is 90s, not 15s

A waiting peer must outlast the holder's **cold** start, which includes a
human-paced TouchID prompt. An early version used 15s; with six parallel
cold connects, five peers gave up and skipped the unlock (verified on
mimolette.local, 2026-09-10). The budget is now 90s, and a waiter also
stops early if the holder's lock disappears — there is nothing left to
wait for at that point. Override with `SSH_WRAPPER_LOCK_WAIT` (0.1s
ticks); the test suite sets it low to stay fast.

#### Socket path length

Unix domain socket paths are capped at ~104 bytes (`sockaddr_un.sun_path`);
ssh rejects longer ones outright with "ControlPath too long".
`~/.ssh/cm/unlock-mimolette.local.sock` is 53 bytes. Note this rules out
long temp-dir paths, which is why the dir is under `~/.ssh` rather than
`$TMPDIR`.

#### Trade-off: shared forwarding

Multiplexed sessions use the **master's** port forwards, so a later
`ssh -L ... mimolette.local` rides the existing master instead of
establishing its own forward. This is invisible for running remote
commands (the actual use case). To get an unshared session, either
`ssh -O exit -o ControlPath=~/.ssh/cm/unlock-<host>.sock <host>` first,
or pass `-S none`.

### Auth-context caveat (OP_SERVICE_ACCOUNT_TOKEN)

The `# op:` loop runs before the keychain dance and may export
`OP_SERVICE_ACCOUNT_TOKEN`. Once that variable is set in the
environment, the local `op` CLI switches from user-session auth (which
can read Personal) to service-account auth (typically scoped to a
single Automation vault). A keychain password stored in Personal then
fails the op read with *"'Personal' isn't a vault in this account"*.

`_unlock_remote_keychain` saves `OP_SERVICE_ACCOUNT_TOKEN`, unsets it,
runs the op read (which falls back to the user's signed-in session
and biometric), then restores it so the final exec still forwards
the token to the remote via SendEnv. Regression coverage in
`integration (keychain): OP_SERVICE_ACCOUNT_TOKEN is unset around
keychain op read`.

### Key invariants

- `"$REAL_SSH"` everywhere inside the wrapper body — never bare `ssh` —
  so the master-open and unlock subchannels bypass the wrapper and
  don't re-trigger annotation resolution or recursion.
- `SendEnv` forwarding still works over multiplexed channels: each ssh
  invocation using `-o ControlPath=$sock` pushes its own env vars.
  `OP_SERVICE_ACCOUNT_TOKEN` reaches the remote because the `# op:`
  export happens before the unlock dance.
- Final argv is passed verbatim to the final `exec`. The wrapper does
  not inject `-t`, `-T`, `-N`, or any other flag. Users who want
  `ssh -t` pass it themselves.
- Password never in argv (`security -i` REPL dispatches in-process,
  verified pre-commit per PDF discussion).
- Password never on disk (piped through stdin, not a tempfile).
- Password never in env on either side.
- `trap` covers EXIT INT TERM HUP; socket cleanup survives ctrl-C
  during the dance. Missing `-O exit` target (e.g., when master never
  opened) is ignored via `2>/dev/null`.

### Eligibility guards

The dance fires only when **all** are true:

- `_resolve_keychain_annotation` returned a non-empty ref for the target.
- argv does not contain `-O` (any ControlMaster control op:
  `-O check|stop|exit|forward|cancel`).

`-O` detection: iterate argv; if any token is exactly `-O` (no bundle
form exists for `-O`; it always takes its arg in the next token),
skip the dance and fall through to plain `exec`.

Decided against:

- Skipping when `-N` is present. A user port-forwarding might still
  want the keychain unlocked for downstream tooling on the remote.
- Skipping when stdin is not a TTY. Too aggressive — would break
  heredoc invocations (`ssh host <<<'cmd'`).

## Failure policy

Asymmetric with `# op:` policy, deliberately:

| Failure | Policy | Reason |
|---|---|---|
| `op read` fails (no biometric, session expired, ref missing) | Warn to stderr, skip dance, fall through to plain `exec ssh` | Failed keychain unlock is a convenience loss, not a security hole. User can unlock manually post-login. |
| `ssh -fNM` master open fails | Warn, skip dance, fall through to plain `exec ssh` | Same reason; plain ssh will produce its own auth error anyway. |
| `security -i` pipe exits non-zero on remote | Warn, proceed with session (master is already open) | Keychain unlock attempted; session should still work. |
| `op` CLI not installed | Warn, skip dance, fall through | Same as `# op:` has (but `# op:` aborts). Here we fall through for consistency with the keychain-specific relaxed policy. |

Rationale for the asymmetry: `# op:` injects a value that the remote
actively depends on (e.g., `OP_SERVICE_ACCOUNT_TOKEN` is how the remote
reaches its 1Password Automation vault). `# op-keychain:` is pure
convenience; no downstream operation breaks if it's skipped.

## Files to modify

| File | Action |
|---|---|
| `~/Developer/scripts/ssh` | Add `_resolve_keychain_annotation`, `_unlock_remote_keychain`, `_argv_has_dash_oh`; extend linear body |
| `~/.ssh/config` | Add `# op-keychain: op://Personal/MIMOLETTE/password` to `Host mimolette.local` block |
| `tests/ssh-wrapper.bats` | Add bats cases (see below) |
| `tests/fixtures/config-keychain` | New fixture file for keychain annotation tests |
| `docs/plans/2026-04-24-ssh-keychain-unlock.md` | This doc |

## Tests

### Unit (via sourced wrapper)

- `_resolve_keychain_annotation`: basic match returns ref
- `_resolve_keychain_annotation`: unannotated host returns empty
- `_resolve_keychain_annotation`: specificity — exact wins over glob
- `_resolve_keychain_annotation`: last-wins at equal specificity
- `_resolve_keychain_annotation`: trailing whitespace right-trimmed
- `_resolve_keychain_annotation`: Match block terminates preceding Host
- `_argv_has_dash_oh`: detects `-O check`, `-O stop`, `-O exit`
- `_argv_has_dash_oh`: does not false-positive on `-o Option=Value`

### Integration (recorder shim)

- Annotated host: wrapper fires master-open, pipe-unlock, then final
  exec with `-o ControlPath=…` present in argv.
- Annotated host with `-O stop`: wrapper skips dance, plain exec.
- Annotated host with failing op-read (fake op mode=failure): wrapper
  warns, skips dance, plain exec succeeds.
- Annotated host with failing master-open (fake real-ssh returning 255
  on `-fNM`): wrapper warns, skips remainder of dance, plain exec with
  no `-o ControlPath=…` token.
- Unannotated host: unchanged from current integration test.
- `# op:` annotated but no `# op-keychain:`: unchanged from current.

### Manual

- `security -i` argv verification (one-time, pre-commit): in terminal 1
  run `security -i`; type `unlock-keychain -p hunter2 login`; in
  terminal 2 run `ps auxww | grep security`. Confirm no subprocess with
  `hunter2` in argv appears. If it does, design needs to change.
- End-to-end: after implementation, on a locked mimolette.local,
  `ssh mimolette.local` → TouchID prompts → shell appears → run
  `security show-keychain-info` → confirm unlocked.
- Stability: exit shell, re-ssh, confirm clean teardown (no orphaned
  master socket, no stray `ssh -fNM` processes).

## Pre-commit checks

- `shellcheck -S info ~/Developer/scripts/ssh` — no findings
- `bash -n ~/Developer/scripts/ssh` — syntax clean
- `bats tests/ssh-wrapper.bats` — all tests pass
- Executable bit preserved on `ssh`

## Out of scope (for this change)

- Unlocking non-login keychains (`~/Library/Keychains/*.keychain-db`)
- Per-host custom keychain paths
- Client-side keychain unlock before ssh
- ControlMaster *reuse* across wrapper invocations (each invocation
  opens its own short-lived master; closes on exit)
- Integration with existing `# op: VAR=…` merge semantics beyond
  coexistence (the two annotations are parsed with the same rank rules
  but in separate pipelines)

## Open questions

None at sign-off.
