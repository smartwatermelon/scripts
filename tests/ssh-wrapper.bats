#!/usr/bin/env bats
# bats tests for ssh-wrapper (the `ssh` script in the repo root)
#
# Run from repo root:  bats tests/ssh-wrapper.bats

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  WRAPPER="${SCRIPT_DIR}/ssh"
  FIXTURES="${SCRIPT_DIR}/tests/fixtures"
  TMPDIR_T="$(mktemp -d)"
  # Sandbox the ControlMaster socket dir for EVERY test so no test can
  # create, probe, or delete a socket in the real ~/.ssh/cm. mktemp -d
  # paths are short enough to stay under the ~104-byte sun_path cap.
  export SSH_WRAPPER_CM_DIR="${TMPDIR_T}/cm"
  # Source the wrapper for unit tests (the wrapper's linear body is guarded,
  # so sourcing only loads function definitions).
  # shellcheck source=../ssh
  source "${WRAPPER}"
}

teardown() {
  rm -rf "${TMPDIR_T}"
}

# ─────────────────────────────────────────────────────────────────────────
# _extract_host
# ─────────────────────────────────────────────────────────────────────────

@test "_extract_host: bare hostname" {
  result="$(_extract_host mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: strips user@" {
  result="$(_extract_host user@mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: lowercases" {
  result="$(_extract_host user@MIMOLETTE)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: consuming flag with separate value" {
  result="$(_extract_host -p 2222 mimolette ls)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: consuming flag with bundled value" {
  result="$(_extract_host -p2222 mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: -L with colon-separated arg" {
  result="$(_extract_host -L 8080:localhost:80 mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: -- terminator" {
  result="$(_extract_host -- mimolette --help)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: mixed flags with lowercasing" {
  result="$(_extract_host -i ~/.ssh/foo -J bastion user@MIMOLETTE cmd)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: -v (non-consuming) before host" {
  result="$(_extract_host -v mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: no destination returns empty" {
  result="$(_extract_host -v)"
  [[ -z "${result}" ]]
}

@test "_extract_host: no args returns empty" {
  result="$(_extract_host)"
  [[ -z "${result}" ]]
}

@test "_extract_host: -o with separate value" {
  result="$(_extract_host -o StrictHostKeyChecking=no mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: -oFoo=bar bundled" {
  result="$(_extract_host -oStrictHostKeyChecking=no mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: does not consume arg after non-consuming flag" {
  # -4 is non-consuming; next token is destination
  result="$(_extract_host -4 mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: -- separator with plain remote command" {
  result="$(_extract_host -- mimolette echo hi)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: -J jump target consumed, destination extracted" {
  result="$(_extract_host -J jumphost mimolette)"
  [[ "${result}" == "mimolette" ]]
}

@test "_extract_host: user@HOST with remote command" {
  result="$(_extract_host user@MIMOLETTE echo hi)"
  [[ "${result}" == "mimolette" ]]
}

# ─────────────────────────────────────────────────────────────────────────
# _strip_quotes
# ─────────────────────────────────────────────────────────────────────────

@test "_strip_quotes: double-quoted" {
  result="$(_strip_quotes '"op://foo"')"
  [[ "${result}" == "op://foo" ]]
}

@test "_strip_quotes: single-quoted" {
  result="$(_strip_quotes "'op://foo'")"
  [[ "${result}" == "op://foo" ]]
}

@test "_strip_quotes: unquoted passes through" {
  result="$(_strip_quotes "op://foo")"
  [[ "${result}" == "op://foo" ]]
}

@test "_strip_quotes: unmatched leading quote unchanged" {
  result="$(_strip_quotes '"op://foo')"
  [[ "${result}" == '"op://foo' ]]
}

@test "_strip_quotes: unmatched trailing quote unchanged" {
  result="$(_strip_quotes 'op://foo"')"
  [[ "${result}" == 'op://foo"' ]]
}

@test "_strip_quotes: empty string" {
  result="$(_strip_quotes "")"
  [[ -z "${result}" ]]
}

# ─────────────────────────────────────────────────────────────────────────
# _glob_match / _rank_pattern
# ─────────────────────────────────────────────────────────────────────────

@test "_glob_match: bare star matches anything" {
  _glob_match '*' 'anything'
  _glob_match '*' ''
}

@test "_glob_match: literal matches exactly" {
  _glob_match 'mimolette' 'mimolette'
  run ! _glob_match 'mimolette' 'mimo'
  run ! _glob_match 'mimo' 'mimolette'
}

@test "_glob_match: star mid-pattern" {
  _glob_match '*.internal' 'web.internal'
  run ! _glob_match '*.internal' 'external'
}

@test "_glob_match: question mark single char" {
  _glob_match 'ho?t' 'host'
  run ! _glob_match 'ho?t' 'hooost'
}

@test "_glob_match: negation treated literally (not supported)" {
  # Spec: !foo is not supported; treat as literal
  _glob_match '!foo' '!foo'
  run ! _glob_match '!foo' 'foo'
}

@test "_rank_pattern: bare star is 0" {
  result="$(_rank_pattern '*')"
  [[ "${result}" == "0" ]]
}

@test "_rank_pattern: contains glob metachar is 1" {
  r1="$(_rank_pattern '*.internal')"
  r2="$(_rank_pattern 'ho?t')"
  r3="$(_rank_pattern 'foo*bar')"
  [[ "${r1}" == "1" ]]
  [[ "${r2}" == "1" ]]
  [[ "${r3}" == "1" ]]
}

@test "_rank_pattern: literal is 2" {
  result="$(_rank_pattern 'mimolette')"
  [[ "${result}" == "2" ]]
}

# ─────────────────────────────────────────────────────────────────────────
# _resolve_annotations (end-to-end config parsing via fixtures)
# ─────────────────────────────────────────────────────────────────────────

@test "_resolve_annotations: basic match returns one tuple" {
  # Expect: OP_SERVICE_ACCOUNT_TOKEN<TAB>op://Personal/mimolette/credential
  run _resolve_annotations mimolette "${FIXTURES}/config-basic"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == $'OP_SERVICE_ACCOUNT_TOKEN\top://Personal/mimolette/credential' ]]
}

@test "_resolve_annotations: unannotated host returns empty" {
  run _resolve_annotations unannotated "${FIXTURES}/config-basic"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "_resolve_annotations: unknown host returns empty" {
  run _resolve_annotations not-in-config "${FIXTURES}/config-basic"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "_resolve_annotations: specificity - exact wins over glob" {
  # target mimolette matches Host *, Host mimolette asiago
  # BAR: Host *=op://shared/bar (rank 0), Host mimolette=op://specific/bar (rank 2)
  # expected: BAR -> op://specific/bar
  output="$(_resolve_annotations mimolette "${FIXTURES}/config-specificity")"
  [[ "${output}" == *$'BAR\top://specific/bar'* ]]
  [[ "${output}" != *'op://shared/bar'* ]]
}

@test "_resolve_annotations: specificity - glob wins over bare star" {
  # target web.internal: Host *=rank 0, Host *.internal=rank 1
  # FOO: bare * -> shared, *.internal -> internal; expected internal wins
  output="$(_resolve_annotations web.internal "${FIXTURES}/config-specificity")"
  [[ "${output}" == *$'FOO\top://internal/foo'* ]]
  [[ "${output}" != *'op://shared/foo'* ]]
}

@test "_resolve_annotations: multi-name Host - both names resolve identically" {
  # mimolette and asiago both on the same Host line; both should see BAR specific
  out1="$(_resolve_annotations mimolette "${FIXTURES}/config-specificity")"
  out2="$(_resolve_annotations asiago "${FIXTURES}/config-specificity")"
  # Strip host-specific FOO from output (different per host because of * match only)
  # All vars should match between these two (they're on the same Host line).
  [[ "${out1}" == "${out2}" ]]
}

@test "_resolve_annotations: quoted value stripped" {
  output="$(_resolve_annotations mimolette "${FIXTURES}/config-specificity")"
  [[ "${output}" == *$'QUOTED\top://quoted/value'* ]]
}

@test "_resolve_annotations: unquoted value preserved" {
  output="$(_resolve_annotations mimolette "${FIXTURES}/config-specificity")"
  [[ "${output}" == *$'UNQUOTED\top://unquoted/value'* ]]
}

@test "_resolve_annotations: trailing whitespace right-trimmed" {
  # Build a fixture with literal trailing whitespace on the annotation line
  fixture="${TMPDIR_T}/config-trailing"
  printf 'Host trailinghost\n  # op: TRAIL=op://trailing/value   \n' >"${fixture}"
  output="$(_resolve_annotations trailinghost "${fixture}")"
  [[ "${output}" == $'TRAIL\top://trailing/value' ]]
}

@test "_resolve_annotations: last-wins at equal specificity" {
  # Two Host duplicate blocks with different DUP values; last one should win.
  output="$(_resolve_annotations duplicate "${FIXTURES}/config-specificity")"
  [[ "${output}" == *$'DUP\top://second/value'* ]]
  [[ "${output}" != *'op://first/value'* ]]
}

@test "_resolve_annotations: missing config file returns empty" {
  run _resolve_annotations mimolette "${TMPDIR_T}/does-not-exist"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "_resolve_annotations: Match keyword terminates preceding Host block" {
  # UNSAFE is inside a `Match user root` block. The wrapper does not implement
  # Match semantics, so it must NOT attribute UNSAFE to the preceding Host
  # mimolette block (which would silently inject the wrong secret).
  output="$(_resolve_annotations mimolette "${FIXTURES}/config-match")"
  [[ "${output}" == *$'SAFE\top://mimolette/token'* ]]
  [[ "${output}" != *'UNSAFE'* ]]
  [[ "${output}" != *'should-never-inject'* ]]
}

@test "_resolve_annotations: case-insensitive host matching" {
  # Pattern 'mimolette' (lowercase) should match target 'MIMOLETTE' after lowercasing
  # Our contract: caller lowercases target; resolver should lowercase pattern too.
  output="$(_resolve_annotations mimolette "${FIXTURES}/config-specificity")"
  [[ "${output}" == *'op://specific/bar'* ]]
}

@test "_resolve_annotations: negation excludes specified host from wildcard block" {
  # 'Host * !secret-host': secret-host must NOT receive SHARED from the wildcard block.
  output="$(_resolve_annotations secret-host "${FIXTURES}/config-negation")"
  [[ "${output}" != *'SHARED'* ]]
  [[ "${output}" == *$'SECRET\top://secrets/only'* ]]
}

@test "_resolve_annotations: negation does not exclude non-negated hosts" {
  # 'Host * !secret-host': other hosts still match via the * pattern.
  output="$(_resolve_annotations other-host "${FIXTURES}/config-negation")"
  [[ "${output}" == *$'SHARED\top://shared/token'* ]]
  [[ "${output}" != *'SECRET'* ]]
}

# ─────────────────────────────────────────────────────────────────────────
# _resolve_keychain_annotation
# ─────────────────────────────────────────────────────────────────────────

@test "_resolve_keychain_annotation: exact match wins over glob" {
  run _resolve_keychain_annotation mimolette "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://specific/keychain/password" ]]
}

@test "_resolve_keychain_annotation: glob wins over bare star" {
  run _resolve_keychain_annotation web.internal "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://internal/keychain/password" ]]
}

@test "_resolve_keychain_annotation: multi-name Host - both names resolve identically" {
  out1="$(_resolve_keychain_annotation mimolette "${FIXTURES}/config-keychain")"
  out2="$(_resolve_keychain_annotation asiago "${FIXTURES}/config-keychain")"
  [[ "${out1}" == "${out2}" ]]
  [[ "${out1}" == "op://specific/keychain/password" ]]
}

@test "_resolve_keychain_annotation: last-wins at equal specificity" {
  run _resolve_keychain_annotation duplicate "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://second/value" ]]
}

@test "_resolve_keychain_annotation: quoted value stripped" {
  run _resolve_keychain_annotation quoted "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://quoted/keychain/password" ]]
}

@test "_resolve_keychain_annotation: trailing whitespace right-trimmed" {
  fixture="${TMPDIR_T}/config-trailing-kc"
  printf 'Host trailhost\n  # op-keychain: op://trailing/password   \n' >"${fixture}"
  run _resolve_keychain_annotation trailhost "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://trailing/password" ]]
}

@test "_resolve_keychain_annotation: literal with no matching exact block falls through to Host *" {
  run _resolve_keychain_annotation unannotated "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  # `unannotated` is a literal that matches only Host * (rank 0), so the
  # shared keychain ref on Host * applies.
  [[ "${output}" == "op://shared/keychain/password" ]]
}

@test "_resolve_keychain_annotation: exact block with only # op: falls through to Host * for keychain ref" {
  # `onlytoken` matches both Host * (rank 0, has op-keychain) and Host
  # onlytoken (rank 2, has only # op: — no # op-keychain). Since the
  # rank-2 block contributes no keychain ref, the rank-0 Host * ref wins.
  run _resolve_keychain_annotation onlytoken "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://shared/keychain/password" ]]
}

@test "_resolve_keychain_annotation: host with both # op: and # op-keychain resolves keychain correctly" {
  run _resolve_keychain_annotation mixed "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://mixed/keychain/password" ]]
}

