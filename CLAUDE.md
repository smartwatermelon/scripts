# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of macOS-specific utility scripts for system administration, device management, and development workflow automation. All scripts are GNU Bash 5.x compatible and follow strict safety standards.

## Code Architecture

### Script Categories

- **System Management**: `reset-tccd.sh` - macOS daemon management and privacy control
- **Development Tools**: `git-status.sh`, `my-repos.sh`, `beacon-repos.sh`, `vim-setup.sh` - Development workflow utilities
- **Network/Storage**: `smb-mount.sh` - File system management
- **Utilities**: `sleepnow`, `updates` - Simple system utilities

### Common Patterns

#### Error Handling & Safety

All production scripts use `set -euo pipefail` for strict error handling. The increment pattern rule is critical:

- NEVER use `((var++))` or `((var--))` - these fail with `set -e` when var=0
- ALWAYS use `((var += 1))` and `((var -= 1))` patterns instead

**Approved exception — `set -uo pipefail` (omitting `-e`):** `smb-mount.sh` intentionally omits `-e` so that a failure on one SMB share does not abort the entire mount loop; remaining shares still get attempted. This per-share failure-isolation pattern is the only approved reason to drop `-e`. Any other script omitting `-e` requires explicit justification.

#### Shared Functions

Scripts reference shared utilities in `~/.config/bash/functions.sh`:

- `_notif()` - Standardized notification/logging
- `_what_is_this()` - Script identification for logging
- `_kill_clones()` - Process management

#### Logging Architecture

Structured logging pattern used across scripts:

- Log directory: `~/.local/state/`
- File naming: `${SCRIPT_NAME}.out`
- Timestamp format: `$(date): message`
- Output redirection with fallback to stdout

#### Process Management Pattern

`kill_and_wait_for_respawn()` function pattern for daemon management:

- Force kill with `pkill -9`
- Wait for automatic respawn with timeout
- Verify process count restoration
- Used for tccd (`reset-tccd.sh`)

## Development Commands

### Script Validation

```bash
# Check syntax for all scripts
for script in *.sh; do bash -n "$script"; done

# Run shellcheck on all scripts (use -S info for thorough linting)
for script in *.sh; do shellcheck -S info "$script"; done
```

- `shellcheck` does **not** support `zsh` scripts (SC1071 error) — convert shebangs to `#!/usr/bin/env bash` before linting
- All scripts must use `#!/usr/bin/env bash` (not `/bin/bash` or `#!/bin/zsh`)
- Shell scripts require the `+x` bit before committing — the pre-commit hook checks executability and will reject the commit if missing. Fix: `chmod +x <script>` then re-stage before retrying.

### Testing

- Create test scripts in `/tmp/` before modifying production scripts
- Test edge cases: special characters, missing files, network failures
- Verify shellcheck compliance after every modification

## Key Implementation Details

### macOS-Specific Integrations

- Uses `osascript` for AppleScript automation and UI dialogs
- Integrates with macOS keychain via `security` command
- Leverages `diskutil` for disk management
- Process management via `pgrep`/`pkill` with daemon restart patterns

### Network & HTTP

- `curl` with default timeouts will exit code 28 (timeout) on slow/unreachable hosts in batch scripts — add `-m <seconds>` (e.g., `-m 10`) when checking multiple hostnames

### Security Considerations

- 1Password + NetAuth (Apple-ID SSO via `osascript mount volume`) for credential retrieval (`smb-mount.sh`)
- Password prompting via secure AppleScript dialogs
- No hardcoded credentials (uses 1Password CLI where needed)
- Proper cleanup of temporary files

## File Locations & Dependencies

- Scripts live in `/Users/andrewrich/Developer/scripts/` and are symlinked from `~/.local/bin/`
- Files under `lib/` are sourced libraries, not commands: mode `644`, no
  shebang execution, and deliberately not symlinked into `~/.local/bin`.
  `lib/repo-walker.sh` holds the logic for `my-repos.sh` and `beacon-repos.sh`,
  which are configuration-only wrappers.
- Log files go to `~/.local/state/`, not `~/log/`
- LaunchAgent plists are never *untracked* file copies in
  `~/Library/LaunchAgents/` (active). Every entry there must trace back to a
  source of truth in a repo, by one of exactly two patterns:
  - **Symlinked** back to a tracked plist, so editing the tracked file
    changes what launchd loads on next bootstrap and the two cannot drift.
    This is the default for scripts in this repo.
  - **Generated** by a tracked, idempotent installer that also ships an
    uninstaller. `~/Developer/lock-sync/bin/install` is the reference: it
    writes the plist from a heredoc and `bin/uninstall` boots it out and
    removes it. The generator is the source of truth; the plist on disk is
    a build artifact and is correctly absent from the repo.

  Both satisfy the rule. A plain file copy with no repo source satisfies
  neither -- it is unrecoverable if the directory is lost. Verify with:

  Third-party agents (Backblaze, Google, Synergy) are plain files there too,
  so a bare `ls` cannot tell ours from theirs. Audit only ours -- anything
  listed as a regular file must be installer-generated, and any other hit is
  an untracked copy to fix:

  ```bash
  ( cd ~/Library/LaunchAgents || exit
  for f in com.{asiago,andrewrich,smartwatermelon}.*.plist; do
    [[ -e "${f}" ]] || continue
    if [[ -L "${f}" ]]; then
      printf 'symlink   %s -> %s\n' "$(basename "${f}")" "$(readlink "${f}")"
    else
      printf 'FILE      %s   (must be installer-generated)\n' "$(basename "${f}")"
    fi
  done )
  ```

- A plist's source of truth is the repo that owns the script it runs, so
  plists are deliberately spread across repos rather than pooled in one
  directory. Co-location is the point: a plist edited next to its script
  cannot drift from it. Where a given plist belongs:
  - **Script lives in this repo** -> `LaunchAgents/` here.
    `com.asiago.break-watcher.plist` is here because `break-watcher.sh` is.
  - **Script lives in another repo that ships an installer** -> nowhere as a
    tracked file; its installer generates it. `com.smartwatermelon.lock-sync`
    is written by `~/Developer/lock-sync/bin/install`. Do not add a copy here
    or in `~/Developer/LaunchAgents/` -- that would create the drift the
    generator exists to prevent.
  - **Script lives outside any repo, or in a repo with no installer** ->
    `~/Developer/LaunchAgents/`, symlinked into the active directory.
    `com.asiago.mount-smb-shares.plist`, `com.andrewrich.tm-caffeinate.plist`,
    and `com.andrewrich.updates.plist` live there.

  Never keep the same plist in two of these places. `com.asiago.mount-smb-shares.plist`
  was such a copy and was removed in favor of the `~/Developer/LaunchAgents/`
  original that the live symlink already pointed at.
- Scripts themselves should only live in `~/Developer/scripts/`

### External Dependencies

- `~/.config/bash/functions.sh` - Shared utility functions
- `~/.local/state/` directory - Central logging location
- 1Password CLI (`op`) for credential retrieval

### Script-Specific Requirements

- `git-status.sh`: Git repositories under `$HOME` with max depth 3
- `reset-tccd.sh`: macOS privacy daemon management
- `smb-mount.sh`: SMB server access, 1Password + NetAuth (Apple-ID SSO)
