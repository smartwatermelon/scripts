# smb-mount keychain fallback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop the overnight 1Password TouchID prompt caused by `com.asiago.mount-smb-shares` by making `smb-mount.sh` probe 1Password safely, fall back to the login keychain when 1Password is locked, and keep the two stores in sync with 1Password as canonical.

**Architecture:** Introduce a `fetch_password` helper that (1) uses `timeout 2 op whoami` as a silent gate — verified empirically that this never prompts for TouchID whether signed in or out — to decide whether it's safe to call `op read`; (2) when `op read` succeeds, compares the retrieved value to the login-keychain item and updates the keychain if they differ (1Password is canonical); (3) when the op gate fails, reads the password from the login keychain directly (auto-unlocked at user login, so LaunchAgents can access it without prompting). A `SHARE_KC_REFS` parallel array is added alongside `SHARE_OP_REFS`; `mount_one_op` is renamed `mount_one_cred` to reflect that it now handles either or both. Mount-time authentication failures surface a macOS user notification so bad keychain entries get noticed rather than silently retrying forever.

**Tech Stack:** GNU bash 5.x, `security(1)` (macOS login keychain), 1Password CLI 2.x (`op`), `osascript` for notifications, bats for tests, shellcheck for lint.

**Repo context:** This plan operates in `~/Developer/scripts` (`smartwatermelon/scripts` repo, NOT the dotfiles repo). Branch: `claude/fix-smb-overnight-touchid-20260424-111637`. The target script is `./smb-mount.sh` at repo root; tests in `tests/`; fixtures in `tests/fixtures/`. The LaunchAgent that invokes it is `~/Library/LaunchAgents/com.asiago.mount-smb-shares.plist` (symlinked from `~/Developer/LaunchAgents/` — outside this repo).

**Relationship to PR #64 (`feat: ssh wrapper unlocks remote login keychain on connect`, merged 2026-04-24):** The sibling `ssh` script now carries a `_fetch_op` helper and a `# op-keychain:` annotation pattern for a different purpose (unlocking the *remote* login keychain after SSH). No direct code sharing in this plan — `ssh`'s helper is interactive-error-focused (categorizes "not signed in" as user action), whereas smb-mount's fetch must silently fall back. We duplicate the shape but keep the semantics distinct. If a third call site appears, extract to `lib/op-helpers.sh` in a follow-up.

**Background evidence:** Investigation transcript is in the prior session. One-line version: overnight, `romano.local` (Synology NAS) sleeps → SMB mount drops → `smb-mount.sh` tries to remount → `op read` blocks on a locked vault → TouchID prompt queues → script exits non-zero → `KeepAlive.SuccessfulExit=false` respawns → each ~60 s the cycle re-queues the prompt until the user arrives.

---

## Task 1: Baseline verification

**Files:** none modified, just establishing ground truth

**Step 1: Confirm branch**

Run:

```bash
git -C ~/Developer/scripts branch --show-current
```

Expected: `claude/fix-smb-overnight-touchid-<timestamp>` (NOT `main`).

**Step 2: Confirm current shellcheck baseline for smb-mount.sh**

Run:

```bash
shellcheck -S info ~/Developer/scripts/smb-mount.sh
```

Expected: exit 0, no output. Any pre-existing notes are recorded here so we don't attribute them to this change.

**Step 3: Confirm current bats suite passes**

Run:

```bash
cd ~/Developer/scripts && bats tests/ssh-wrapper.bats
```

Expected: all passing. (Smoke-test that our baseline is clean before we add tests.)

**Step 4: Confirm happy path behavior**

Run:

```bash
op whoami && echo op-unlocked
~/.local/bin/smb-mount.sh
echo "exit=$?"
tail -8 ~/.local/state/com.asiago.mount-smb-shares.log
```

Expected: `op-unlocked`; script exits 0; log shows "already mounted, skipping" for both shares.

**Step 5: No commit** (baseline only).

---

## Task 2: Add `main "$@"` source guard to `smb-mount.sh`

**Files:**

- Modify: `smb-mount.sh` — last line

This matches the idiom already used in `ssh` (line 506): `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then … fi`. This lets bats `source` the file to load functions without executing `main`.

**Step 1: Current bottom**

Run:

```bash
tail -3 ~/Developer/scripts/smb-mount.sh
```

Expected:

```bash
}

main "$@"
```

**Step 2: Replace with source-guarded invocation**

