# scripts

Personal macOS utility scripts. Everything here is deployed to `~/.local/bin/`
via symlink, so the file on disk and the file in version control are the same
object — edits land immediately, no install step beyond the initial
`ln -sf`.

Internal repo; not intended for public consumption.

## Conventions

- Shebang: `#!/usr/bin/env bash` (never `/bin/bash` or a `zsh` shebang —
  `shellcheck` refuses the latter).
- `set -euo pipefail` unless the script explicitly needs partial-failure
  behavior (`smb-mount.sh` uses `-uo pipefail` so one share's failure doesn't
  abort the others).
- Logs: `~/.local/state/<name>.out` or `<name>.log`.
- Secrets: macOS Keychain or 1Password CLI (`op`). Never hardcoded.
- Shared helpers: `~/.config/bash/functions.sh` (`_notif`, `_what_is_this`,
  `_kill_clones`).
- Repo-walking scripts take their target directory from an env var with a
  sensible default: `MY_REPOS_DIR` (`my-repos.sh`), `BEACON_REPOS_DIR`
  (`beacon-repos.sh`). A missing directory warns and exits 0 rather than
  failing, so `allup` still passes on a machine that legitimately lacks one.
  A repo that fails its status check, switch, pull or branch restore makes
  the walker exit 1; a dirty repo is skipped and does not.
- LaunchAgent plists for scripts in this repo live in `LaunchAgents/` here
  and are symlinked into `~/Library/LaunchAgents/`. Plists for scripts
  outside any repo live in `~/Developer/LaunchAgents/`. `CLAUDE.md` has the
  full placement rule.
- Practice/standards reference: `CLAUDE.md` (same dir). Design docs:
  `docs/plans/`.

## Scripts

### System management

| Script | Purpose |
| --- | --- |
| `reset-tccd.sh` | Resets the macOS TCC daemon (Transparency, Consent, and Control) and waits for it to respawn. Used when privacy-permission state gets wedged. |
| `local-macs.sh` | Lists ssh-able Macs on the LAN (Bonjour `_ssh._tcp`, 3-second browse), excluding this host and any name with a space. |
| `allup-fleet.sh` | Runs `allup` on every host from `local-macs` at once, one tmux pane per host via `ssh -t` — so each remote run stays interactive (casks, macOS updates, sudo prompts) and its output stays separate. `-d` starts without attaching; any other arguments replace `allup` as the remote command. Tests in `tests/allup-fleet.bats`. |
| `disk-cleanup.sh` | Weekly cache cleanup for the data volume. It runs `npm cache clean --force`, `uv cache prune` and `xcrun simctl delete unavailable`. The simctl step runs under `timeout` (120 s) and skips if there is no `timeout` or `gtimeout`. The script deletes no path itself; each tool cleans its own cache. A missing tool is a logged skip. A failed step does not stop the others, but the run then exits 1. It logs free space before and after. Runs under `LaunchAgents/com.asiago.disk-cleanup.plist` (Sunday 04:00) and logs to `~/.local/state/disk-cleanup.out`. Design: [`docs/plans/2026-10-22-disk-space-automation.md`](docs/plans/2026-10-22-disk-space-automation.md). Tests in `tests/disk-cleanup.bats`. |
| `disk-space-alert.sh` | Daily low-disk alert. If free space on `/System/Volumes/Data` is below 40 GiB (the first argument overrides it), it posts a macOS notification with `osascript`. It also posts one if it cannot read free space. It deletes nothing. `osascript` can exit 0 when the notification is not shown, so the log is the record. Runs under `LaunchAgents/com.asiago.disk-space-alert.plist` (daily 09:00) and logs to `~/.local/state/disk-space-alert.out`. Tests in `tests/disk-space-alert.bats`. |
| `tm-caffeinate.sh` | Keeps the machine awake while Time Machine is backing up. LaunchAgent-driven: re-execs under `caffeinate` and polls until the backup completes, then exits. |

### Development workflow

