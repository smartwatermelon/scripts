#!/usr/bin/env bats
# bats tests for smb-mount.sh
#
# Run from repo root:  bats tests/smb-mount.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${SCRIPT_DIR}/smb-mount.sh"
  TMPDIR_T="$(mktemp -d)"
  # shellcheck source=../smb-mount.sh
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
  #   op whoami  → mode-controlled silent exit
  #   op read REF → mode-controlled value or error
  # Env:
  #   OP_WHOAMI_MODE: signed_in (default) | signed_out | vault_scoped
  #   OP_READ_MODE:   success (default)   | failure    | vault_scoped
  #   OP_READ_VALUE:  stdout on success (default "dummy-op-secret")
  # "vault_scoped" fails iff OP_SERVICE_ACCOUNT_TOKEN is set — models the
  # real production failure where a service-account token can't see
  # Personal. Mirrors the mode of the same name in tests/ssh-wrapper.bats.
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
      vault_scoped)
        if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
          printf 'URL: https://my.1password.com\nEmail: automation@example.com\n'
          exit 0
        fi
        printf 'URL: https://my.1password.com\nEmail: test@example.com\n'
        exit 0
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
      vault_scoped)
        if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
          printf "[ERROR] could not read secret '%s': \"Personal\" isn't a vault in this account.\n" "$2" >&2
          exit 1
        fi
        printf '%s\n' "${OP_READ_VALUE:-dummy-op-secret}"
        exit 0
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
        exit 44
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
    run --separate-stderr fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "kc-secret" ]]
}

@test "fetch_password: op signed-in + op+kc match → returns op value, no kc write" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  KC_WRITE_LOG="${TMPDIR_T}/kc-writes"
  : >"${KC_WRITE_LOG}"
  OP_WHOAMI_MODE=signed_in \
    OP_READ_MODE=success OP_READ_VALUE="same-secret" \
    KC_READ_MODE=hit KC_READ_VALUE="same-secret" \
    KC_WRITE_LOG="${KC_WRITE_LOG}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run --separate-stderr fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "same-secret" ]]
  [[ ! -s "${KC_WRITE_LOG}" ]]
}

@test "fetch_password: op signed-in + kc differs → returns op value, kc updated" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  KC_WRITE_LOG="${TMPDIR_T}/kc-writes"
  : >"${KC_WRITE_LOG}"
  OP_WHOAMI_MODE=signed_in \
    OP_READ_MODE=success OP_READ_VALUE="new-secret" \
    KC_READ_MODE=hit KC_READ_VALUE="old-secret" \
    KC_WRITE_LOG="${KC_WRITE_LOG}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run --separate-stderr fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "new-secret" ]]
  grep -q "smb-synology-dsadmin" "${KC_WRITE_LOG}"
  grep -q "new-secret" "${KC_WRITE_LOG}"
}

@test "fetch_password: op signed-out + kc miss → fails with notification" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  OSASCRIPT_LOG="${TMPDIR_T}/osascript-log"
  : >"${OSASCRIPT_LOG}"
  # Override notification state paths to tmpdir so this test does not
  # pollute ~/.local/state/ on the real filesystem.
  OP_WHOAMI_MODE=signed_out \
    KC_READ_MODE=miss \
    ALERT_FILE="${TMPDIR_T}/alert.txt" \
    BANNER_COOLDOWN_FILE="${TMPDIR_T}/banner.ts" \
    OSASCRIPT_LOG="${OSASCRIPT_LOG}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run --separate-stderr fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -ne 0 ]]
  grep -q "SMB password lookup failed" "${OSASCRIPT_LOG}"
}

@test "fetch_password: OP_SERVICE_ACCOUNT_TOKEN set in env → fetch_password still uses personal session" {
  # Regression test: even when the caller's environment has a service-
  # account token (which would normally make `op read` fail for items
  # in Personal), fetch_password must unset the token inside its
  # subshells so whoami and read use the user's personal session.
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  OP_SERVICE_ACCOUNT_TOKEN="dummy-svc-token" \
    OP_WHOAMI_MODE=vault_scoped \
    OP_READ_MODE=vault_scoped OP_READ_VALUE="personal-pw" \
    KC_READ_MODE=hit KC_READ_VALUE="personal-pw" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run --separate-stderr fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "personal-pw" ]]
}

@test "_notify_user: banner rate-limited to once per cooldown" {
  _setup_fake_osascript
  local osalog="${TMPDIR_T}/osa.log"
  local sentinel="${TMPDIR_T}/alert.txt"
  local cooldown="${TMPDIR_T}/banner.ts"

  # First call: no cooldown file exists → banner fires.
  ALERT_FILE="${sentinel}" \
    BANNER_COOLDOWN_FILE="${cooldown}" \
    BANNER_COOLDOWN_SECONDS=1800 \
    OSASCRIPT_LOG="${osalog}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    _notify_user "first" "first msg"
  [[ -s "${osalog}" ]]
  [[ -f "${cooldown}" ]]
  [[ -s "${sentinel}" ]]

  # Second call inside cooldown window → banner suppressed.
  : >"${osalog}"
  ALERT_FILE="${sentinel}" \
    BANNER_COOLDOWN_FILE="${cooldown}" \
    BANNER_COOLDOWN_SECONDS=1800 \
    OSASCRIPT_LOG="${osalog}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    _notify_user "second" "second msg"
  [[ ! -s "${osalog}" ]]         # banner suppressed
  grep -q "second" "${sentinel}" # sentinel still updated
}

@test "_notify_user: banner fires again after cooldown expires" {
  _setup_fake_osascript
  local osalog="${TMPDIR_T}/osa.log"
  local sentinel="${TMPDIR_T}/alert.txt"
  local cooldown="${TMPDIR_T}/banner.ts"

  # Seed a stale cooldown file (mtime in the past).
  touch -t 202001010000.00 "${cooldown}"

  ALERT_FILE="${sentinel}" \
    BANNER_COOLDOWN_FILE="${cooldown}" \
    BANNER_COOLDOWN_SECONDS=1800 \
    OSASCRIPT_LOG="${osalog}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    _notify_user "refire" "refire msg"
  [[ -s "${osalog}" ]] # banner fired because cooldown expired
}

@test "fetch_password: op signed-in but read fails → falls back to kc" {
  _setup_fake_op
  _setup_fake_security
  _setup_fake_osascript
  OP_WHOAMI_MODE=signed_in \
    OP_READ_MODE=failure \
    KC_READ_MODE=hit KC_READ_VALUE="kc-fallback" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run --separate-stderr fetch_password "dsadmin" "op://Personal/Synology NAS - dsadmin/password" "smb-synology-dsadmin"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "kc-fallback" ]]
}