@test "_resolve_keychain_annotation: missing config returns empty" {
  run _resolve_keychain_annotation mimolette "${TMPDIR_T}/does-not-exist"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "_resolve_keychain_annotation: empty target returns empty" {
  run _resolve_keychain_annotation "" "${FIXTURES}/config-keychain"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "_resolve_keychain_annotation: Match block terminates preceding Host" {
  fixture="${TMPDIR_T}/config-match-kc"
  cat >"${fixture}" <<'EOF'
Host mimolette
  # op-keychain: op://mimolette/safe

Match user root
  # op-keychain: op://never/inject
EOF
  run _resolve_keychain_annotation mimolette "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "op://mimolette/safe" ]]
  [[ "${output}" != *"never/inject"* ]]
}

@test "_resolve_keychain_annotation: does not confuse # op: for # op-keychain" {
  fixture="${TMPDIR_T}/config-noconfuse"
  cat >"${fixture}" <<'EOF'
Host onlyop
  # op: VAR=op://should/not/match
EOF
  run _resolve_keychain_annotation onlyop "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "_resolve_keychain_annotation: does not confuse # op-keychain for # op:" {
  # Confirm the keychain annotation doesn't leak into # op: resolution.
  fixture="${TMPDIR_T}/config-noconfuse2"
  cat >"${fixture}" <<'EOF'
Host onlykc
  # op-keychain: op://keychain/only
EOF
  run _resolve_annotations onlykc "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

# ─────────────────────────────────────────────────────────────────────────
# _argv_has_dash_oh
# ─────────────────────────────────────────────────────────────────────────

@test "_argv_has_dash_oh: returns 1 on empty argv" {
  run ! _argv_has_dash_oh
}

@test "_argv_has_dash_oh: returns 1 for no -O" {
  run ! _argv_has_dash_oh -v mimolette echo hi
}

@test "_argv_has_dash_oh: returns 0 on standalone -O stop" {
  _argv_has_dash_oh -O stop mimolette
}

@test "_argv_has_dash_oh: returns 0 on -O check at any position" {
  _argv_has_dash_oh mimolette -O check
}

@test "_argv_has_dash_oh: returns 0 on -O exit with other flags" {
  _argv_has_dash_oh -v -O exit mimolette
}

@test "_argv_has_dash_oh: does NOT match lowercase -o" {
  run ! _argv_has_dash_oh -o StrictHostKeyChecking=no mimolette
}

@test "_argv_has_dash_oh: does NOT match -oFoo=bar bundled" {
  run ! _argv_has_dash_oh -oStrictHostKeyChecking=no mimolette
}

@test "_argv_has_dash_oh: does NOT match -O after --" {
  run ! _argv_has_dash_oh -- mimolette -O check
}

# ─────────────────────────────────────────────────────────────────────────
# _find_real_ssh
# ─────────────────────────────────────────────────────────────────────────

@test "_find_real_ssh: skips self and finds alternative" {
  mkdir -p "${TMPDIR_T}/wrap" "${TMPDIR_T}/real"
  ln -sf "${WRAPPER}" "${TMPDIR_T}/wrap/ssh"
  cat >"${TMPDIR_T}/real/ssh" <<'EOF'
#!/usr/bin/env bash
echo "fake-ssh called with: $*"
EOF
  chmod +x "${TMPDIR_T}/real/ssh"
  local wrap_canon real_canon
  wrap_canon="$(realpath "${TMPDIR_T}/wrap/ssh")"
  real_canon="$(realpath "${TMPDIR_T}/real/ssh")"
  # Command substitution creates a subshell, scoping PATH/SELF_PATH overrides
  # to the _find_real_ssh invocation only; outer PATH is preserved for teardown.
  local out rc
  out="$(PATH="${TMPDIR_T}/wrap:${TMPDIR_T}/real:/usr/bin:/bin" \
    SELF_PATH="${wrap_canon}" _find_real_ssh 2>&1)"
  rc=$?
  [[ "${rc}" -eq 0 ]]
  local out_canon
  out_canon="$(realpath "${out}")"
  [[ "${out_canon}" == "${real_canon}" ]]
}

@test "_find_real_ssh: no candidates errors" {
  mkdir -p "${TMPDIR_T}/only-self"
  ln -sf "${WRAPPER}" "${TMPDIR_T}/only-self/ssh"
  local only_canon
  only_canon="$(realpath "${TMPDIR_T}/only-self/ssh")"
  # PATH must contain a dir with realpath (so canonicalization inside
  # _find_real_ssh works) but NO dir containing a real `ssh` other than the
  # self-symlink.
  #
  # Do not use /bin here. That worked only on macOS, where /bin has realpath
  # and no ssh; on Linux /bin usually does contain ssh, so _find_real_ssh
  # finds one and the test silently stops testing what it claims. Build a
  # directory holding realpath and nothing else instead.
  mkdir -p "${TMPDIR_T}/only-realpath"
  local realpath_bin
  realpath_bin="$(command -v realpath)" || true
  # Without this guard an absent realpath yields an empty string, `ln -sf ""`
  # quietly creates a dangling symlink, and _find_real_ssh then errors for the
  # wrong reason -- the test still passes while testing nothing.
  [[ -n "${realpath_bin}" ]] || skip "realpath not available on this runner"
  ln -sf "${realpath_bin}" "${TMPDIR_T}/only-realpath/realpath"
  local out rc
  out="$(PATH="${TMPDIR_T}/only-self:${TMPDIR_T}/only-realpath" \
    SELF_PATH="${only_canon}" \
    SSH_WRAPPER_SKIP_FALLBACKS=1 _find_real_ssh 2>&1)" && rc=0 || rc=$?
  [[ "${rc}" -ne 0 ]]
  [[ "${out}" == *"Could not find real ssh"* ]]
}

# ─────────────────────────────────────────────────────────────────────────
# _fetch_op
# ─────────────────────────────────────────────────────────────────────────

# Backdates a path's mtime by N seconds, portably.
#
# `date -v-2M` is BSD-only and `date -d '2 min ago'` is GNU-only, so the
# suite would pass on macOS and fail on the Linux CI runner (or vice
# versa). perl's utime is present on both and takes a plain epoch offset.
_backdate() {
  local path="$1" secs="$2"
  perl -e 'my $t = time - $ARGV[1]; utime($t, $t, $ARGV[0]) or die "utime failed: $!";' \
    "${path}" "${secs}"
}

_setup_fake_op() {
  # Creates $TMPDIR_T/bin/op that behaves per mode env var OP_FAKE_MODE
  mkdir -p "${TMPDIR_T}/bin"
  cat >"${TMPDIR_T}/bin/op" <<'EOF'
#!/usr/bin/env bash
# Fake op for tests. Modes:
#   success        — prints OP_FAKE_VALUE to stdout, exit 0
#   expired        — prints "[ERROR] ... not currently signed in ..." to stderr, exit 1
#   failure        — prints "[ERROR] some other error" to stderr, exit 1
#   vault_scoped   — fail with "isn't a vault in this account" iff
#                    OP_SERVICE_ACCOUNT_TOKEN is set; otherwise behave
#                    like success. Models the real production failure
#                    where a service-account token can't see Personal.
#
# Every invocation appends a line to $OP_FAKE_CALL_LOG when that variable
# is set, so tests can assert that a cached master triggers NO op read at
# all (an op read is exactly what raises the 1Password modal).
if [[ -n "${OP_FAKE_CALL_LOG:-}" ]]; then
  printf 'OP_CALL: %s\n' "$*" >>"${OP_FAKE_CALL_LOG}"
fi
case "${OP_FAKE_MODE:-success}" in
  success)
    printf '%s\n' "${OP_FAKE_VALUE:-dummy-token-value}"
    ;;
  expired)
    printf '[ERROR] You are not currently signed in. Please run `op signin` first.\n' >&2
    exit 1
    ;;
  failure)
    printf '[ERROR] reference not found: %s\n' "$*" >&2
    exit 1
    ;;
  vault_scoped)
    if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
      printf "[ERROR] could not read secret '%s': \"Personal\" isn't a vault in this account.\n" "$*" >&2
      exit 1
    fi
    printf '%s\n' "${OP_FAKE_VALUE:-dummy-token-value}"
    ;;
