#!/usr/bin/env bats
# bats tests for openai-tunnel-client.sh
#
# Run from repo root:  bats tests/openai-tunnel-client.bats
#
# The script is a thin credential-fetching wrapper that ends in `exec
# tunnel-client run --profile server-filesystem`, so there are no sourceable
# functions to unit-test. These run it end to end with `security` and
# `tunnel-client` stubbed onto PATH, which is also the only way to reproduce
# the launchd environment the real bugs lived in.
#
# Each test here maps to a defect found while debugging the LaunchAgent, and
# every one of them was invisible in an interactive shell:
#
#   - USER is set in a terminal but NOT by launchd. Under `set -u` the
#     unbound expansion killed the script before it reached exec.
#   - `export VAR="$(cmd)" || exit 1` tests export's exit status, not cmd's,
#     so a failed keychain read exported an empty key and the script ran on
#     to authenticate with nothing.
#   - `security add-generic-password -w` silently truncates a long pasted
#     secret, so an empty-or-partial value must be caught locally rather than
#     surfacing later as a 401 from the service.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${REPO_ROOT}/openai-tunnel-client.sh"
  TMPDIR_T="$(mktemp -d)"
  STUB_DIR="${TMPDIR_T}/bin"
  mkdir -p "${STUB_DIR}"
}

teardown() {
  [[ -n "${TMPDIR_T:-}" ]] && rm -rf "${TMPDIR_T}"
}

# Stubs tunnel-client to record the argv it was exec'd with and exit 0, so a
# test can assert on the command line without a real tunnel.
_stub_tunnel_client() {
  cat >"${STUB_DIR}/tunnel-client" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${TMPDIR_T}/argv"
printf '%s\n' "\${CONTROL_PLANE_API_KEY-<unset>}" >"${TMPDIR_T}/key_seen"
EOF
  chmod +x "${STUB_DIR}/tunnel-client"
}

# Stubs /usr/bin/security. The script calls it by absolute path, so the stub
# goes into a fake usr/bin that a bind-style PATH cannot reach — instead the
# tests run the script with a rewritten copy pointing at the stub. $1 is the
# value to emit, $2 the exit status (default 0).
_stub_security() {
  local value="$1" rc="${2:-0}"
  printf '%s' "${value}" >"${TMPDIR_T}/secret"
  cat >"${STUB_DIR}/security" <<EOF
#!/usr/bin/env bash
if [[ ${rc} -ne 0 ]]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit ${rc}
fi
cat "${TMPDIR_T}/secret"
EOF
  chmod +x "${STUB_DIR}/security"
  # Point the script's absolute /usr/bin/security call at the stub.
  sed "s#/usr/bin/security#${STUB_DIR}/security#" "${SCRIPT}" \
    >"${TMPDIR_T}/openai-tunnel-client.sh"
  chmod +x "${TMPDIR_T}/openai-tunnel-client.sh"
}

# Runs the rewritten script with a launchd-like environment: USER unset, and a
# PATH containing only the stub dir plus the system essentials.
_run_as_launchd() {
  run env -u USER "PATH=${STUB_DIR}:/usr/bin:/bin" \
    "${TMPDIR_T}/openai-tunnel-client.sh"
}

@test "runs tunnel-client with the server-filesystem profile" {
  _stub_tunnel_client
  _stub_security "sk-proj-abc123"
  _run_as_launchd
  [ "${status}" -eq 0 ]
  [ "$(cat "${TMPDIR_T}/argv")" = "run
--profile
server-filesystem" ]
}

@test "exports the keychain value as CONTROL_PLANE_API_KEY" {
  _stub_tunnel_client
  _stub_security "sk-proj-abc123"
  _run_as_launchd
  [ "${status}" -eq 0 ]
  [ "$(cat "${TMPDIR_T}/key_seen")" = "sk-proj-abc123" ]
}

# launchd does not export USER. The original script used "$USER" as the
# keychain account and died on the unbound variable under `set -u`.
@test "succeeds with USER unset, as under launchd" {
  _stub_tunnel_client
  _stub_security "sk-proj-abc123"
  _run_as_launchd
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"USER: unbound variable"* ]]
}

# `export VAR="$(cmd)" || exit 1` masks cmd's status behind export's, so this
# case used to exec tunnel-client with an empty key instead of exiting.
@test "fails when the keychain item is missing" {
  _stub_tunnel_client
  _stub_security "" 44
  _run_as_launchd
  [ "${status}" -eq 1 ]
  [[ "${output}" == *'no keychain item "openai-tunnel-client"'* ]]
  [ ! -f "${TMPDIR_T}/argv" ]
}

# The truncation mode of `security add-generic-password -w`: the item exists
# and the read succeeds, but the value is empty. Better to fail here than to
# authenticate with nothing and read a 401 out of the log later.
@test "fails when the keychain item is empty" {
  _stub_tunnel_client
  _stub_security ""
  _run_as_launchd
  [ "${status}" -eq 1 ]
  [[ "${output}" == *'is empty'* ]]
  [ ! -f "${TMPDIR_T}/argv" ]
}

@test "fails with a diagnostic when tunnel-client is not on PATH" {
  _stub_security "sk-proj-abc123"
  # No tunnel-client stub written, so command -v cannot resolve it.
  _run_as_launchd
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"tunnel-client not found on PATH"* ]]
}

# Parses the plist with Python's stdlib plistlib rather than plutil, which is
# macOS-only and absent on the Linux CI runner. This is the assertion that
# actually matters: the tracked file was once a `cat > ... <<'EOF'` install
# command saved verbatim, which no plist parser accepts.
@test "the LaunchAgent plist parses and points at the installed symlink" {
  local plist="${REPO_ROOT}/LaunchAgents/com.andrewrich.openai-tunnel-filesystem.plist"
  [ -f "${plist}" ]
  run python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
print(d["Label"])
print(d["ProgramArguments"][0])
' "${plist}"
  [ "${status}" -eq 0 ]
  # The plist launches the ~/.local/bin symlink, not the repo path, matching
  # how every other script here is invoked. launchd does not expand ~ or $HOME
  # in ProgramArguments, so the path is necessarily absolute and hardcoded —
  # assert the literal value rather than deriving it from $HOME, which differs
  # on the CI runner.
  [ "${lines[0]}" = "com.andrewrich.openai-tunnel-filesystem" ]
  [ "${lines[1]}" = "/Users/andrewrich/.local/bin/openai-tunnel-client" ]
}

# plutil is the tool launchd's own parser agrees with, so keep it as an extra
# check where it exists. Same pattern as the realpath guard in ssh-wrapper.bats.
@test "the LaunchAgent plist passes plutil -lint (macOS only)" {
  command -v plutil >/dev/null || skip "plutil not available on this runner"
  run plutil -lint "${REPO_ROOT}/LaunchAgents/com.andrewrich.openai-tunnel-filesystem.plist"
  [ "${status}" -eq 0 ]
}