Change:

```bash
main "$@"
```

to:

```bash
# Skip main when sourced (e.g., by bats tests loading function defs).
# This mirrors the guard in the `ssh` wrapper in this repo.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

**Step 3: Verify LaunchAgent path still runs main**

Run:

```bash
~/.local/bin/smb-mount.sh
echo "exit=$?"
```

Expected: exit 0, log shows normal "Finished, all shares mounted".

**Step 4: Verify sourcing does NOT run main**

Run:

```bash
# shellcheck disable=SC1091
( source ~/Developer/scripts/smb-mount.sh; type -t main )
```

Expected: `function` printed; no "Starting SMB mount pass" log line.

**Step 5: Shellcheck and commit**

```bash
shellcheck -S info ~/Developer/scripts/smb-mount.sh
cd ~/Developer/scripts
git add smb-mount.sh
git commit -m "refactor(smb-mount): guard main so tests can source the script"
```

---

## Task 3: Bats test scaffold (failing tests — RED phase)

**Files:**

- Create: `tests/smb-mount.bats`

Follows the `tests/ssh-wrapper.bats` conventions: sources the script in `setup()`, PATH-stubs `op` and `security` via a `_setup_fake_op` / `_setup_fake_security` pair, one `@test` per branch.

**Step 1: Create the test file**

Create `tests/smb-mount.bats` with this content:

```bash
#!/usr/bin/env bats
# bats tests for smb-mount.sh
#
# Run from repo root:  bats tests/smb-mount.bats

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${SCRIPT_DIR}/smb-mount.sh"
  TMPDIR_T="$(mktemp -d)"
  # shellcheck disable=SC1090
  source "${SCRIPT}"
}

teardown() {
  rm -rf "${TMPDIR_T}"
}

# ─────────────────────────────────────────────────────────────────────────
# Fake op/security/osascript helpers
# ─────────────────────────────────────────────────────────────────────────

_setup_fake_op() {
  # Creates $TMPDIR_T/bin/op that responds to:
  #   op whoami → mode-controlled silent exit
  #   op read REF → mode-controlled value or error
  # Env:
  #   OP_WHOAMI_MODE: signed_in (default) | signed_out
  #   OP_READ_MODE:   success (default)   | failure
  #   OP_READ_VALUE:  stdout on success (default "dummy-op-secret")
  mkdir -p "${TMPDIR_T}/bin"
  cat >"${TMPDIR_T}/bin/op" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  whoami)
    case "${OP_WHOAMI_MODE:-signed_in}" in
      signed_in)
        printf 'URL: https://my.1password.com\nEmail: test@example.com\n'
        exit 0
        ;;
      signed_out)
        printf '[ERROR] account is not signed in\n' >&2
        exit 1
        ;;
    esac
    ;;
  read)
    case "${OP_READ_MODE:-success}" in
      success)
        printf '%s\n' "${OP_READ_VALUE:-dummy-op-secret}"
        exit 0
        ;;
      failure)
        printf '[ERROR] op read failed for %s\n' "$2" >&2
        exit 1
        ;;
    esac
    ;;
esac
EOF
  chmod +x "${TMPDIR_T}/bin/op"
}

_setup_fake_security() {
  # Creates $TMPDIR_T/bin/security that handles:
  #   security find-generic-password -s SVC -w   → mode-controlled pw or miss
  #   security add-generic-password ...          → records args into KC_WRITE_LOG
  # Env:
  #   KC_READ_MODE: hit (default) | miss
  #   KC_READ_VALUE: stdout on hit (default "dummy-kc-secret")
  #   KC_WRITE_LOG: path to append one line per add-generic-password invocation
  mkdir -p "${TMPDIR_T}/bin"
  cat >"${TMPDIR_T}/bin/security" <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"
shift || true
case "${sub}" in
  find-generic-password)
    case "${KC_READ_MODE:-hit}" in
      hit)
        printf '%s\n' "${KC_READ_VALUE:-dummy-kc-secret}"
        exit 0
        ;;
      miss)
        printf '\n' >&2
        exit 44  # SecKeychainSearchCopyNext: item not found
        ;;
    esac
    ;;
  add-generic-password)
    if [[ -n "${KC_WRITE_LOG:-}" ]]; then
      printf '%s\n' "$*" >>"${KC_WRITE_LOG}"
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${TMPDIR_T}/bin/security"
}

