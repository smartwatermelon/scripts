# SMB Mount Rebuild — Design

**Date:** 2026-04-16
**Branch:** `claude/feat-smb-mount-rebuild-20260416`
**Scope:** Replace the non-functional `smb-mount.sh` + `com.andrewrich.mountsmbshares.plist` with a reliable, idempotent SMB auto-mounter for ASIAGO, modeled on the proven NFS mount template from `mac-server-setup` (as deployed on TILSIT).

## Goals

Mount two SMB subpaths automatically at user login and keep them mounted:

| Server path (on SMB server) | Local path |
|---|---|
| `//dsadmin@romano.local/DSMedia/Archives/ASIAGO/archives` | `/Users/andrewrich/Downloads/archives` (direct mount) |
| `smb://mimolette.local/extra-vieille/Workspaces` | `/Users/andrewrich/workspaces` (symlink → `/Volumes/Workspaces`) |

Mounts must survive network blips, sleep/wake cycles, and server restarts. Re-runs must be idempotent (no-op when everything is already mounted).

The mimolette share is reached via Apple-ID SSO (see Credentials); the CLI-accessible path for that auth always lands in `/Volumes/<basename>`, so the configured mount point is maintained as a symlink rather than a direct mount.

## Non-goals

- Mounting the whole `DSMedia` share (we want only the one subpath).
- Mounting anything at boot before the user is logged in — this is a workstation, not a server.
- A generic multi-host framework. Two shares is the use case.

## Credentials

Each share picks its auth mode based on whether an `op_ref` is configured.

| Share | Auth mode | Username | `op` reference |
|---|---|---|---|
| romano.local / DSMedia | 1Password | `dsadmin` | `op://Personal/Synology NAS - dsadmin/password` |
| mimolette.local / extra-vieille | NetAuth (Apple-ID SSO via osascript) | — | — |

**1Password mode** (romano): `op read` fetches the password at mount time, URL-encoded and embedded as `//user:pass@host/...`. The LaunchAgent runs as `andrewrich` (`LimitLoadToSessionType=Aqua`), so `op` uses biometric unlock via the 1Password desktop app. TouchID fires only when a mount is attempted (fast-path short-circuits when already mounted), so at 150s cadence there are no recurring prompts during steady state.

**NetAuth / SSO mode** (mimolette): both Macs are signed into the same Apple ID, and `mimolette.local` exposes the share exclusively through macOS's Apple-ID iCloud file-sharing identity (principal `com.apple.idms.appleid.prd.<hash>@…`). This identity lives in the NetAuth/IdMS subsystem that Finder uses — not in the generic login keychain that `mount_smbfs` reads. Empirical verification: `mount_smbfs -N //mimolette.local/extra-vieille/Workspaces` returns `server rejected the connection: Authentication error`, and no `security find-internet-password -s mimolette.local` entry exists. Guest auth is also rejected, and no Kerberos ticket is present in a CLI-visible cache.

The only CLI path that reaches the NetAuth stack is `osascript -e 'mount volume "smb://..."'`, which always mounts to `/Volumes/<share-basename>` (the command has no argument for a custom destination). To preserve the configured mount point for consumers, the script mounts via NetAuth and then maintains `~/workspaces` as a symlink pointing at the `/Volumes/…` path. This accepts a modest semantic shift (the configured path is a symlink, not a true mount point) in exchange for keeping automation.

The script treats `op_ref == ""` as the NetAuth/SSO-mode signal, so future shares can be added in either mode by adjusting the configuration arrays.

## Mount strategy

Two code paths, chosen by whether `op_ref` is set.

**1Password path (romano):** direct subpath mount via `mount_smbfs`. macOS `mount_smbfs` accepts share-relative subdirectories in the URL, so the mount point corresponds to exactly one mount — no symlinks, no whole-share intermediates.

```
mount_smbfs -N //dsadmin:<pw>@romano.local/DSMedia/Archives/ASIAGO/archives \
               /Users/andrewrich/Downloads/archives
```

Password is URL-encoded before substitution and redacted from all log output.

**NetAuth path (mimolette):** `osascript 'mount volume "smb://..."'` to route through NetAuth, then reconcile a symlink at the configured mount point.