esac
EOF
  chmod +x "${TMPDIR_T}/bin/op"
}

@test "_fetch_op: happy path returns value without trailing newline" {
  _setup_fake_op
  OP_FAKE_MODE=success OP_FAKE_VALUE="hello-world" PATH="${TMPDIR_T}/bin:${PATH}" \
    run _fetch_op "op://any/ref" "OP_VAR"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "hello-world" ]]
}

@test "_fetch_op: missing op binary errors with install hint" {
  mkdir -p "${TMPDIR_T}/empty"
  # PATH contains /usr/bin (for realpath etc.) but not any dir that holds `op`.
  PATH="${TMPDIR_T}/empty:/usr/bin:/bin" run _fetch_op "op://any/ref" "OP_VAR"
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"op CLI not installed"* ]]
  [[ "${output}" == *"OP_VAR"* ]]
}

@test "_fetch_op: session expired produces signin hint" {
  _setup_fake_op
  OP_FAKE_MODE=expired PATH="${TMPDIR_T}/bin:${PATH}" \
    run _fetch_op "op://any/ref" "OP_VAR"
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"op session expired"* || "${output}" == *"op signin"* ]]
}

@test "_fetch_op: other failure surfaces stderr" {
  _setup_fake_op
  OP_FAKE_MODE=failure PATH="${TMPDIR_T}/bin:${PATH}" \
    run _fetch_op "op://any/ref" "OP_VAR"
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"op read failed for OP_VAR"* ]]
  [[ "${output}" == *"op://any/ref"* ]]
}