_setup_fake_osascript() {
  # Captures osascript invocations into OSASCRIPT_LOG (one line per call).
  mkdir -p "${TMPDIR_T}/bin"
  cat >"${TMPDIR_T}/bin/osascript" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${OSASCRIPT_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"${OSASCRIPT_LOG}"
fi
exit 0
EOF
  chmod +x "${TMPDIR_T}/bin/osascript"
}

# ─────────────────────────────────────────────────────────────────────────
# _op_whoami_ok
# ─────────────────────────────────────────────────────────────────────────

@test "_op_whoami_ok: returns 0 when signed in" {
  _setup_fake_op
  OP_WHOAMI_MODE=signed_in PATH="${TMPDIR_T}/bin:${PATH}" run _op_whoami_ok
  [[ "${status}" -eq 0 ]]
}

@test "_op_whoami_ok: returns 1 when signed out" {
  _setup_fake_op
  OP_WHOAMI_MODE=signed_out PATH="${TMPDIR_T}/bin:${PATH}" run _op_whoami_ok
  [[ "${status}" -eq 1 ]]
}

@test "_op_whoami_ok: returns 1 when op binary missing" {
  mkdir -p "${TMPDIR_T}/empty"
  PATH="${TMPDIR_T}/empty:/usr/bin:/bin" run _op_whoami_ok
  [[ "${status}" -eq 1 ]]
}

# ─────────────────────────────────────────────────────────────────────────
# fetch_password
# ─────────────────────────────────────────────────────────────────────────

@test "fetch_password: op signed-out + kc hit → returns kc value, no op read" {
  _setup_fake_op
  _setup_fake_security
  OP_WHOAMI_MODE=signed_out \
    KC_READ_MODE=hit KC_READ_VALUE="kc-secret" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "kc-secret" ]]
}

@test "fetch_password: op signed-in + op+kc match → returns op value, no kc write" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  export KC_WRITE_LOG="${TMPDIR_T}/kc-writes"
  : >"${KC_WRITE_LOG}"
  OP_WHOAMI_MODE=signed_in \
    OP_READ_MODE=success OP_READ_VALUE="same-secret" \
    KC_READ_MODE=hit KC_READ_VALUE="same-secret" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "same-secret" ]]
  [[ ! -s "${KC_WRITE_LOG}" ]]
}

@test "fetch_password: op signed-in + kc differs → returns op value, kc gets updated" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  export KC_WRITE_LOG="${TMPDIR_T}/kc-writes"
  : >"${KC_WRITE_LOG}"
  OP_WHOAMI_MODE=signed_in \
    OP_READ_MODE=success OP_READ_VALUE="new-secret" \
    KC_READ_MODE=hit KC_READ_VALUE="old-secret" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "new-secret" ]]
  grep -q "smb-synology-dsadmin" "${KC_WRITE_LOG}"
  grep -q "new-secret" "${KC_WRITE_LOG}"
}

@test "fetch_password: op signed-out + kc miss → fails with notification" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  export OSASCRIPT_LOG="${TMPDIR_T}/osascript-log"
  : >"${OSASCRIPT_LOG}"
  OP_WHOAMI_MODE=signed_out \
    KC_READ_MODE=miss \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -ne 0 ]]
  grep -q "SMB password lookup failed" "${OSASCRIPT_LOG}"
}