```
osascript -e 'mount volume "smb://mimolette.local/extra-vieille/Workspaces"'
# → macOS mounts at /Volumes/Workspaces
ln -sfn /Volumes/Workspaces /Users/andrewrich/workspaces
```

The script discovers the actual `/Volumes/...` path by parsing `mount` for any smbfs entry whose source ends with `mimolette.local/extra-vieille/Workspaces`, so it tolerates macOS appending `-1` on duplicate basenames.

## Per-share lifecycle (idempotent)

Per-share steps, with mode-specific branches:

- **Step 0 — Already satisfied?**
  - 1Password path: `mount` output contains `on <mount_point> (smbfs`.
  - NetAuth path: `<mount_point>` is a symlink, its target is a live smbfs mount, and that target matches the share's current `/Volumes/...` entry.
  - Match → log and skip.
- **Step 1 — Reachability.** `ping -c 1 -W 2000 "$server"`. Failure → log and skip (no retry loop; `KeepAlive`+`StartInterval=150` handles retries at the LaunchAgent layer).
- **Step 2a (1Password path) — Clean mount point.** If the path is a file (e.g., a stale alias), remove it. If it's an empty directory, leave it. If missing, `mkdir -p`. If it's currently a mount for a different URL, attempt `umount`.
- **Step 2b (1Password path) — Fetch password.** `op read "$op_ref"`. Empty/failure → log and return non-zero for this share; continue to next.
- **Step 2c (1Password path) — Mount + verify.** `mount_smbfs -N <url> <mount_point>`; re-check `mount` output.
- **Step 3a (NetAuth path) — Reuse existing mount if present.** If the share is already mounted at some `/Volumes/...` (e.g., user opened it manually from Finder), skip the osascript call and go straight to Step 3c.
- **Step 3b (NetAuth path) — Mount.** `osascript -e 'mount volume "smb://server/share_path"'`. Stderr captured and logged on failure. Re-scan `mount` to discover the assigned `/Volumes/...` path.
- **Step 3c (NetAuth path) — Ensure symlink.** If `<mount_point>` is already the right symlink, done. If it's a dangling/wrong symlink, replace it. If it's an empty directory, `rmdir` then symlink. If it's a non-empty directory, refuse and log an error (preserves any user data that accidentally landed there).

Script uses `set -uo pipefail` (intentionally **not** `-e`) so a failure on one share doesn't abort the other. `main` returns non-zero if any share failed, which feeds `KeepAlive.SuccessfulExit=false`.

## Script structure

```
smb-mount.sh
├── log()                                        # timestamped → stdout (launchd captures)
├── url_encode()                                 # for password special characters
├── is_mounted <mount_point>                     # smbfs-at-path check
├── any_mount_at <mount_point>                   # any-fs check (for cleanup)
├── find_existing_smbfs_mount <server/share>     # map //…/share → /Volumes/… path
├── prepare_mount_point <path>                   # cleanup: stale mount, symlink, file, mkdir
├── ensure_symlink <link> <target>               # idempotent symlink, refuses non-empty dir
├── sso_already_ok <mp> <server/share>           # NetAuth fast-path check
├── mount_one_cred <server> <user> <share> <mp> <op_ref> <kc_ref>   # 1Password / keychain / mount_smbfs
├── mount_one_netauth <server> <share> <mp>                        # osascript + symlink
├── mount_one <server> <user> <share> <mp> <op_ref> <kc_ref>      # dispatch + reachability
└── main                                         # iterates SHARES; tracks failures
```

Configuration is a set of parallel bash arrays (one entry per share, indexed by position), defined at the top of the script for easy future edits.

## LaunchAgent

File: `com.asiago.mount-smb-shares.plist` (renamed from `com.andrewrich.mountsmbshares.plist` via `git mv`).

```xml
Label                   com.asiago.mount-smb-shares
ProgramArguments        [/Users/andrewrich/.local/bin/smb-mount.sh]
RunAtLoad               true
StartInterval           150
KeepAlive               { SuccessfulExit: false }
LimitLoadToSessionType  Aqua
StandardOutPath         ~/.local/state/com.asiago.mount-smb-shares.log
StandardErrorPath       ~/.local/state/com.asiago.mount-smb-shares.log
EnvironmentVariables    { PATH: /opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin }
```