# ─────────────────────────────────────────────────────────────────────────
# Integration smoke tests — end-to-end: real wrapper invocation
# ─────────────────────────────────────────────────────────────────────────

@test "integration: annotated host gets env injected and args forwarded" {
  _setup_fake_op
  # recorder-ssh writes its env and argv to a known path, then exits
  recorder="${TMPDIR_T}/recorder-ssh"
  cat >"${recorder}" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:'
for a in "$@"; do printf ' <%s>' "${a}"; done
printf '\n'
printf 'ENV_OP_SERVICE_ACCOUNT_TOKEN=%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-UNSET}"
EOF
  chmod +x "${recorder}"

  unset OP_SERVICE_ACCOUNT_TOKEN
  OP_FAKE_MODE=success OP_FAKE_VALUE="injected-token-XYZ" \
    SSH_CONFIG_PATH="${FIXTURES}/config-basic" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette echo hi

  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"ARGS: <mimolette> <echo> <hi>"* ]]
  [[ "${output}" == *"ENV_OP_SERVICE_ACCOUNT_TOKEN=injected-token-XYZ"* ]]
}

@test "integration: unannotated host passes through with no env injection" {
  _setup_fake_op
  recorder="${TMPDIR_T}/recorder-ssh"
  cat >"${recorder}" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:'
for a in "$@"; do printf ' <%s>' "${a}"; done
printf '\n'
printf 'ENV_OP_SERVICE_ACCOUNT_TOKEN=%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-UNSET}"
EOF
  chmod +x "${recorder}"

  # Unset to ensure unset-ness is observable (bats `run` is a shell function,
  # can't be prefixed with `env`, so use `unset`).
  unset OP_SERVICE_ACCOUNT_TOKEN
  OP_FAKE_MODE=success \
    SSH_CONFIG_PATH="${FIXTURES}/config-basic" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" unannotated echo hi

  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"ARGS: <unannotated> <echo> <hi>"* ]]
  [[ "${output}" == *"ENV_OP_SERVICE_ACCOUNT_TOKEN=UNSET"* ]]
}