@test "fetch_password: op signed-in but read fails → falls back to kc" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  OP_WHOAMI_MODE=signed_in \
    OP_READ_MODE=failure \
    KC_READ_MODE=hit KC_READ_VALUE="kc-fallback" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "kc-fallback" ]]
}
```

**Step 2: Run the suite — expect all new tests to fail**

Run:

```bash
cd ~/Developer/scripts && bats tests/smb-mount.bats
```

Expected: 8 tests fail (3 on `_op_whoami_ok`, 5 on `fetch_password`) with "command not found" for undefined functions. The ssh-wrapper.bats tests still pass.

**Step 3: Commit the failing tests**

```bash
cd ~/Developer/scripts
git add tests/smb-mount.bats
git commit -m "test(smb-mount): add failing bats tests for op whoami gate and fetch_password"
```

---

## Task 4: Implement helpers — `_op_whoami_ok`, `_kc_read`, `_kc_write`, `_notify_user` (GREEN for whoami tests)

**Files:**

- Modify: `smb-mount.sh` — insert helper block after `url_encode` and before `is_mounted` (around line 100)

**Step 1: Insert helpers**

Add this block just before the `is_mounted()` definition:

```bash
# ─── Credential helpers ────────────────────────────────────────────────
# Silent probe: is `op` currently signed in (session valid)?
# Verified 2026-04-24: op whoami does NOT trigger TouchID in either state
# (signed out → exit 1 silently; signed in → exit 0 silently). 2s timeout
# guards against network hiccups or XPC hangs.
_op_whoami_ok() {
  command -v op &>/dev/null || return 1
  timeout 2 op whoami >/dev/null 2>&1
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

# Create or update a login-keychain generic password. -T ACL entries allow
# these binaries to read the item non-interactively. -U updates if it exists.
_kc_write() {
  local svc="$1" acct="$2" pw="$3"
  security add-generic-password \
    -s "${svc}" \
    -a "${acct}" \
    -w "${pw}" \
    -T /usr/bin/security \
    -T /sbin/mount_smbfs \
    -T "${HOME}/.local/bin/smb-mount.sh" \
    -U 2>/dev/null
}

# Best-effort macOS notification. Never fails the run; osascript absence is
# non-fatal.
_notify_user() {
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg}\" with title \"${title}\"" \
    >/dev/null 2>&1 || true
}
```

**Step 2: Run bats**

Run:

```bash
cd ~/Developer/scripts && bats tests/smb-mount.bats
```

Expected: 3 `_op_whoami_ok` tests now PASS; 5 `fetch_password` tests still FAIL (function undefined).

**Step 3: Shellcheck and commit**

```bash
shellcheck -S info ~/Developer/scripts/smb-mount.sh
cd ~/Developer/scripts
git add smb-mount.sh
git commit -m "feat(smb-mount): add _op_whoami_ok, _kc_read, _kc_write, _notify_user helpers"
```

---

## Task 5: Implement `fetch_password` (GREEN for fetch_password tests)

**Files:**

- Modify: `smb-mount.sh` — add `fetch_password` immediately after the helpers from Task 4

**Step 1: Add the function**

Append just below the `_notify_user` definition:

```bash
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
    if pw="$(timeout 5 op read "${op_ref}" 2>/dev/null)" && [[ -n "${pw}" ]]; then
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
```

**Step 2: Run bats — expect all 8 pass**

Run:

```bash
cd ~/Developer/scripts && bats tests/smb-mount.bats
```

Expected: 8 of 8 passing.

**Step 3: Shellcheck and commit**

```bash
shellcheck -S info ~/Developer/scripts/smb-mount.sh
cd ~/Developer/scripts
git add smb-mount.sh
git commit -m "feat(smb-mount): add fetch_password with op→keychain fallback and sync"
```

---

## Task 6: Add `SHARE_KC_REFS`, rename `mount_one_op`, wire auth-error notification

**Files:**

- Modify: `smb-mount.sh` — header comment block, `SHARE_KC_REFS` array, `mount_one_op` → `mount_one_cred`, `mount_one` caller, `main` loop

**Step 1: Update the parallel-arrays header comment**

Replace the existing `# Fields: … | op_ref` block and the `op_ref can be:` list with:

```bash
# Parallel arrays — each index defines one share.
# Fields: server | user | share_path | mount_point | op_ref | kc_ref
# Credentials:
#   op_ref  = "op://..."  → 1Password CLI reference (canonical source)
#   kc_ref  = "<service>" → login keychain generic-password service name
#                           (fallback when 1Password vault is locked)
#   BOTH set (recommended): op is canonical, keychain mirrors it. Overnight
#     runs use keychain; next interactive run re-syncs from op if needed.
#   op_ref only: same as prior behavior — only works when vault unlocked.
#   kc_ref only: keychain-only.
#   Both empty: Apple-ID SSO / NetAuth mode (unchanged).
```

**Step 2: Add `SHARE_KC_REFS`**

Immediately after `SHARE_OP_REFS=(…)`, add:

```bash
SHARE_KC_REFS=(
  "smb-synology-dsadmin"
  ""
)
```

Confirm the array has the same length as the others:

```bash
grep -c '"' ~/Developer/scripts/smb-mount.sh | head
```

(Spot-check visually: all six arrays should have exactly two quoted entries.)

**Step 3: Rename `mount_one_op` → `mount_one_cred` and swap the credential fetch**