## Logging

- File: `~/.local/state/com.asiago.mount-smb-shares.log` (matches TILSIT naming convention).
- Truncated at the start of each run (per TILSIT template).
- `chmod 600`.
- Launchd captures stderr/stdout to the same file via the plist.

## Deploy

The script and plist live in the repo and are symlinked into their runtime locations (matches the existing `~/.local/bin/` convention for this repo):

```bash
ln -sf ~/Developer/scripts/smb-mount.sh ~/.local/bin/smb-mount.sh
ln -sf ~/Developer/LaunchAgents/com.asiago.mount-smb-shares.plist \
       ~/Library/LaunchAgents/com.asiago.mount-smb-shares.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.asiago.mount-smb-shares.plist
```

One-shot pre-deploy cleanup (not part of the script itself):

1. `rm ~/Downloads/archives` — remove the stale macOS alias file.
2. If `com.andrewrich.mountsmbshares.plist` happens to be loaded: `launchctl bootout gui/$(id -u) …` and remove any stray symlink in `~/Library/LaunchAgents/`.

## Testing plan

Local verification before commit:

1. `bash -n smb-mount.sh` — syntax.
2. `shellcheck -S info smb-mount.sh` — must be clean with no `disable` directives.
3. Unmount `extra-vieille/Workspaces` (`diskutil unmount /Volumes/Workspaces` or eject in Finder) and run `smb-mount.sh` directly. Verify `/Volumes/Workspaces` is mounted (smbfs) and `~/workspaces` is a symlink pointing at it.
4. Re-run the script: confirm no-op (NetAuth fast-path short-circuits via `sso_already_ok`; romano short-circuits via `is_mounted`; no TouchID / NetAuth prompts).
5. Delete `~/workspaces` symlink, leave the `/Volumes/Workspaces` mount, and re-run: confirm the symlink is recreated without a re-mount.
6. Unmount `/Volumes/Workspaces`, leave the `~/workspaces` symlink dangling, and re-run: confirm remount via osascript and symlink update to match the new `/Volumes` path.
7. Load LaunchAgent and verify it runs at login and every 150s.

## Deliverables

Single branch, single PR:

- New `smb-mount.sh` (full rewrite).
- `com.andrewrich.mountsmbshares.plist` → `com.asiago.mount-smb-shares.plist` via `git mv`, contents replaced.
- This design doc at `docs/plans/2026-04-16-smb-mount-rebuild-design.md`.

## 2026-04-24 addendum — keychain fallback

After the initial rollout, overnight `op read` calls against a locked 1Password vault queued TouchID prompts that piled up by morning (LaunchAgent with `KeepAlive.SuccessfulExit=false` respawned every ~60 s each time `op read` blocked on biometric and timed out).

Resolution: added a `SHARE_KC_REFS` parallel array and a `fetch_password` helper that:

1. Uses `op whoami` in a subshell (with `OP_SERVICE_ACCOUNT_TOKEN` unset) as a silent safety gate before `op read`. Verified empirically not to trigger TouchID.
2. Falls back to the macOS login keychain (via `security find-generic-password -w`) when the op gate fails.
3. Pushes updates from 1Password back into the keychain whenever it finds them out of sync (1Password remains canonical; keychain is a non-interactive mirror).
4. Surfaces a macOS notification + persistent sentinel file at `~/.local/state/smb-mount-alert.txt` on SMB auth failures, so stale keychain entries get noticed rather than silently looping. Banner is rate-limited to once per 30 min to avoid Notification Center spam during a persistent outage.

Key auth-context detail: the same `OP_SERVICE_ACCOUNT_TOKEN` vault-scoping issue that PR #64 addressed in the `ssh` wrapper applies here too — a service-account token makes `op read` fail for Personal-vault items. `fetch_password` wraps its op calls in subshells with that var unset.

`_kc_write` on an existing item omits `-T` flags so ACL is preserved and macOS does not prompt to authorize an ACL change. The initial keychain entry must be seeded manually with `-T` (see the runbook in `docs/plans/2026-04-24-smb-mount-keychain-fallback.md` Task 7).

See `docs/plans/2026-04-24-smb-mount-keychain-fallback.md` for the full implementation plan and per-task history.