@test "integration: pre-set OP_SERVICE_ACCOUNT_TOKEN is preserved, no op fetch" {
  _setup_fake_op
  recorder="${TMPDIR_T}/recorder-ssh"
  cat >"${recorder}" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:'
for a in "$@"; do printf ' <%s>' "${a}"; done
printf '\n'
printf 'ENV_OP_SERVICE_ACCOUNT_TOKEN=%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-UNSET}"
EOF
  chmod +x "${recorder}"

  # OP_FAKE_MODE=failure proves fetch was NOT attempted: if the wrapper
  # called op, it would error and abort before exec'ing the recorder.
  export OP_SERVICE_ACCOUNT_TOKEN="already-set-value"
  OP_FAKE_MODE=failure \
    SSH_CONFIG_PATH="${FIXTURES}/config-basic" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette echo hi
  unset OP_SERVICE_ACCOUNT_TOKEN

  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"ARGS: <mimolette> <echo> <hi>"* ]]
  [[ "${output}" == *"ENV_OP_SERVICE_ACCOUNT_TOKEN=already-set-value"* ]]
}

@test "integration: empty OP_SERVICE_ACCOUNT_TOKEN is treated as unset and fetched" {
  _setup_fake_op
  recorder="${TMPDIR_T}/recorder-ssh"
  cat >"${recorder}" <<'EOF'
#!/usr/bin/env bash
printf 'ENV_OP_SERVICE_ACCOUNT_TOKEN=%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-UNSET}"
EOF
  chmod +x "${recorder}"

  export OP_SERVICE_ACCOUNT_TOKEN=""
  OP_FAKE_MODE=success OP_FAKE_VALUE="freshly-fetched" \
    SSH_CONFIG_PATH="${FIXTURES}/config-basic" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette echo hi
  unset OP_SERVICE_ACCOUNT_TOKEN

  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"ENV_OP_SERVICE_ACCOUNT_TOKEN=freshly-fetched"* ]]
}

@test "integration: missing op ref aborts, does not exec ssh" {
  _setup_fake_op
  recorder="${TMPDIR_T}/recorder-ssh"
  cat >"${recorder}" <<'EOF'
#!/usr/bin/env bash
echo "RECORDER-SHOULD-NOT-RUN"
EOF
  chmod +x "${recorder}"

  unset OP_SERVICE_ACCOUNT_TOKEN
  OP_FAKE_MODE=failure \
    SSH_CONFIG_PATH="${FIXTURES}/config-basic" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette echo hi

  [[ "${status}" -ne 0 ]]
  [[ "${output}" != *"RECORDER-SHOULD-NOT-RUN"* ]]
  [[ "${output}" == *"op read failed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────
# Integration: # op-keychain dance dispatch
# ─────────────────────────────────────────────────────────────────────────

# Keychain-aware recorder: records every invocation (argv + stdin) to a
# log file. Returns 0 by default. Set RECORDER_FAIL_ON_MASTER=1 to make
# the -fNM master-open invocation exit non-zero.
#
# `-O check` (the wrapper's live-master probe) exits NON-ZERO by default,
# modelling "no master running yet" so the full dance runs. Set
# RECORDER_MASTER_ALIVE=1 to model an already-live master; the wrapper
# should then reuse it and skip both `op read` and `-fNM`.
_setup_kc_recorder() {
  recorder="${TMPDIR_T}/kc-recorder-ssh"
  log="${TMPDIR_T}/kc-recorder.log"
  cat >"${recorder}" <<EOF
#!/usr/bin/env bash
log="${log}"
{
  printf 'CALL_ARGS:'
  for a in "\$@"; do printf ' <%s>' "\${a}"; done
  printf '\n'
  # If stdin has data, capture it (best-effort; ssh is backgrounded
  # with -fNM so stdin may be empty).
  if [[ -p /dev/stdin || ! -t 0 ]]; then
    data="\$(cat 2>/dev/null || true)"
    if [[ -n "\${data}" ]]; then
      printf 'STDIN_BEGIN\n%s\nSTDIN_END\n' "\${data}"
    fi
  fi
  printf 'CALL_END\n'
} >>"\${log}"
# Model \`ssh -O check\`: report a live master only when asked to.
for a in "\$@"; do
  if [[ "\${a}" == "-O" ]]; then
    for b in "\$@"; do
      if [[ "\${b}" == "check" ]]; then
        [[ "\${RECORDER_MASTER_ALIVE:-0}" == "1" ]] && exit 0
        exit 255
      fi
    done
  fi
done
# Master-open failure injection for testing fallback.
for a in "\$@"; do
  if [[ "\${a}" == "-fNM" ]] && [[ "\${RECORDER_FAIL_ON_MASTER:-0}" == "1" ]]; then
    exit 255
  fi
done
exit 0
EOF
  chmod +x "${recorder}"
  : >"${log}"
}

# Builds a minimal ssh_config fixture in $TMPDIR_T for keychain tests.
_setup_kc_config() {
  kc_config="${TMPDIR_T}/kc-config"
  cat >"${kc_config}" <<'EOF'
Host mimolette.local
    # op-keychain: op://Personal/MIMOLETTE/password

Host plain.local
    HostName plain.local
EOF
}

@test "integration (keychain): annotated host fires full dance sequence" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success OP_FAKE_VALUE="secret-keychain-pw" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  log_contents="$(<"${log}")"
  # Master-open with -fNM. ControlPersist is long-lived (4h default) so the
  # master survives between connects; a 60s window expired before the next
  # invocation could reuse it, which caused a modal per connect.
  [[ "${log_contents}" == *"<-fNM>"* ]]
  [[ "${log_contents}" == *"<ControlPersist=4h>"* ]]
  # Pipe-unlock invocation runs `exec security -i` on remote.
  [[ "${log_contents}" == *"<exec security -i>"* ]]
  # Pipe-unlock stdin should contain unlock-keychain with the fake password.
  # Command targets the remote's default keychain (no explicit name).
  [[ "${log_contents}" == *$'unlock-keychain -p secret-keychain-pw\n'* ]]
  [[ "${log_contents}" != *"unlock-keychain -p secret-keychain-pw login"* ]]
  # Final exec should use ControlPath.
  [[ "${log_contents}" == *"<ControlPath="*".sock>"* ]]
}

@test "integration (keychain): -O present skips dance entirely" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success OP_FAKE_VALUE="secret-keychain-pw" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" -O stop mimolette.local

  [[ "${status}" -eq 0 ]]
  log_contents="$(<"${log}")"
  # Only one invocation: the passthrough. No -fNM, no security -i.
  [[ "${log_contents}" != *"<-fNM>"* ]]
  [[ "${log_contents}" != *"<exec security -i>"* ]]
  [[ "${log_contents}" != *"unlock-keychain"* ]]
  # The -O stop argv should have been forwarded verbatim.
  [[ "${log_contents}" == *"<-O> <stop> <mimolette.local>"* ]]
}

@test "integration (keychain): op read failure falls through to plain exec" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=failure \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"keychain-unlock: op read failed"* ]]
  log_contents="$(<"${log}")"
  # No dance stages; just the plain exec passthrough. The live-master probe
  # (`-O check`) does run first and legitimately carries a ControlPath, so
  # assert on the FINAL call rather than the whole log.
  [[ "${log_contents}" != *"<-fNM>"* ]]
  [[ "${log_contents}" != *"<exec security -i>"* ]]
  final_call="$(grep '^CALL_ARGS:' "${log}" | tail -1)"
  [[ "${final_call}" != *"<ControlPath="* ]]
  [[ "${final_call}" == *"<mimolette.local>"* ]]
}