Find the function (originally at line 166) and change its signature and credential block.

Before:

```bash
mount_one_op() {
  local server="$1"
  local user="$2"
  local share_path="$3"
  local mp="$4"
  local op_ref="$5"

  prepare_mount_point "${mp}"

  local pw
  if ! pw="$(op read "${op_ref}" 2>/dev/null)"; then
    log "  op read failed for ${op_ref}"
    return 1
  fi
  if [[ -z "${pw}" ]]; then
    log "  op read returned empty password for ${op_ref}"
    return 1
  fi
```

After:

```bash
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
```

Leave the remainder (`url_encode`, `mount_smbfs`, verification) unchanged until Step 4.

**Step 4: Add auth-error notification in the mount-failure branch**

Find the block:

```bash
else
  mount_err="$(sed 's|:[^@]*@|:REDACTED@|g' <<< "${mount_err}")"
  log "  mount_smbfs failed: ${mount_err}"
  return 1
fi
```

Change to:

```bash
else
  mount_err="$(sed 's|:[^@]*@|:REDACTED@|g' <<< "${mount_err}")"
  log "  mount_smbfs failed: ${mount_err}"
  if grep -qiE "authentication|permission denied|session setup failed" <<<"${mount_err}"; then
    _notify_user "SMB mount auth error" \
      "Failed to mount //${server}/${share_path} — check keychain: ${kc_ref:-(none)}"
  fi
  return 1
fi
```

**Step 5: Update `mount_one` to accept and pass `kc_ref`**

In `mount_one()`'s signature add a 6th positional:

```bash
local op_ref="$5"
local kc_ref="$6"
```

Update the "Processing" log line so the auth label reflects both sources. Replace:

```bash
local auth_label
if [[ -n "${op_ref}" ]]; then
  auth_label="${user}@ (op)"
else
  auth_label="(NetAuth/SSO)"
fi
```

with:

```bash
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
```

Change the cred-path branch. Before:

```bash
if [[ -n "${op_ref}" ]]; then
  mount_one_op "${server}" "${user}" "${share_path}" "${mp}" "${op_ref}"
else
  mount_one_netauth "${server}" "${share_path}" "${mp}" "${existing}"
fi
```

After:

```bash
if [[ -n "${op_ref}" || -n "${kc_ref}" ]]; then
  mount_one_cred "${server}" "${user}" "${share_path}" "${mp}" "${op_ref}" "${kc_ref}"
else
  mount_one_netauth "${server}" "${share_path}" "${mp}" "${existing}"
fi
```

Also update the `is_mounted` early-return branch's condition — it currently only short-circuits when `op_ref` is set. Change:

```bash
if [[ -n "${op_ref}" ]]; then
  if is_mounted "${mp}"; then
    log "  already mounted, skipping"
    return 0
  fi
else
  ...
fi
```

to:

```bash
if [[ -n "${op_ref}" || -n "${kc_ref}" ]]; then
  if is_mounted "${mp}"; then
    log "  already mounted, skipping"
    return 0
  fi
else
  ...
fi
```

**Step 6: Update `main`'s loop to pass `SHARE_KC_REFS`**

Find the call in `main`:

```bash
if ! mount_one \
  "${SHARE_SERVERS[i]}" \
  "${SHARE_USERS[i]}" \
  "${SHARE_PATHS[i]}" \
  "${SHARE_MOUNTS[i]}" \
  "${SHARE_OP_REFS[i]}"; then
```

Change to:

```bash
if ! mount_one \
  "${SHARE_SERVERS[i]}" \
  "${SHARE_USERS[i]}" \
  "${SHARE_PATHS[i]}" \
  "${SHARE_MOUNTS[i]}" \
  "${SHARE_OP_REFS[i]}" \
  "${SHARE_KC_REFS[i]}"; then
```

**Step 7: Run shellcheck + full bats suite**

Run:

```bash
shellcheck -S info ~/Developer/scripts/smb-mount.sh
cd ~/Developer/scripts && bats tests/smb-mount.bats tests/ssh-wrapper.bats
```

Expected: all passing.

**Step 8: Smoke-run smb-mount.sh once interactively with vault unlocked**

Run:

```bash
op whoami && echo unlocked
~/.local/bin/smb-mount.sh
echo "exit=$?"
tail -8 ~/.local/state/com.asiago.mount-smb-shares.log
```

