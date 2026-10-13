#!/usr/bin/env bash
set -euo pipefail

# instapaper-mcp-launcher.sh
# Reads Instapaper API credentials from the macOS Keychain and launches the
# Instapaper MCP server. Keeps the credentials out of
# claude_desktop_config.json, which is world-readable-by-any-process plaintext
# and is rewritten by Claude Desktop on its own schedule.
#
# The server itself calls dotenv.config(), which resolves .env against the
# process working directory rather than the script location. A Desktop-spawned
# server does not run from the repo, so a repo-local .env is never found.
# Exporting into the environment here is what actually reaches the server.
#
# To seed or rotate a credential:
#   security add-generic-password -a "$USER" -s instapaper-mcp-<name> -w <value> -U
# where <name> is one of: consumer-key, consumer-secret, username, password

MCP_ENTRY="${HOME}/Developer/Instapaper-MCP/build/index.js"
KEYCHAIN_ACCOUNT="$(id -un)"

if [[ ! -f "${MCP_ENTRY}" ]]; then
  echo "ERROR: Instapaper MCP not built at ${MCP_ENTRY}" >&2
  echo "Build with: cd ${HOME}/Developer/Instapaper-MCP && npm install && npm run build" >&2
  exit 1
fi

# Keychain service name -> environment variable the server reads.
_read_secret() {
  local svc="$1" var="$2" val
  val="$(security find-generic-password -a "${KEYCHAIN_ACCOUNT}" -s "${svc}" -w 2>/dev/null)" || {
    echo "ERROR: Keychain item '${svc}' not found." >&2
    echo "Add it: security add-generic-password -a \"\$USER\" -s ${svc} -w <value> -U" >&2
    exit 1
  }
  if [[ -z "${val}" ]]; then
    echo "ERROR: Keychain item '${svc}' exists but is empty." >&2
    echo "Re-add it: security add-generic-password -a \"\$USER\" -s ${svc} -w <value> -U" >&2
    exit 1
  fi
  export "${var}=${val}"
}

# Trade-off: exporting into this process's environment makes the credentials
# visible to the exec'd MCP server and any child it spawns. Accepted for the
# same reason as 1password-mcp-launcher.sh — the MCP stdio protocol offers no
# narrower credential-injection channel.
_read_secret instapaper-mcp-consumer-key INSTAPAPER_CONSUMER_KEY
_read_secret instapaper-mcp-consumer-secret INSTAPAPER_CONSUMER_SECRET
_read_secret instapaper-mcp-username INSTAPAPER_USERNAME
_read_secret instapaper-mcp-password INSTAPAPER_PASSWORD

exec node "${MCP_ENTRY}"
