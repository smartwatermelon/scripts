# Disposable macOS VM test runner on mimolette

Date: 2026-10-23. Status: design, not built. Nothing on mimolette changes
until this is approved.

## Why

`~/.claude/CLAUDE.md` Protocol 3 ("Destructive code", claude-config PR 778)
says a test that may reach a real destructive command, and the first run of
any new safety test, must run in a disposable environment. The trigger was
the 2026-10-22 incident in `2026-10-22-disk-space-automation.md`.

A Linux container covers code that is portable or fully stubbed. It cannot
run `tmutil`, `diskutil`, `launchctl`, `osascript` or `simctl`. A GitHub macOS
runner can, at about 10 times the Linux per-minute price. mimolette is an
always-on Apple silicon Mac with room to spare, so it hosts throwaway macOS
VMs instead.

## Facts checked on 2026-10-23

| Item | Value |
| --- | --- |
| Chip | arm64 |
| macOS | 27.0.1 (same as ASIAGO) |
| Free on `/System/Volumes/Data` | 158 GiB of 460 GiB |
| Access | passwordless ssh as `andrewrich@`, always on |

## Threat model

The thing under test is assumed hostile by accident: it may run `rm -rf /`
inside the guest. The runner must make sure that:

1. Nothing the guest does reaches mimolette's files, ASIAGO's files or the
   `Workspaces` share that mimolette serves.
2. A session on ASIAGO cannot use the runner as a general shell on
   mimolette. On ASIAGO, `ssh *` is in the Claude Code sandbox's
   `excludedCommands`, so any ssh command runs outside the sandbox.
3. Every run starts from a known-clean image, and nothing from one run
   survives into the next.

## Design

### Account

- A standard (non-admin) macOS user `claude` on mimolette. No sudo.
- All VM images, clones and logs live under `/Users/claude`. Deleting that
  account removes all of it.
- Check at setup: `ls -ld /Users/andrewrich` and its subfolders. New users
  join group `staff`, and home folders may be group-readable. Lock them down
  if `claude` can list them.

### SSH access is one command, not a shell

- ASIAGO gets a new key, used only for this.
- `/Users/claude/.ssh/authorized_keys` on mimolette holds that key with
  `command="/Users/claude/bin/vm-test-run",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc`.
- Whatever the client asks to run arrives only as `SSH_ORIGINAL_COMMAND`,
  which `vm-test-run` parses against a strict allowlist. It never passes it
  to a shell.

### Tool

- Tart (Cirrus Labs), installed by `andrewrich` with Homebrew. `claude` only
  runs it. Tart uses Apple's Virtualization framework; no root is needed.
- One base image, `macos-base`, built once and kept read-only in practice:
  macOS 27, Homebrew, bats, shellcheck, coreutils, git. No Apple ID, no
  secrets, no keys except the one that lets the runner ssh into the guest.

### Code goes in as data

The code under test is often unpushed (a red-phase test should not need a
push, and pushes cost CI money). So the client sends a git bundle on stdin:

```text
git bundle create - HEAD | ssh -i <key> claude@mimolette run <suite>
```

`vm-test-run`:

1. Reads the bundle from stdin into a fresh temp dir under `/Users/claude`.
   Caps its size.
2. Checks `<suite>` against `^tests/[A-Za-z0-9._-]+\.bats$`.
3. Takes a lock, so only one run is active at a time. Apple's licence allows
   at most 2 extra macOS VMs per Mac, and one at a time keeps it simple.
4. `tart clone macos-base run-<id>`, then `tart run --no-graphics run-<id>`
   with **no `--dir` option**, so no host folder is shared.
5. Waits for `tart ip run-<id>`, copies the bundle into the guest with `scp`,
   clones from it there, and runs `bats --print-output-on-failure <suite>`
   inside the guest.
6. Streams the guest's output to the client as text and exits with the
   suite's exit code.
7. Always stops and deletes `run-<id>` and the temp dir, from a `trap`, on
   success, failure or timeout.
8. Bounds the whole run with `timeout` (default 15 minutes).

### Results come out as text

Only stdout, stderr and the exit code go back. No files are copied out of
the guest.

### Client side, on ASIAGO

A small `vm-test` wrapper in this repo builds the bundle and calls ssh with
the dedicated key. That is the only supported way in. Protocol 3's "where
suites run" rule points destructive suites here.

## Validation before first real use

A clean result from an unvalidated sandbox proves nothing. Before the runner
counts as "disposable", run a known-bad suite through it:

1. A bats test that runs `rm -rf /` inside the guest (and, separately, tries
   to reach `/Volumes`, the host's IP and mimolette's `Workspaces` share).
2. Confirm on mimolette: `/Users/claude` and `/Users/andrewrich` unchanged,
   the share unchanged, `run-<id>` gone, `macos-base` unchanged.
3. Confirm the next run starts clean.
4. Confirm a plain `ssh -i <key> claude@mimolette` gets no shell, and that
   `run '; id'` or a path outside `tests/` is refused.

## Open questions

1. **Headless start.** Does `tart run --no-graphics` start a macOS guest
   from an ssh login with no GUI session for `claude`? Not confirmed. If it
   does not, `claude` may need an auto-login GUI session, which changes the
   setup.
2. **Base image source.** Pull a Cirrus Labs macOS 27 image if one exists,
   or build from an IPSW with `tart create --from-ipsw`. Not checked.
3. **Image size.** I expect tens of GB for the base. Whether `tart clone` is
   a cheap APFS copy-on-write clone is not confirmed.
4. **Guest network.** With the bundle approach the guest needs no network
   during a run. Whether Tart can cut the guest off from the LAN (and so
   from the `Workspaces` share) is not confirmed. Until it is, step 1 of the
   validation is the evidence.
5. **Linux layer.** Apple's `container` (Homebrew, 1.6.0) could run the
   portable suites the same way, on ASIAGO or mimolette. Not part of this
   design; add it if the VM start time proves too slow.

## Rollout

Each step is a checkpoint; stop and report if one fails.

1. Andrew creates the `claude` account and installs Tart.
2. Build `macos-base`; answer open questions 1 to 4.
3. Write `vm-test-run` and `vm-test`, both tracked in this repo, with bats
   tests that stub `tart` and `ssh`. `vm-test-run` reaches
   `/Users/claude/bin` on mimolette through a tracked installer, not by hand.
4. Run the validation above.
5. Update Protocol 3 if anything here changed what it promises.
