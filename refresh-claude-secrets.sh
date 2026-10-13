#!/usr/bin/env bash
# refresh-claude-secrets.sh
# Resolves secret references from secrets.op via `op` and writes plaintext
# values to claude-secrets.md for use by Claude via the Filesystem MCP.
# Run this after rotating any credentials. The op:// references are stable.
#
# MUST be run from ~/.config/claude-code (symlinked there from Developer/scripts).

set -euo pipefail

EXPECTED_DIR="${HOME}/.config/claude-code"
SCRIPT_DIR="$(dirname "$0")"

# Guard: only run from the expected directory
resolved_script="$(cd "${SCRIPT_DIR}" && pwd -P)"
resolved_expected="$(cd "${EXPECTED_DIR}" 2>/dev/null && pwd -P)" || {
  echo "ERROR: ${EXPECTED_DIR} does not exist." >&2
  exit 1
}
if [[ "${resolved_script}" != "${resolved_expected}" ]]; then
  echo "ERROR: Must be run from ${EXPECTED_DIR} (or via its symlink)." >&2
  echo "  Actual location: ${SCRIPT_DIR}" >&2
  exit 1
fi

SECRETS_OP="${SCRIPT_DIR}/secrets.op"
OUT="${SCRIPT_DIR}/claude-secrets.md"

# Verify secrets.op exists and is readable
if [[ ! -r "${SECRETS_OP}" ]]; then
  echo "ERROR: Cannot read ${SECRETS_OP}" >&2
  exit 1
fi

# Verify op CLI is available
if ! command -v op &>/dev/null; then
  echo "ERROR: 1Password CLI (op) not found in PATH." >&2
  exit 1
fi

# Atomic write: build into temp file, then rename into place.
# Prevents TOCTOU (secrets never world-readable) and preserves the
# previous output file if this run fails partway through.
tmpfile="$(mktemp "${SCRIPT_DIR}/.claude-secrets.XXXXXX")"
chmod 600 "${tmpfile}"
trap 'rm -f "${tmpfile}"' EXIT

generated_at="$(date)"
{
  echo "# Claude Runtime Secrets"
  echo "# Auto-generated: ${generated_at}"
  echo "# Resolved from secrets.op via 1Password. Do not commit or share."
  echo ""

  while IFS='=' read -r key ref; do
    # Skip comments and blank lines
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key}" ]] && continue

    # Validate key is a safe identifier (letters, digits, underscores)
    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "ERROR: Invalid key name '${key}' in secrets.op" >&2
      exit 1
    fi

    # Validate ref starts with op://
    if [[ "${ref}" != op://* ]]; then
      echo "ERROR: Value for '${key}' is not an op:// reference (malformed)" >&2
      exit 1
    fi

    value="$(op read "${ref}")"

    # Reject multiline values (e.g. PEM keys, notes) — not supported by this format
    if [[ "${value}" == *$'\n'* ]]; then
      echo "ERROR: Secret '${key}' contains newlines (unsupported)" >&2
      exit 1
    fi

    echo "${key}=${value}"
  done <"${SECRETS_OP}"
} >"${tmpfile}"

# Finalize: lock permissions and atomically move into place
chmod 400 "${tmpfile}"
mv -f "${tmpfile}" "${OUT}"
trap - EXIT

echo "Secrets written to ${OUT} (mode 400)"