@test "integration (keychain): master-open failure falls through to plain exec" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    RECORDER_FAIL_ON_MASTER=1 \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"ControlMaster open failed"* ]]
  log_contents="$(<"${log}")"
  # Master-open was attempted (and failed), but pipe-unlock must not have run.
  [[ "${log_contents}" == *"<-fNM>"* ]]
  [[ "${log_contents}" != *"<exec security -i>"* ]]
  # Expected sequence after master failure:
  #   1. -O check probe          (no live master yet -> 255, so dance runs)
  #   2. -O check re-probe       (after acquiring the creation lock, in case
  #                               a racing wrapper brought a master up in
  #                               between -- the concurrency guard)
  #   3. -fNM master-open        (exits 255 per RECORDER_FAIL_ON_MASTER)
  #   4. -O exit cleanup         (harmless no-op in production: ssh -O exit
  #                               on a non-existent socket fails silently
  #                               and is swallowed via `|| true`)
  #   5. plain passthrough exec  (no -o ControlPath token)
  call_count="$(grep -c '^CALL_ARGS:' "${log}")"
  [[ "${call_count}" -eq 5 ]]
  # The final call must NOT include ControlPath (i.e., plain exec path).
  final_call="$(grep '^CALL_ARGS:' "${log}" | tail -1)"
  [[ "${final_call}" != *"<ControlPath="* ]]
  [[ "${final_call}" != *"<-O>"* ]]
}

@test "integration (keychain): master-open uses BatchMode and ConnectTimeout (FileVault preboot)" {
  # During the FileVault preboot SSH phase (Apple Silicon, macOS Tahoe+),
  # only password auth is accepted and the connection drops after volume
  # unlock. Trying to set up a multiplexed master in that state would (a)
  # surface an unexpected /dev/tty password prompt for the auxiliary
  # connection and (b) produce a master that dies seconds later. Guard
  # the master with BatchMode=yes (no interactive prompts; key auth only)
  # and ConnectTimeout=10 (don't hang on partially-up hosts). When the
  # master fails, the wrapper falls through to the user's interactive
  # session, which is exactly the right experience for preboot unlock.
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  master_call="$(grep '^CALL_ARGS:' "${log}" | grep -- '<-fNM>')"
  [[ -n "${master_call}" ]]
  [[ "${master_call}" == *"<BatchMode=yes>"* ]]
  [[ "${master_call}" == *"<ConnectTimeout=10>"* ]]
}

@test "integration (keychain): remote security -i stderr is surfaced in warning on failure" {
  # If `security -i` on the remote returns non-zero (e.g., wrong
  # password, keychain not found), the wrapper must include its
  # stderr in the warning so the user can diagnose without hand-
  # instrumenting the wrapper.
  _setup_fake_op
  _setup_kc_config

  # A custom recorder that fails on the pipe-unlock invocation
  # (`'exec security -i'` as a single arg) and emits a specific
  # stderr line we can assert on.
  recorder="${TMPDIR_T}/err-recorder"
  log="${TMPDIR_T}/err-recorder.log"
  cat >"${recorder}" <<EOF
#!/usr/bin/env bash
log="${log}"
{
  printf 'CALL_ARGS:'
  for a in "\$@"; do printf ' <%s>' "\${a}"; done
  printf '\n'
  printf 'CALL_END\n'
} >>"\${log}"
# No live master yet: fail the \`-O check\` probe so the dance proceeds.
for a in "\$@"; do
  if [[ "\${a}" == "-O" ]]; then
    exit 255
  fi
done
# Identify the pipe-unlock invocation by its positional arg.
for a in "\$@"; do
  if [[ "\${a}" == "exec security -i" ]]; then
    printf 'security: SecKeychainUnlock login: The user name or passphrase you entered is not correct.\n' >&2
    exit 45
  fi
done
exit 0
EOF
  chmod +x "${recorder}"
  : >"${log}"

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  # Wrapper itself must still succeed (non-fatal continue).
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"keychain-unlock: remote security -i exit=45"* ]]
  [[ "${output}" == *"passphrase you entered is not correct"* ]]
}

