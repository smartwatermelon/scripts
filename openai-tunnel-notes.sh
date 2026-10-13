#!/usr/bin/env bash
#
# openai-tunnel-notes.sh - run the OpenAI tunnel client for the Apple Notes
# profile, with the control-plane API key pulled from the login keychain.
#
# Launched by com.andrewrich.openai-tunnel-notes.plist. Nothing here may
# depend on an interactive shell's environment: launchd sets neither USER nor
# HOME-derived PATH entries the way a login shell does.

set -euo pipefail

if ! TUNNEL_CLIENT="$(command -v tunnel-client)"; then
	NOW="$(date)"
	printf '%s: tunnel-client not found on PATH (%s)\n' "${NOW}" "${PATH}" >&2
	exit 1
fi

# launchd does not export USER, so ask the system instead of the environment.
KEYCHAIN_ACCOUNT="$(id -un)"

# Assign first, then export: `export VAR="$(cmd)"` masks cmd's exit status
# behind export's own, so a keychain miss would export an empty key.
if ! CONTROL_PLANE_API_KEY="$(
	/usr/bin/security find-generic-password \
		-a "${KEYCHAIN_ACCOUNT}" \
		-s "openai-tunnel-client" \
		-w
)"; then
	NOW="$(date)"
	printf '%s: no keychain item "openai-tunnel-client" for account %s\n' \
		"${NOW}" "${KEYCHAIN_ACCOUNT}" >&2
	exit 1
fi

if [[ -z "${CONTROL_PLANE_API_KEY}" ]]; then
	NOW="$(date)"
	printf '%s: keychain item "openai-tunnel-client" is empty\n' "${NOW}" >&2
	exit 1
fi

export CONTROL_PLANE_API_KEY

exec "${TUNNEL_CLIENT}" run --profile apple-notes
