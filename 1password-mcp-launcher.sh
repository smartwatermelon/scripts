#!/usr/bin/env bash
set -euo pipefail

# 1password-mcp-launcher.sh
# Reads OP_SERVICE_ACCOUNT_TOKEN from macOS Keychain and launches the
# 1Password MCP server. Keeps the token out of claude_desktop_config.json.
#
# The MCP server is installed once at a pinned version to avoid handing
# the keychain-held credential to whatever `npx -y` happens to download.
# To install or upgrade:
#   mkdir -p ~/.local/opt/1password-mcp
#   cd ~/.local/opt/1password-mcp
#   npm init -y
#   npm install @takescake/1password-mcp@<version>
# Audit the package before each upgrade, then bump PINNED_VERSION below.

PINNED_VERSION="2.4.1"
MCP_ROOT="${HOME}/.local/opt/1password-mcp"
MCP_BIN="${MCP_ROOT}/node_modules/.bin/1password-mcp"
MCP_PKG_JSON="${MCP_ROOT}/node_modules/@takescake/1password-mcp/package.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for pinned-version verification but was not found on PATH." >&2
  echo "Install: brew install jq" >&2
  exit 1
fi

if [[ ! -x "${MCP_BIN}" ]]; then
  echo "ERROR: 1password-mcp not installed at ${MCP_BIN}" >&2
  echo "Install with:" >&2
  echo "  mkdir -p ${MCP_ROOT} && cd ${MCP_ROOT} \\" >&2
  echo "    && npm init -y && npm install @takescake/1password-mcp@${PINNED_VERSION}" >&2
  exit 1
fi

if [[ ! -f "${MCP_PKG_JSON}" ]]; then
  echo "ERROR: @takescake/1password-mcp package.json missing at ${MCP_PKG_JSON}" >&2
  echo "Re-install: cd ${MCP_ROOT} && npm install @takescake/1password-mcp@${PINNED_VERSION}" >&2
  exit 1
fi

installed_version="$(jq -r '.version // empty' "${MCP_PKG_JSON}" 2>/dev/null)" || {
  echo "ERROR: failed to parse ${MCP_PKG_JSON}" >&2
  echo "Re-install: cd ${MCP_ROOT} && npm install @takescake/1password-mcp@${PINNED_VERSION}" >&2
  exit 1
}
if [[ "${installed_version}" != "${PINNED_VERSION}" ]]; then
  echo "ERROR: installed @takescake/1password-mcp version '${installed_version}' does not match pinned '${PINNED_VERSION}'." >&2
  echo "Re-install: cd ${MCP_ROOT} && npm install @takescake/1password-mcp@${PINNED_VERSION}" >&2
  exit 1
fi

_token="$(security find-generic-password \
  -a "$USER" \
  -s "op-service-account-claude-automation" \
  -w 2>/dev/null)" || {
  echo "ERROR: 1Password service account token not found in Keychain." >&2
  echo "Run: security add-generic-password -a \"\$USER\" -s op-service-account-claude-automation -w <token>" >&2
  exit 1
}

if [[ -z "${_token}" ]]; then
  echo "ERROR: Keychain item 'op-service-account-claude-automation' exists but is empty." >&2
  echo "Delete and re-add: security delete-generic-password -a \"\$USER\" -s op-service-account-claude-automation" >&2
  exit 1
fi

# Trade-off: exporting the token into this process's environment means it is
# visible to the exec'd MCP server (and any child it spawns), rather than
# being piped in more narrowly. Accepted because the MCP protocol here offers
# no narrower credential-injection channel.
export OP_SERVICE_ACCOUNT_TOKEN="${_token}"
unset _token

exec "${MCP_BIN}"