@test "integration (keychain): OP_SERVICE_ACCOUNT_TOKEN is unset around keychain op read" {
  # Regression: the # op: loop exports OP_SERVICE_ACCOUNT_TOKEN before
  # _unlock_remote_keychain runs. If the token stays in env during the
  # keychain op read, the local op CLI uses service-account auth and
  # can't see the Personal vault where keychain passwords live. The
  # vault_scoped fake-op mode fails iff OP_SERVICE_ACCOUNT_TOKEN is
  # set — so a successful test proves the wrapper unset it for the
  # keychain fetch AND restored it for the exec (SendEnv forward).
  _setup_fake_op
  _setup_kc_recorder

  # Build a fixture with BOTH # op: and # op-keychain on the same host.
  kc_config="${TMPDIR_T}/kc-config-both"
  cat >"${kc_config}" <<'EOF'
Host mimolette.local
    # op: OP_SERVICE_ACCOUNT_TOKEN=op://Automation/svc/token
    # op-keychain: op://Personal/MIMOLETTE/password
EOF

  unset OP_SERVICE_ACCOUNT_TOKEN
  OP_FAKE_MODE=vault_scoped OP_FAKE_VALUE="pw-or-token" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  # No keychain-unlock failure should surface: token was unset for
  # that read.
  [[ "${output}" != *"keychain-unlock: op read failed"* ]]
  log_contents="$(<"${log}")"
  # Dance ran to completion: master, pipe with password, final exec.
  [[ "${log_contents}" == *"<-fNM>"* ]]
  [[ "${log_contents}" == *"<exec security -i>"* ]]
  [[ "${log_contents}" == *$'unlock-keychain -p pw-or-token\n'* ]]
  [[ "${log_contents}" != *"unlock-keychain -p pw-or-token login"* ]]
}

@test "integration (keychain): host without # op-keychain skips dance" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" plain.local

  [[ "${status}" -eq 0 ]]
  log_contents="$(<"${log}")"
  [[ "${log_contents}" != *"<-fNM>"* ]]
  [[ "${log_contents}" != *"<exec security -i>"* ]]
  call_count="$(grep -c '^CALL_ARGS:' "${log}")"
  [[ "${call_count}" -eq 1 ]]
}

# ─────────────────────────────────────────────────────────────────────────
# Integration: ControlMaster reuse (the modal-barrage fix)
#
# The keychain password lives in the Personal vault, so `op read` is
# TouchID-gated and pops a modal. A PID-keyed socket could never be
# reused, so every `ssh mimolette.local` paid that modal. These tests pin
# the fix: one live master per host means one prompt per persist window.
# ─────────────────────────────────────────────────────────────────────────

@test "integration (keychain): live master reuses socket without any op read" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config
  op_calls="${TMPDIR_T}/op-calls.log"
  : >"${op_calls}"

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    OP_FAKE_CALL_LOG="${op_calls}" \
    RECORDER_MASTER_ALIVE=1 \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  # THE point of the fix: no op read means no 1Password modal.
  [[ ! -s "${op_calls}" ]]
  log_contents="$(<"${log}")"
  # No master re-open and no re-unlock; the existing master is reused.
  [[ "${log_contents}" != *"<-fNM>"* ]]
  [[ "${log_contents}" != *"<exec security -i>"* ]]
  # The session still rides the shared master.
  final_call="$(grep '^CALL_ARGS:' "${log}" | tail -1)"
  [[ "${final_call}" == *"<ControlPath="*"unlock-mimolette.local.sock>"* ]]
}

@test "integration (keychain): socket is keyed on host, not PID" {
  # Regression: the original socket was "ssh-unlock-$$.sock", so two
  # invocations never shared one. Keying on the host is what makes reuse
  # (and therefore prompt suppression) possible at all.
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  log_contents="$(<"${log}")"
  [[ "${log_contents}" == *"unlock-mimolette.local.sock"* ]]
  [[ "${log_contents}" != *"ssh-unlock-$$"* ]]
  # Path must be deterministic: no PID anywhere in the socket name.
  sock_token="$(grep -o 'ControlPath=[^>]*' "${log}" | head -1)"
  [[ "${sock_token}" == *"/unlock-mimolette.local.sock" ]]
}

@test "integration (keychain): second invocation reuses the first master" {
  # End-to-end shape of the fix: run the wrapper twice. The first opens a
  # master and reads the secret; the second must do neither.
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config
  op_calls="${TMPDIR_T}/op-calls.log"

  # First run: no master yet -> full dance, one op read.
  : >"${op_calls}"
  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    OP_FAKE_CALL_LOG="${op_calls}" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local
  [[ "${status}" -eq 0 ]]
  first_op_count="$(grep -c '^OP_CALL:' "${op_calls}")"
  [[ "${first_op_count}" -eq 1 ]]

  # Second run with the master now alive: zero op reads, no -fNM.
  : >"${op_calls}"
  : >"${log}"
  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    OP_FAKE_CALL_LOG="${op_calls}" \
    RECORDER_MASTER_ALIVE=1 \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local
  [[ "${status}" -eq 0 ]]
  [[ ! -s "${op_calls}" ]]
  [[ "$(<"${log}")" != *"<-fNM>"* ]]
}