Expected: exit 0; log auth labels now read "(op+kc)" for the Synology share; "already mounted, skipping" since nothing's been unmounted.

**Step 9: Commit**

```bash
cd ~/Developer/scripts
git add smb-mount.sh
git commit -m "feat(smb-mount): add SHARE_KC_REFS and keychain fallback wiring"
```

---

## Task 7: User-side keychain seeding (one-time manual step)

**Files:** none in repo — this is a human action, documented for review.

**Step 1: Read the password from 1Password** (this WILL prompt TouchID — expected, one-time):

```bash
op read "op://Personal/Synology NAS - dsadmin/password"
```

Copy the value.

**Step 2: Store in login keychain with ACL**

Run (replace `<PASSWORD>`):

```bash
security add-generic-password \
  -s smb-synology-dsadmin \
  -a dsadmin \
  -w '<PASSWORD>' \
  -T /usr/bin/security \
  -T /sbin/mount_smbfs \
  -T "${HOME}/.local/bin/smb-mount.sh" \
  -U
```

**Step 3: Verify non-interactive readback**

Run:

```bash
security find-generic-password -s smb-synology-dsadmin -w
```

Expected: password prints; no GUI prompt.

**Step 4: No commit** (no repo changes).

---

## Task 8: End-to-end verification

**Files:** none modified — regression test.

**Step 1: Baseline — vault unlocked, shares mounted (no remount needed)**

Run:

```bash
op whoami && echo unlocked
~/.local/bin/smb-mount.sh
echo "exit=$?"
tail -8 ~/.local/state/com.asiago.mount-smb-shares.log
```

Expected: exit 0; log shows "already mounted, skipping" for both shares; no "op read" lines (fast path).

**Step 2: Force remount with vault UNLOCKED — sync path**

Run:

```bash
umount "${HOME}/Downloads/archives"
~/.local/bin/smb-mount.sh
echo "exit=$?"
tail -12 ~/.local/state/com.asiago.mount-smb-shares.log
```

Expected: exit 0; log shows "op read succeeded"; either "keychain updated from 1Password" (first run after seeding — op and kc are likely in sync so may not appear) or nothing; mount verified.

**Step 3: Force remount with vault LOCKED — keychain fallback, NO TouchID**

Lock 1Password desktop (menu → Lock). Verify silent:

```bash
op whoami 2>&1
echo "exit=$?"
```

Expected: `[ERROR] account is not signed in`; exit non-zero; NO TouchID prompt.

Then:

```bash
umount "${HOME}/Downloads/archives"
~/.local/bin/smb-mount.sh
echo "exit=$?"
tail -12 ~/.local/state/com.asiago.mount-smb-shares.log
```

**Watch the screen for a TouchID prompt — there must not be one.** Expected log:
"op unavailable or read failed; falling back to keychain" → "keychain read succeeded" → mount verified. Exit 0.

**Step 4: Simulate bad keychain — notification**

Corrupt the entry:

```bash
security add-generic-password -s smb-synology-dsadmin -a dsadmin -w "wrong-password" -U \
  -T /usr/bin/security -T /sbin/mount_smbfs -T "${HOME}/.local/bin/smb-mount.sh"
umount "${HOME}/Downloads/archives"
~/.local/bin/smb-mount.sh
echo "exit=$?"
```

Expected: exit non-zero; macOS notification banner "SMB mount auth error — Failed to mount //romano.local/…".

**Step 5: Restore correct entry**

Repeat Task 7 steps 1–2 to overwrite the test value with the real password.

**Step 6: Log-noise sanity check**

Run:

```bash
log show --predicate 'process == "op"' --start "$(date -v-10M '+%Y-%m-%d %H:%M:%S')" 2>/dev/null | grep -c "Retrieve User by ID"
```

Expected: small single-digit count (just the op whoami probes we ran in verification). Contrast with the overnight cadence which was ~60/hour for 7 hours.

**Step 7: No commit**.

---

## Task 9: Documentation updates

**Files:**

- Modify: `docs/plans/2026-04-16-smb-mount-rebuild-design.md` — append addendum
- Modify: `smb-mount.sh` — update top comment

**Step 1: Append addendum to the original design doc**

At the bottom of `~/Developer/scripts/docs/plans/2026-04-16-smb-mount-rebuild-design.md`, add:

