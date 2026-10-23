# Disk space automation

Date: 2026-10-22, revised 2026-10-23. Branch:
`claude/feat-disk-space-automation-20261022`.

## Why

On 2026-10-22 ASIAGO's data volume reached 92% used (37 GiB free of 460 GiB).
Manual cleanup recovered 145 GiB. Where it went:

| Source | Freed |
| --- | --- |
| `~/.npm` | 24 GiB |
| iOS simulator runtimes and devices | ~23 GiB |
| Android emulators and SDK | ~21 GiB |
| `~/.cache/uv` | 13 GiB |
| Puppeteer browsers, Gradle caches | ~16 GiB |
| Time Machine local snapshots | 8 GiB or more |

Two jobs existed and neither caught it:

- `thin-timemachine-snapshots` (LaunchDaemon, source in `~/Developer/LaunchAgents`,
  a local repo with no remote) runs weekly with a 50 GiB target. It last ran at
  boot on 2026-10-21 with 52 GiB free, did nothing (correctly), and was not due
  again until Sunday 2026-10-25. Free space fell to 37 GiB in between. It can
  only thin snapshots; it cannot touch caches.
- `updates` (dotfiles, nightly) runs `brew cleanup --prune=all`, which works.
  Nothing cleans npm, uv or simulator caches.

On 2026-10-23, after the cleanup, the volume had 135 GiB free: `~/.npm` was
1.8 GiB, `~/.cache/uv` was empty, `~/.cache/puppeteer` was gone and
CoreSimulator held 8 KiB. Most of the 145 GiB was one-time (mobile work moved
to another server). npm and uv grow back, so a small weekly job and an alert
are still worth having.

## Incident, 2026-10-22

The first version of this branch had a Puppeteer step that ran its own
`rm -rf`: in each `<cache>/<browser>/` it kept the newest version directory by
`sort -V` and removed the rest. Its path guard was a denylist. It refused an
empty path, a relative path and exactly `$HOME`, after stripping one trailing
slash.

A red-phase bats test passed `//` to that guard before the fix for it
existed. `//` became `/` and passed. The loop then treated every top-level
directory as a "browser" and removed all but one child of each. About 40 apps
in `/Applications` were deleted (user-owned ones; root-owned bundles resisted).
Backups restored everything within a few hours. The second guard
(`entry == cache_dir/*/*`) was a glob and matched `//Applications/Foo.app`, so
it failed on the same input.

What changed as a result:

- The Puppeteer step is gone. No project under `~/Developer` uses Puppeteer,
  and the cache no longer exists.
- `disk-cleanup.sh` deletes nothing itself. Every cache is cleaned by the tool
  that owns it. A guard test fails if a code line calls `rm`, `rmdir`, `mv`,
  `unlink`, `shred` or `-delete`.
- The test file has no `rm` either: it uses `BATS_TEST_TMPDIR`, which bats
  creates and removes.
- `~/.claude/CLAUDE.md` gained a "Destructive code" rule in Protocol 3
  (claude-config PR 778): stub every destructive command, keep real
  dangerous paths out of safety tests, and run red-phase safety tests only in
  a disposable container or VM.
- Claude Code sessions here now run Bash under the macOS sandbox.
  `/Applications` is outside its write allowlist.

## What

Two commits, one PR.

### 1. `disk-cleanup.sh` + `LaunchAgents/com.asiago.disk-cleanup.plist`

Weekly LaunchAgent (Sunday 04:00). Each step skips with a log line when its
tool is absent, and one failing step does not stop the others:

- `npm cache clean --force`
- `uv cache prune` (keeps entries still in use, unlike `uv cache clean`)
- `xcrun simctl delete unavailable`, wrapped in `timeout` (an unwrapped
  `simctl` call hung past 300 s during the 2026-10-22 cleanup). Kept although
  CoreSimulator is empty now: `simctl` decides what to delete, and the step
  costs nothing when there is nothing to delete.

Logs to `~/.local/state/disk-cleanup.out` with free space before and after.

### 2. `disk-space-alert.sh` + `LaunchAgents/com.asiago.disk-space-alert.plist`

Daily LaunchAgent at 09:00. If free space on `/System/Volumes/Data` is below
the threshold (default 40 GiB, first argument overrides), post a macOS
notification with `osascript`. 40 GiB, not 50, so the alert does not fire on a
shortfall the 50 GiB snapshot thinner clears on its own. It deletes nothing.

- An unreadable volume also posts a notification and exits 1, so the alert
  cannot fail silently on its own input.
- The title and message reach AppleScript as `argv`, not as script text, so
  no value can change the script.
- `osascript` exits 0 even when the notification service is unreachable (seen
  inside the Claude Code sandbox on 2026-10-23), so a missing notification
  is not always detected. The log line is the record.

## Later, separate PR

### Move `thin-timemachine-snapshots` into this repo, run it daily

Split out because it installs a root LaunchDaemon, which this branch's
sandboxed sessions cannot do, and because it changes system state
(`tmutil`), so it falls under the destructive-code rule.

- `thin-timemachine-snapshots.sh` moves here from `~/Developer/LaunchAgents`.
- Its plist goes in a new `LaunchDaemons/` directory with
  `StartCalendarInterval` changed from weekly (Sunday 03:00) to daily (03:00).
- A LaunchDaemon plist and the script it runs as root must be root-owned
  regular files, so the repo's symlink rule cannot apply.
  `install-thin-timemachine-snapshots.sh` copies both into place with the
  right owner and mode and bootstraps the daemon; `--uninstall` reverses it.
  This is the repo's "generated by a tracked installer" pattern.
- `CLAUDE.md` gains a LaunchDaemons clause in the placement rule.
- `tmutil` is injected and stubbed in tests. Any test that needs the real
  `tmutil` runs in a disposable macOS VM (see
  `2026-10-23-mimolette-vm-test-runner.md`).
- After it merges and the installer has run, the old copies in
  `~/Developer/LaunchAgents` are removed in a separate local commit there.

## Not doing

- No Puppeteer cleanup (see Incident).
- No cleanup of Gradle, Xcode DerivedData or Android files. Mobile development
  moved to another server, and those were removed by hand.
- No change to the `updates` job in dotfiles.