@test "integration (keychain): creation lock is released after master opens" {
  # A lock left behind would push every later invocation into the
  # wait-then-timeout path, silently losing the unlock.
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  [[ ! -d "${SSH_WRAPPER_CM_DIR}/unlock-mimolette.local.sock.lock" ]]
}

@test "integration (keychain): lock released even when op read fails" {
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config

  OP_FAKE_MODE=failure \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  [[ ! -d "${SSH_WRAPPER_CM_DIR}/unlock-mimolette.local.sock.lock" ]]
}

@test "_cm_socket_path: sanitizes path separators out of the host" {
  # A destination containing '/' must not escape the socket dir. Dots are
  # allowed (real hostnames need them), so traversal is prevented by
  # killing the separators rather than the dots.
  result="$(SSH_WRAPPER_CM_DIR=/tmp/cmtest _cm_socket_path '../../etc/evil')"
  [[ "${result}" == "/tmp/cmtest/unlock-.._.._etc_evil.sock" ]]
  # The socket stays a direct child of the socket dir.
  [[ "$(dirname "${result}")" == "/tmp/cmtest" ]]
}

@test "_cm_socket_path: strips shell metacharacters from the host" {
  result="$(SSH_WRAPPER_CM_DIR=/tmp/cmtest _cm_socket_path 'a;rm -rf /$(x)`y`')"
  [[ "$(dirname "${result}")" == "/tmp/cmtest" ]]
  [[ "${result}" != *';'* ]]
  [[ "${result}" != *'$'* ]]
  [[ "${result}" != *'`'* ]]
  [[ "${result}" != *' '* ]]
}

@test "_cm_socket_path: is stable across calls for the same host" {
  a="$(SSH_WRAPPER_CM_DIR=/tmp/cmtest _cm_socket_path 'mimolette.local')"
  b="$(SSH_WRAPPER_CM_DIR=/tmp/cmtest _cm_socket_path 'mimolette.local')"
  [[ "${a}" == "${b}" ]]
  [[ "${a}" == "/tmp/cmtest/unlock-mimolette.local.sock" ]]
}

@test "_cm_socket_path: stays under the 104-byte sun_path limit for a real host" {
  # ssh rejects longer ControlPath values outright ("ControlPath too long").
  result="$(SSH_WRAPPER_CM_DIR="${HOME}/.ssh/cm" _cm_socket_path 'mimolette.local')"
  [[ "${#result}" -lt 104 ]]
}

@test "_cm_acquire_lock: is exclusive, and released locks are re-acquirable" {
  sock="${TMPDIR_T}/lock-probe.sock"
  _cm_acquire_lock "${sock}"
  # Second acquisition must fail while the first is held.
  run _cm_acquire_lock "${sock}"
  [[ "${status}" -ne 0 ]]
  _cm_release_lock "${sock}"
  # Now it is available again.
  _cm_acquire_lock "${sock}"
  _cm_release_lock "${sock}"
}

@test "integration (keychain): stale lock is broken so it cannot wedge forever" {
  # A holder killed with SIGKILL (or a panic) leaves the lock behind with
  # no trap able to fire. Without a staleness breaker every later connect
  # would silently skip the unlock forever.
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config
  mkdir -p "${SSH_WRAPPER_CM_DIR}"
  lock="${SSH_WRAPPER_CM_DIR}/unlock-mimolette.local.sock.lock"
  mkdir -p "${lock}"
  _backdate "${lock}" 120

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    SSH_WRAPPER_LOCK_WAIT=2 \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  # The stale lock was broken and the dance ran normally.
  [[ "$(<"${log}")" == *"<-fNM>"* ]]
  # And it did not leave a lock behind.
  [[ ! -d "${lock}" ]]
}

@test "integration (keychain): fresh held lock makes the wrapper wait, not prompt" {
  # A lock held by a live peer must NOT trigger a second op read (that is
  # the duplicate modal we are eliminating). The wrapper waits for the
  # peer's master, then gives up and falls through without unlocking.
  _setup_fake_op
  _setup_kc_recorder
  _setup_kc_config
  op_calls="${TMPDIR_T}/op-calls.log"
  : >"${op_calls}"
  mkdir -p "${SSH_WRAPPER_CM_DIR}"
  lock="${SSH_WRAPPER_CM_DIR}/unlock-mimolette.local.sock.lock"
  mkdir -p "${lock}"   # fresh: mtime is now, so not stale

  OP_FAKE_MODE=success OP_FAKE_VALUE="pw" \
    OP_FAKE_CALL_LOG="${op_calls}" \
    SSH_WRAPPER_LOCK_WAIT=2 \
    SSH_CONFIG_PATH="${kc_config}" \
    SSH_WRAPPER_REAL_SSH="${recorder}" \
    PATH="${TMPDIR_T}/bin:${PATH}" \
    run "${WRAPPER}" mimolette.local

  [[ "${status}" -eq 0 ]]
  # No competing master, and crucially no second prompt.
  [[ "$(<"${log}")" != *"<-fNM>"* ]]
  [[ ! -s "${op_calls}" ]]
  [[ "${output}" == *"no master from concurrent setup"* ]]
  # The peer's lock is left alone (we did not steal a live lock).
  [[ -d "${lock}" ]]
  # The session still goes through as a plain exec.
  final_call="$(grep '^CALL_ARGS:' "${log}" | tail -1)"
  [[ "${final_call}" == *"<mimolette.local>"* ]]
}

@test "_cm_lock_is_stale: fresh lock is not stale, old lock is" {
  sock="${TMPDIR_T}/age-probe.sock"
  mkdir -p "${sock}.lock"
  run _cm_lock_is_stale "${sock}"
  [[ "${status}" -ne 0 ]]
  _backdate "${sock}.lock" 120
  run _cm_lock_is_stale "${sock}"
  [[ "${status}" -eq 0 ]]
}

@test "_cm_lock_is_stale: absent lock is not stale" {
  run _cm_lock_is_stale "${TMPDIR_T}/no-such.sock"
  [[ "${status}" -ne 0 ]]
}
