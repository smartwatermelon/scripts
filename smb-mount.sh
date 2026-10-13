#!/usr/bin/env bash
# smb-mount.sh - Idempotent SMB auto-mount for ASIAGO workstation.
# Invoked by ~/Library/LaunchAgents/com.asiago.mount-smb-shares.plist.
# Design: docs/plans/2026-04-16-smb-mount-rebuild-design.md
# Keychain fallback addendum: docs/plans/2026-04-24-smb-mount-keychain-fallback.md
#
# Credential sources (in priority order):
#   1. 1Password via `op read` — canonical; used when `op whoami` silent-succeeds.
#   2. macOS login keychain via `security find-generic-password` — fallback
#      when op is locked/unavailable (LaunchAgents have no TTY; biometric
#      prompts would stack indefinitely). Login keychain auto-unlocks at
#      user login so non-interactive reads are silent.
# 1Password values are synced into the keychain automatically on every
# successful `op read` (1Password stays canonical).
#
# Alerts on persistent failure:
#   - macOS notification banner (rate-limited; see _notify_user).
#   - Persistent sentinel file: ~/.local/state/smb-mount-alert.txt
#     Inspect with: cat ~/.local/state/smb-mount-alert.txt

set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
# Path launchd redirects stdout+stderr to (StandardOutPath/StandardErrorPath in
# com.asiago.mount-smb-shares.plist). log() prints to stderr so it does not
# pollute $() captures (fetch_password returns the password on stdout); both
# streams land in the same on-disk log via launchd. We truncate this file at
# the start of each run so it can't grow unbounded.
LOG_FILE="${HOME}/.local/state/com.asiago.mount-smb-shares.log"

# Parallel arrays — each index defines one share.
# Fields: server | user | share_path | mount_point | op_ref | kc_ref
# Credentials:
#   op_ref  = "op://..."  → 1Password CLI reference (canonical source)
#   kc_ref  = "<service>" → login keychain generic-password service name
#                           (fallback when 1Password vault is locked)
#   BOTH set (recommended): op is canonical, keychain mirrors it. Overnight
#     runs use keychain; next interactive run re-syncs from op if needed.
#   op_ref only: identical to prior behavior — only works when vault unlocked.
#   kc_ref only: keychain-only, never consults 1Password.
#   Both empty:  Apple ID SSO / NetAuth mode — mount via osascript
#                'mount volume' (Finder's NetAuth stack), which always
#                mounts to /Volumes/<basename>. We then symlink mount_point
#                → that /Volumes path so consumers still find the configured
#                location.
SHARE_SERVERS=(
  "romano.local"
  "mimolette.local"
)
SHARE_USERS=(
  "dsadmin"
  ""
)
SHARE_PATHS=(
  "DSMedia/Archives/ASIAGO/archives"
  "extra-vieille/Workspaces"
)
SHARE_MOUNTS=(
  "${HOME}/Downloads/archives"
  "${HOME}/workspaces"
)
SHARE_OP_REFS=(
  "op://Personal/Synology NAS - dsadmin/password"
  ""
)
SHARE_KC_REFS=(
  "smb-synology-dsadmin"
  ""
)

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  # Write to stderr so log lines don't pollute $() captures of helper
  # output (e.g. fetch_password prints the password to stdout). The
  # LaunchAgent plist redirects stdout and stderr to the same file, so
  # log ordering and content in the on-disk log are unchanged.
  printf '%s [%s] %s\n' "${ts}" "${SCRIPT_NAME}" "$*" >&2
}

