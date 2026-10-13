#!/usr/bin/env bash
#
# openai-tunnel-instapaper.sh - run the OpenAI tunnel client for the
# Instapaper profile, with the control-plane API key pulled from the login
# keychain. The Instapaper MCP launcher separately obtains its Instapaper
# credentials from Keychain.
#
# Launched by com.andrewrich.openai-tunnel-instapaper.plist. Nothing here may
# depend on an interactive shell's environment.

set -euo pipefail

if ! TUNNEL_CLIENT="$(command -v tunnel-client)"; then
  printf '%s: tunnel-client not found on PATH (%s)\n' "$(date)" "${PATH}" >&2
  exit 1
fi

KEYCHAIN_ACCOUNT="$(id -un)"

if ! CONTROL_PLANE_API_KEY="$(
  /usr/bin/security find-generic-password \
    -a "${KEYCHAIN_ACCOUNT}" \
    -s "openai-tunnel-client" \
    -w
)"; then
  printf '%s: no keychain item "openai-tunnel-client" for account %s\n' \
    "$(date)" "${KEYCHAIN_ACCOUNT}" >&2
  exit 1
fi

if [[ -z "${CONTROL_PLANE_API_KEY}" ]]; then
  printf '%s: keychain item "openai-tunnel-client" is empty\n' "$(date)" >&2
  exit 1
fi

export CONTROL_PLANE_API_KEY

exec "${TUNNEL_CLIENT}" run --profile instapaper
