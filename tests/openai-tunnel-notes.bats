#!/usr/bin/env bats
# Regression tests for the Apple Notes tunnel launcher. The wrapper must be
# safe under launchd's sparse environment and select only its own profile.

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
	SCRIPT="${REPO_ROOT}/openai-tunnel-notes.sh"
	TMPDIR_T="$(mktemp -d)"
	STUB_DIR="${TMPDIR_T}/bin"
	mkdir -p "${STUB_DIR}"
}

teardown() {
	[[ -n "${TMPDIR_T:-}" ]] && rm -rf "${TMPDIR_T}"
}

_stub_tunnel_client() {
	cat >"${STUB_DIR}/tunnel-client" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${TMPDIR_T}/argv"
printf '%s\n' "\${CONTROL_PLANE_API_KEY-<unset>}" >"${TMPDIR_T}/key_seen"
EOF
	chmod +x "${STUB_DIR}/tunnel-client"
}

_stub_security() {
	local value="$1" rc="${2:-0}"
	printf '%s' "${value}" >"${TMPDIR_T}/secret"
	cat >"${STUB_DIR}/security" <<EOF
#!/usr/bin/env bash
if [[ ${rc} -ne 0 ]]; then
  exit ${rc}
fi
cat "${TMPDIR_T}/secret"
EOF
	chmod +x "${STUB_DIR}/security"
	sed "s#/usr/bin/security#${STUB_DIR}/security#" "${SCRIPT}" >"${TMPDIR_T}/openai-tunnel-notes.sh"
	chmod +x "${TMPDIR_T}/openai-tunnel-notes.sh"
}

_run_as_launchd() {
	run env -u USER "PATH=${STUB_DIR}:/usr/bin:/bin" "${TMPDIR_T}/openai-tunnel-notes.sh"
}

# This catches a profile typo or accidental reuse of server-filesystem, which
# would route Notes requests through the wrong independently managed tunnel.
@test "runs tunnel-client with the apple-notes profile" {
	_stub_tunnel_client
	_stub_security "test-control-plane-key"
	_run_as_launchd
	[ "${status}" -eq 0 ]
	[ "$(cat "${TMPDIR_T}/argv")" = "run
--profile
apple-notes" ]
	[ "$(cat "${TMPDIR_T}/key_seen")" = "test-control-plane-key" ]
}

# This catches a malformed deployment path that launchd itself would reject.
@test "the Apple Notes LaunchAgent plist parses and invokes its installed symlink" {
	local plist="${REPO_ROOT}/LaunchAgents/com.andrewrich.openai-tunnel-notes.plist"
	run python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
print(d["Label"])
print(d["ProgramArguments"][0])
' "${plist}"
	[ "${status}" -eq 0 ]
	[ "${lines[0]}" = "com.andrewrich.openai-tunnel-notes" ]
	[ "${lines[1]}" = "/Users/andrewrich/.local/bin/openai-tunnel-notes" ]
}