# Percent-encode every character that isn't a URL-safe unreserved char.
# Operates byte-by-byte via od so multi-byte UTF-8 characters are handled
# correctly — each byte gets its own %XX escape rather than encoding only
# the first byte as the prior printf "'${c}" approach did.
url_encode() {
  local s="$1"
  local hex
  hex=$(printf '%s' "${s}" | od -An -tx1 | tr -d ' \n')
  local out="" i byte decimal octal char
  for ((i = 0; i < ${#hex}; i += 2)); do
    byte="${hex:i:2}"
    decimal=$((16#${byte}))
    octal=$(printf '%03o' "${decimal}")
    char=$(printf '%b' "\\${octal}")
    case "${char}" in
      [a-zA-Z0-9.~_-]) out+="${char}" ;;
      *) out+="%${byte^^}" ;;
    esac
  done
  printf '%s' "${out}"
}

# ─── Credential helpers ────────────────────────────────────────────────
# Silent probe: is `op` currently signed in (session valid)?
# Verified 2026-04-24: op whoami does NOT trigger TouchID in either state
# (signed out → exit 1 silently; signed in → exit 0 silently). 2s timeout
# guards against network hiccups or XPC hangs.
#
# Runs in a subshell with OP_SERVICE_ACCOUNT_TOKEN unset so we probe the
# user's personal session — which can read Personal-vault items — rather
# than any ambient service-account session (typically scoped to a single
# Automation vault). Parent env is unaffected. Same auth-context issue
# that the `ssh` wrapper addresses in _unlock_remote_keychain.
_op_whoami_ok() {
  command -v op &>/dev/null || return 1
  (
    unset OP_SERVICE_ACCOUNT_TOKEN
    timeout 2 op whoami >/dev/null 2>&1
  )
}

# Read a password from the login keychain by service name. Login keychain is
# auto-unlocked at user login, so this does not prompt when run from a
# LaunchAgent. Stdout is the password (trailing newline stripped); non-zero
# exit means the item is missing or ACL-denied.
_kc_read() {
  local svc="$1"
  local pw
  pw="$(security find-generic-password -s "${svc}" -w 2>/dev/null)" || return 1
  printf '%s' "${pw%$'\n'}"
}

# Create or update a login-keychain generic password.
#
# If the item already exists, we UPDATE it WITHOUT -T so the existing ACL
# is preserved. Adding -T flags on an existing item triggers a macOS auth
# dialog to authorize the ACL change — which would fire every time
# 1Password and the keychain drift apart. Not what we want for a silent
# background sync.
#
# If the item does not exist (unusual — Task 7's manual seed is supposed
# to create it), we CREATE it with -T so LaunchAgent runs can read it
# silently via the pre-authorized binaries.
_kc_write() {
  local svc="$1" acct="$2" pw="$3"
  if security find-generic-password -s "${svc}" -a "${acct}" >/dev/null 2>&1; then
    security add-generic-password \
      -s "${svc}" -a "${acct}" -w "${pw}" -U 2>/dev/null
  else
    security add-generic-password \
      -s "${svc}" -a "${acct}" -w "${pw}" \
      -T /usr/bin/security \
      -T /sbin/mount_smbfs \
      -T "${HOME}/.local/bin/smb-mount.sh" 2>/dev/null
  fi
}

# Surface a user-visible alert. Dual-channel because macOS frequently
# suppresses script-origin notifications silently (Focus mode, missing
# Automation permission for the invoking terminal, etc.):
#   1. osascript banner — rate-limited to once per BANNER_COOLDOWN_SECONDS
#      (default 30 min) so a persistent failure doesn't spam Notification
#      Center. A successful run (see main) clears the cooldown so the next
#      failure alerts immediately.
#   2. Persistent sentinel file — overwritten on EVERY call; survives
#      banner suppression. Inspect with:
#          cat ~/.local/state/smb-mount-alert.txt
# Paths and cooldown are env-overridable for tests.
# Modification time of a file, in epoch seconds; 0 if unavailable.
#
# `stat` is not portable: BSD/macOS spells this `-f '%m'`, GNU/Linux spells
# it `-c '%Y'`, and GNU's `-f` means *filesystem* info, so it prints a
# "File: ..." block rather than failing in a way a bare `||` would catch.
# Try BSD first (this script's home platform), then GNU, and validate that
# what came back is actually a number before trusting it.
_file_mtime() {
  local f="$1" ts=""
  ts=$(stat -f '%m' "${f}" 2>/dev/null) || ts=""
  [[ "${ts}" =~ ^[0-9]+$ ]] || ts=$(stat -c '%Y' "${f}" 2>/dev/null) || ts=""
  [[ "${ts}" =~ ^[0-9]+$ ]] || ts=0
  printf '%s' "${ts}"
}

_notify_user() {
  local title="$1" msg="$2"
  local alert_file="${ALERT_FILE:-${HOME}/.local/state/smb-mount-alert.txt}"
  local cooldown_file="${BANNER_COOLDOWN_FILE:-${HOME}/.local/state/smb-mount-banner.ts}"
  local cooldown_sec="${BANNER_COOLDOWN_SECONDS:-1800}"

  printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${title}" "${msg}" \
    >"${alert_file}" 2>/dev/null || true

  local now banner_ts age
  now=$(date +%s)
  if [[ -f "${cooldown_file}" ]]; then
    banner_ts=$(_file_mtime "${cooldown_file}")
    age=$((now - banner_ts))
  else
    age=$((cooldown_sec + 1))
  fi

  if ((age > cooldown_sec)); then
    osascript -e "display notification \"${msg}\" with title \"${title}\"" \
      >/dev/null 2>&1 || true
    touch "${cooldown_file}" 2>/dev/null || true
  fi
}

# Fetch the password for a share. 1Password is canonical; keychain is a
# mirror usable when the vault is locked. Flow:
#   1. If op_ref set AND `op whoami` silent-succeeds:
#        → op read with 5s timeout
#        → on success, compare to kc (if kc_ref set) and update kc on diff
#        → return op value
#   2. If kc_ref set: return kc value
#   3. Otherwise: notify + return 1
# Called only when a share needs (re)mounting, so the per-run cost is
# bounded and does not fire while shares are already mounted.
fetch_password() {
  local user="$1" op_ref="$2" kc_ref="$3"
  local pw=""

  if [[ -n "${op_ref}" ]] && _op_whoami_ok; then
    # Same auth-context subshell as _op_whoami_ok — use the user's
    # personal session to read the Personal-vault item.
    if pw="$( (
      unset OP_SERVICE_ACCOUNT_TOKEN
      timeout 5 op read "${op_ref}" 2>/dev/null
    ))" && [[ -n "${pw}" ]]; then
      pw="${pw%$'\n'}"
      log "  op read succeeded (${op_ref})"
      if [[ -n "${kc_ref}" ]]; then
        local kc_pw
        kc_pw="$(_kc_read "${kc_ref}")" || kc_pw=""
        if [[ "${kc_pw}" != "${pw}" ]]; then
          if _kc_write "${kc_ref}" "${user}" "${pw}"; then
            log "  keychain updated from 1Password (${kc_ref})"
          else
            log "  WARNING: keychain write failed for ${kc_ref}"
          fi
        fi
      fi
      printf '%s' "${pw}"
      return 0
    fi
    log "  op unavailable or read failed; falling back to keychain"
  fi

  if [[ -n "${kc_ref}" ]]; then
    if pw="$(_kc_read "${kc_ref}")" && [[ -n "${pw}" ]]; then
      log "  keychain read succeeded (${kc_ref})"
      printf '%s' "${pw}"
      return 0
    fi
    log "  keychain read failed for ${kc_ref}"
    _notify_user "SMB password lookup failed" \
      "Missing or unreadable keychain entry: ${kc_ref}"
    return 1
  fi

  log "  no credential source available for ${user}"
  return 1
}

# True if $1 is currently a mount point for any smbfs mount.
# Uses grep -F for a literal mount-point match so paths with regex
# metacharacters (., +, [, etc.) don't broaden the match.
is_mounted() {
  local mp="$1"
  mount | grep -qF " on ${mp} (smbfs"
}

# True if anything at all (any fstype) is currently mounted at $1.
any_mount_at() {
  local mp="$1"
  mount | grep -qF " on ${mp} ("
}

# Find any smbfs mount whose source URL (after normalization) equals $1
# (e.g. "mimolette.local/extra-vieille/Workspaces"). Prints the mount path
# (/Volumes/...) on stdout, returns 1 with no output if no match.
#
# Normalization strips the leading "//" and any "user@" prefix that appears
# before the first path separator, leaving "server/path". Exact-match (rather
# than a suffix glob) eliminates the collision class where two shares share
# a path tail (e.g. "A.local/foo" vs "B.local/bar/foo").
find_existing_smbfs_mount() {
  local key="$1"
  local mount_out line src mp tail line_no_opts
  mount_out="$(mount)"
  while IFS= read -r line; do
    # Strip the options block " (fstype, ...)" first so the remaining string is
    # purely "<source> on <mountpoint>". This avoids mis-parses when " on "
    # appears inside the source URL (e.g. //server/share on ice/path).
    line_no_opts="${line% (*}"
    mp="${line_no_opts##* on }" # mount point: after the last " on "
    src="${line_no_opts% on *}" # source: before the last " on "
    tail="${src#//}"
    # Strip user@ only when @ appears before the first /, so a legitimate @ in
    # the path (e.g. //server/foo@bar) is not mistaken for auth credentials.
    if [[ "${tail}" == *"@"* && "${tail%%@*}" != *"/"* ]]; then
      tail="${tail#*@}"
    fi
    if [[ "${tail}" == "${key}" && "${line}" == *"(smbfs"* ]]; then
      printf '%s\n' "${mp}"
      return 0
    fi
  done <<<"${mount_out}"
  return 1
}

# Make sure the mount point is a directory ready to receive mount_smbfs.
prepare_mount_point() {
  local mp="$1"
  if any_mount_at "${mp}"; then
    log "Detaching stale mount at ${mp}"
    local umount_err
    if ! umount_err="$(umount "${mp}" 2>&1)"; then
      log "  warning: umount failed (${umount_err}); mount_smbfs may report Device busy"
    fi
  fi
  if [[ -L "${mp}" ]]; then
    log "Removing stale symlink at mount point: ${mp}"
    rm -f "${mp}"
  fi
  if [[ -e "${mp}" && ! -d "${mp}" ]]; then
    log "Removing non-directory at mount point: ${mp}"
    rm -f "${mp}"
  fi
  if [[ ! -e "${mp}" ]]; then
    log "Creating mount point: ${mp}"
    mkdir -p "${mp}"
  fi
}

# Ensure $link is a symlink pointing at $target, replacing other state if safe.
# Refuses to clobber a non-empty directory (returns 1 after logging).
ensure_symlink() {
  local link="$1" target="$2"
  if [[ -L "${link}" ]]; then
    local current
    current="$(readlink "${link}")"
    if [[ "${current}" == "${target}" ]]; then
      return 0
    fi
    log "  replacing symlink ${link} (was -> ${current})"
    rm -f "${link}"
  elif [[ -d "${link}" ]]; then
    if ! rmdir "${link}" 2>/dev/null; then
      log "  ERROR: ${link} is a non-empty directory, refusing to replace with symlink"
      return 1
    fi
  elif [[ -e "${link}" ]]; then
    rm -f "${link}"
  fi
  ln -sfn "${target}" "${link}"
}

# Mount via mount_smbfs with URL-embedded credentials sourced from either
# 1Password (canonical) or the login keychain (fallback). Credential
# resolution is delegated to fetch_password, which handles the op-whoami
# safety gate and keychain fallback.
mount_one_cred() {
  local server="$1"
  local user="$2"
  local share_path="$3"
  local mp="$4"
  local op_ref="$5"
  local kc_ref="$6"

  prepare_mount_point "${mp}"

  local pw
  if ! pw="$(fetch_password "${user}" "${op_ref}" "${kc_ref}")"; then
    return 1
  fi

  local enc_user enc_pw
  enc_user="$(url_encode "${user}")"
  enc_pw="$(url_encode "${pw}")"
  local url="//${enc_user}:${enc_pw}@${server}/${share_path}"

  local mount_err
  if mount_err="$(mount_smbfs -N "${url}" "${mp}" 2>&1)"; then
    log "  mount_smbfs succeeded"
  else
    [[ -n "${enc_pw}" ]] && mount_err="${mount_err//${enc_pw}/REDACTED}"
    mount_err="$(sed 's|:[^@]*@|:REDACTED@|g' <<<"${mount_err}")"
    log "  mount_smbfs failed: ${mount_err}"
    if grep -qiE "authentication|permission denied|session setup failed" <<<"${mount_err}"; then
      _notify_user "SMB mount auth error" \
        "Failed to mount //${server}/${share_path} — check keychain: ${kc_ref:-(none)}"
    fi
    return 1
  fi

  if ! is_mounted "${mp}"; then
    log "  verification failed: ${mp} not in mount table"
    return 1
  fi
  log "  verified mounted"
  return 0
}

# Mount via NetAuth (AppleScript), which uses the Apple-ID SSO / IdMS stack
# Finder uses. Cannot specify a destination path — macOS always picks
# /Volumes/<basename>. We then ensure mount_point is a symlink to that path.
# 4th arg (required): pre-computed find_existing_smbfs_mount result from the
# caller's already-ok check — passed through to avoid a redundant subshell.
# May be empty string (share not yet mounted); that is distinct from absent.
mount_one_netauth() {
  local server="$1"
  local share_path="$2"
  local mp="$3"
  [[ $# -ge 4 ]] || {
    log "BUG: mount_one_netauth requires 4 args (existing pre-computed by caller)"
    return 1
  }
  local existing="$4"

  local server_share="${server}/${share_path}"
  local url="smb://${server_share}"

  if [[ -z "${existing}" ]]; then
    log "  mounting via NetAuth: ${url}"
    # URL passed via argv (not shell-interpolated into AppleScript source), so any
    # backslash / double-quote / space in a future share path round-trips safely.
    local osa_err
    if ! osa_err="$(
      osascript - "${url}" 2>&1 <<'APPLESCRIPT'
on run argv
  mount volume (item 1 of argv)
end run
APPLESCRIPT
    )"; then
      log "  osascript mount volume failed: ${osa_err}"
      return 1
    fi
    existing="$(find_existing_smbfs_mount "${server_share}")"
    if [[ -z "${existing}" ]]; then
      log "  ERROR: osascript reported success but share not found in mount table"
      return 1
    fi
    log "  mounted at ${existing}"
  fi

  if ! ensure_symlink "${mp}" "${existing}"; then
    return 1
  fi
  log "  symlink ${mp} -> ${existing} verified"
  return 0
}

# Return 0 if SSO-mode share is already fully satisfied: symlink exists and
# points to a live smbfs mount of the expected share.
# Optional 3rd arg: pre-computed find_existing_smbfs_mount result to avoid a
# redundant subshell when the caller already has the value.
sso_already_ok() {
  local mp="$1" server_share="$2" existing="${3:-}"
  [[ -L "${mp}" ]] || return 1
  local current
  current="$(readlink "${mp}")"
  is_mounted "${current}" || return 1
  if [[ -z "${existing}" ]]; then
    existing="$(find_existing_smbfs_mount "${server_share}")"
  fi
  [[ "${existing}" == "${current}" ]]
}

mount_one() {
  local server="$1"
  local user="$2"
  local share_path="$3"
  local mp="$4"
  local op_ref="$5"
  local kc_ref="$6"

  local auth_label
  if [[ -n "${op_ref}" && -n "${kc_ref}" ]]; then
    auth_label="${user}@ (op+kc)"
  elif [[ -n "${op_ref}" ]]; then
    auth_label="${user}@ (op)"
  elif [[ -n "${kc_ref}" ]]; then
    auth_label="${user}@ (kc)"
  else
    auth_label="(NetAuth/SSO)"
  fi
  log "Processing ${auth_label} //${server}/${share_path} -> ${mp}"

  local existing=""
  if [[ -n "${op_ref}" || -n "${kc_ref}" ]]; then
    if is_mounted "${mp}"; then
      log "  already mounted, skipping"
      return 0
    fi
  else
    existing="$(find_existing_smbfs_mount "${server}/${share_path}")" || true
    if sso_already_ok "${mp}" "${server}/${share_path}" "${existing}"; then
      log "  already mounted via symlink, skipping"
      return 0
    fi
  fi

  if ! ping -c 1 -W 2000 "${server}" >/dev/null 2>&1; then
    log "  unreachable (ping failed): ${server}"
    return 1
  fi

  if [[ -n "${op_ref}" || -n "${kc_ref}" ]]; then
    mount_one_cred "${server}" "${user}" "${share_path}" "${mp}" "${op_ref}" "${kc_ref}"
  else
    mount_one_netauth "${server}" "${share_path}" "${mp}" "${existing}"
  fi
}

main() {
  # Reset per-run log so it can't grow unbounded. Launchd holds this file in
  # append mode, so writes after truncate correctly resume at position 0.
  : >"${LOG_FILE}" 2>/dev/null || true

  log "Starting SMB mount pass (${#SHARE_SERVERS[@]} shares configured)"

  local failures=0
  local i
  for ((i = 0; i < ${#SHARE_SERVERS[@]}; i += 1)); do
    if ! mount_one \
      "${SHARE_SERVERS[i]}" \
      "${SHARE_USERS[i]}" \
      "${SHARE_PATHS[i]}" \
      "${SHARE_MOUNTS[i]}" \
      "${SHARE_OP_REFS[i]}" \
      "${SHARE_KC_REFS[i]}"; then
      failures=$((failures + 1))
    fi
  done

  if ((failures > 0)); then
    log "Finished with ${failures} failure(s)"
    return 1
  fi
  log "Finished, all shares mounted"
  # Clear any stale sentinel + banner cooldown from a prior alert — all
  # shares are healthy now. Next failure (if any) fires a banner
  # immediately rather than waiting out the leftover cooldown.
  rm -f \
    "${ALERT_FILE:-${HOME}/.local/state/smb-mount-alert.txt}" \
    "${BANNER_COOLDOWN_FILE:-${HOME}/.local/state/smb-mount-banner.ts}" \
    2>/dev/null || true
  return 0
}

# Skip main when sourced (e.g., by bats tests loading function defs).
# Mirrors the guard in the `ssh` wrapper in this repo.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