| Script | Purpose |
| --- | --- |
| `git-status.sh` | Surveys every git repo under `$HOME` (max depth 3) and summarizes clean/dirty/branch state. |
| `my-repos.sh` | For every repo in `~/Developer` owned by `smartwatermelon`, `nightowlstudiollc` or `twistedmelonman`: show status, pull if clean. `--check` for offline dirty-report only; `--show-prs`, `--show-issues`, and `--show-dead-branches` report open PRs, open issues, and merged-but-undeleted local branches; `--check-remotes` reports repos whose `origin` points at a stale `owner/repo` (asking GitHub for each repo's canonical name) and `--fix-remotes` repairs them, rewriting `origin`'s url and pushurl and refreshing a stale `remote.origin.gh-resolved` while preserving the URL scheme, host alias and port; `--status` enables all the report-only flags (never the fix); `--skip REPO` excludes a repo (repeatable; accepts the directory name or the `owner/repo` slug); `--quiet` trims output. Override the directory with `MY_REPOS_DIR`. |
| `beacon-repos.sh` | Same flags as `my-repos.sh`, for repos in `~/Developer/beacon-biosignals` owned by `beacon-biosignals`. Both are thin wrappers over `lib/repo-walker.sh`. Override the directory with `BEACON_REPOS_DIR`. |
| `vim-setup.sh` | One-shot bootstrap for `~/.vim/` — installs Gruvbox + plug-vim. |

### Networking & storage

| Script | Purpose |
| --- | --- |
| `smb-mount.sh` | Idempotent SMB auto-mounter for the ASIAGO workstation. Mounts `romano` via `mount_smbfs` + 1Password, and `mimolette` via `osascript 'mount volume'` (routes through Apple-ID SSO / NetAuth) + managed `~/workspaces` symlink. LaunchAgent cadence 150 s. Design: [`docs/plans/2026-04-16-smb-mount-rebuild-design.md`](docs/plans/2026-04-16-smb-mount-rebuild-design.md). |
| `docs-tidy.py` | Quarterly `~/Documents` tidy, plan then approve. `plan` writes a plan to `~/.local/state/docs-tidy/`: archive items unchanged for four calendar years to Google Drive, de-duplicate `Documents - <HOST>` machine snapshots, stash duplicate files, and rename and tag credit reports. Nothing moves until `docs-tidy apply` (copy, verify MD5, delete; `--skip SECTION`). `show` prints the newest plan. Python, stdlib only. Runs under `LaunchAgents/com.asiago.docs-tidy.plist` (`plan --notify`, 10:00 on Jan/Apr/Jul/Oct 1). Design: [`docs/plans/2026-10-21-docs-tidy-design.md`](docs/plans/2026-10-21-docs-tidy-design.md). Tests in `tests/docs-tidy.bats`. |
| `check-certs.sh` | Given a hostname list (defaults to `/tmp/dns-names.txt`), reports DNS resolution and HTTPS certificate validity for each. |

### Credentials & automation

| Script | Purpose |
| --- | --- |
| `1password-mcp-launcher.sh` | Reads `OP_SERVICE_ACCOUNT_TOKEN` from the macOS Keychain and launches the 1Password MCP server at a pinned version — avoids handing the keychain-held token to whatever `npx -y` happens to resolve. |
| `instapaper-mcp-launcher.sh` | Reads the four Instapaper API credentials from the macOS Keychain and launches the Instapaper MCP server. The server calls bare `dotenv.config()`, which resolves `.env` against the process working directory — a Desktop-spawned server never runs from the repo, so exporting here is what actually reaches it. |
| `claude-config-backup.sh` | Snapshots machine-local Claude config files into a git repo and pushes. Each host writes only its own folder: `<HOST>/cli/claude.json`, `<HOST>/desktop/claude_desktop_config.json` and `<HOST>/machine-settings.json`. The last is the `--settings` overlay that claude-wrapper passes; `CLAUDE_MACHINE_SETTINGS` overrides its path. `<HOST>` is `CLAUDE_CONFIG_BACKUP_HOST` if set, else `hostname -s`, uppercased. It must match `^[A-Z0-9][A-Z0-9-]*$`, or the script logs `ERROR` and exits 1. It refuses to run on arich-mac (company machine), detected by host name or by the `arich` login. On its first run with this layout, it moves root-level `cli/` and `desktop/` into `<HOST>/` with `git mv`, in a commit of its own. If both the old and new folders exist, it logs `ERROR`, changes nothing and exits 1. Gates each file on quiescence (unchanged size+mtime across a settle window), valid JSON, and a `gitleaks`-first secret scan before committing. If the remote has commits the clone lacks, it runs `git pull --rebase` and pushes once more. A rebase conflict is aborted and logged as `ERROR` with the manual fix; the script exits 1 and keeps the local commits. Other push failures log `WARN` with git's first error line. A failed push is retried next run, even when nothing new was committed. It never force-pushes. Driven by `com.asiago.claude-config-backup` every 15 min. Tests are in `tests/claude-config-backup.bats`. |
| `handoff-sync.sh` | Two-way `rclone bisync` of `~/.local/state/claude-handoffs` with the Google Drive folder `Claude Handoff`, for hosts with no Drive app (TILSIT). Runs from `andrewrich`'s crontab every 5 minutes, not a LaunchAgent, because that user has no GUI session there. Log: `~/.local/state/rclone/handoff-sync.log`. The `gdrive:` remote uses rclone's shared client ID, which Google may retire. Tests in `tests/handoff-sync.bats`. |
| `refresh-claude-secrets.sh` | Resolves `op://` references from `secrets.op` and writes plaintext values into `claude-secrets.md` for Claude via the Filesystem MCP. Re-run after rotating any referenced credential. Must run from `~/.config/claude-code` (the symlink target). |
| `ssh` | Wrapper over the real `ssh` that intercepts `# op: VAR="op://..."` annotations in `~/.ssh/config`, resolves them via 1Password, exports, then `exec`s real `ssh`. Unannotated hosts pass straight through. Spec: [`docs/plans/2026-04-16-ssh-wrapper-spec.md`](docs/plans/2026-04-16-ssh-wrapper-spec.md). Tests in `tests/ssh-wrapper.bats`. |

### Utilities

| Script | Purpose |
| --- | --- |
| `sleepnow` | One-liner wrapper for `pmset sleepnow`. Immediate sleep. |
| `break-watcher.sh` | Long-running work timer: polls `HIDIdleTime` and runs `break-prompt.sh` after 45 minutes of continuous activity. Idle time resets the accumulator. Runs under `LaunchAgents/com.asiago.break-watcher.plist`. |
| `break-prompt.sh` | The break prompt itself: a modal, then a 3-minute countdown with a typed-reason bypass. No bypass sleeps the machine, so waking needs the password. Bypasses are logged to `~/.local/state/break-enforcer/dismissals.log`. Tests in `tests/break-prompt.bats`. |

### Scratch / practice

| Script | Purpose |
| --- | --- |
| `fizzbuzz.sh` | Classic FizzBuzz in Bash. |
| `stringprefix.sh` | Practice: longest prefix that appears at least twice across an array of strings. |

## Subdirectories

- `lib/` — shared bash libraries, sourced by scripts rather than executed.
  Not executable, not symlinked into `~/.local/bin`. `repo-walker.sh` backs
  `my-repos.sh` and `beacon-repos.sh`.
- `docs/plans/` — design docs and specs for non-trivial scripts.
- `tests/` — `bats` test suites and fixtures (`ssh-wrapper.bats`).
- `LaunchAgents/` — plists for scripts in this repo, symlinked into `~/Library/LaunchAgents/` (see `CLAUDE.md`).
- `.github/workflows/` — `bats.yml` (bats suites and shellcheck), `standards-check.yml`, `auto-tag.yml` (tags each push to main) and `dependabot-auto-merge.yml`. The scheduled ralph-burndown automation is no longer in operation.

## Standards

- Pass `shellcheck -S info` with no `# shellcheck disable` directives.
- Use `((var += 1))` instead of `((var++))` (the latter exits under `set -e` when `var=0`).
- `+x` bit set before commit — the pre-commit hook rejects non-executable shell scripts.
- Prefer `git mv` / `git rm` over bare `mv` / `rm`.
- Never `git add .` — add files individually.
- Scripts that shadow a system binary in `~/.local/bin/` (e.g., `ssh`) need `hash -r` in each active shell before functional verification; bash's per-session command hash cache holds the old location until cleared.