```markdown
## 2026-04-24 addendum — keychain fallback

After initial rollout, overnight `op read` calls against a locked 1Password
vault queued TouchID prompts that piled up by morning (LaunchAgent with
`KeepAlive.SuccessfulExit=false` respawned every ~60 s on op-read timeouts).

Resolution: added a `SHARE_KC_REFS` parallel array and a `fetch_password`
helper that uses `op whoami` as a silent safety gate before `op read`,
falls back to the login keychain on any failure, and pushes updates
from 1Password back into the keychain whenever it finds them out of
sync. 1Password remains canonical; the keychain is a non-interactive
mirror.

See `docs/plans/2026-04-24-smb-mount-keychain-fallback.md` for the full plan.
```

**Step 2: Update `smb-mount.sh` top comment**

Change (top of file, ~lines 2-4):

```bash
# smb-mount.sh - Idempotent SMB auto-mount for ASIAGO workstation.
# Invoked by ~/Library/LaunchAgents/com.asiago.mount-smb-shares.plist.
# Design: docs/plans/2026-04-16-smb-mount-rebuild-design.md
```

to:

```bash
# smb-mount.sh - Idempotent SMB auto-mount for ASIAGO workstation.
# Invoked by ~/Library/LaunchAgents/com.asiago.mount-smb-shares.plist.
# Design: docs/plans/2026-04-16-smb-mount-rebuild-design.md
# Keychain fallback addendum: docs/plans/2026-04-24-smb-mount-keychain-fallback.md
#
# Credential sources (in priority order):
#   1. 1Password via `op read` — canonical; used when `op whoami` silent-succeeds.
#   2. macOS login keychain via `security find-generic-password` — fallback
#      when op is locked/unavailable (LaunchAgents have no TTY; biometric
#      prompts would stack indefinitely).
# 1Password values are synced into the keychain automatically on every
# successful `op read`.
```

**Step 3: Commit**

```bash
cd ~/Developer/scripts
git add docs/plans/2026-04-16-smb-mount-rebuild-design.md smb-mount.sh
git commit -m "docs(smb-mount): document keychain fallback and sync behavior"
```

---

## Task 10: Push and open PR

**Files:** none directly.

**Step 1: Confirm pre-commit hook logged clean**

Run:

```bash
head -6 $(git -C ~/Developer/scripts rev-parse --git-dir)/last-review-result.log
```

Expected: timestamp recent, branch matches our feature branch.

**Step 2: Full test suite one more time**

Run:

```bash
cd ~/Developer/scripts && bats tests/
```

Expected: all tests pass.

**Step 3: Push**

Run:

```bash
git -C ~/Developer/scripts push -u origin HEAD
```

**Step 4: Open PR**

Run:

```bash
gh pr create --repo smartwatermelon/scripts --title "fix(smb-mount): keychain fallback to prevent overnight TouchID prompts" \
  --body "$(cat <<'EOF'
## Summary

- Adds a silent `op whoami` gate before `op read` so the LaunchAgent never triggers a TouchID prompt overnight.
- Adds a `SHARE_KC_REFS` parallel array and a `fetch_password` helper that falls back to the macOS login keychain when 1Password is locked.
- 1Password stays canonical: whenever `op read` succeeds, the keychain is auto-updated if it drifted.
- Surfaces a macOS notification on actual SMB auth failures so stale keychain entries get noticed.

## Root cause

`com.asiago.mount-smb-shares` runs `smb-mount.sh` every 150 s with `KeepAlive.SuccessfulExit=false`. Overnight the Synology sleeps, the SMB mount drops, `smb-mount.sh` tries to remount, calls `op read`, the vault is locked, op blocks ~60 s waiting for TouchID, script exits non-zero, launchd respawns — cycle repeats every minute, queuing TouchID prompts that pile up until the user sits down.

## Test plan

- [x] 8 new bats tests pass (3 on `_op_whoami_ok`, 5 on `fetch_password` covering all branches)
- [x] `shellcheck -S info smb-mount.sh` clean
- [x] Verified manually: vault unlocked remount → op path + keychain sync
- [x] Verified manually: vault locked remount → keychain path, zero TouchID prompts
- [x] Verified manually: bad keychain entry → mount fails + macOS notification
- [x] No per-minute `op` invocations in `log show` after verification

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Step 5: Follow Protocol 5** — poll CI via `bash ~/.claude/scripts/post-push-status.sh <PR#>`, address any review findings, and wait for explicit "approved" before merging (Protocol 6).

---
