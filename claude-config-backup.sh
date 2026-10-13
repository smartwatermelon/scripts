#!/usr/bin/env bash
set -euo pipefail

# claude-config-backup.sh
# Snapshots machine-local Claude config files into a git repo and pushes.
#
# These files are rewritten by Claude Desktop / Claude Code on their own
# schedule, with no history. An MCP server entry once vanished from
# claude_desktop_config.json with no record of when or why; this repo exists
# so the next such change is a one-line diff instead of an investigation.
#
# Deliberately outside the normal review/PR/merge workflow: it commits
# unattended, so there is no place for a human or a review agent in the loop.
#
# Safety: a config being written when we copy it would commit a truncated or
# invalid file, which is worse than no backup. Every tracked file must be
# BOTH quiescent (size and mtime unchanged across a settle interval) AND
# valid JSON before it is committed.

REPO="${XDG_DATA_HOME:-${HOME}/.local/share}/claude-config-backup"

# Tracked files: "<destination path inside repo>|<absolute source path>"
# Add a line here to track another file.
TRACKED=(
  "desktop/claude_desktop_config.json|${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
  "cli/claude.json|${HOME}/.claude/.claude.json"
)

# Seconds to wait between the two stat samples used for the quiescence check.
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] $*"
}

if ! command -v git >/dev/null 2>&1; then
  log "ERROR: git not found on PATH"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 not found on PATH (required for JSON validation)"
  exit 1
fi

# A file is quiescent when size+mtime are identical across SETTLE_SECONDS.
# Catches the common case of a config being rewritten as we run.
_fingerprint() {
  stat -f "%z:%m" "$1" 2>/dev/null || echo "MISSING"
}

_is_quiescent() {
  local f="$1" a b
  a="$(_fingerprint "$f")"
  [[ "$a" == "MISSING" ]] && return 1
  sleep "${SETTLE_SECONDS}"
  b="$(_fingerprint "$f")"
  [[ "$a" == "$b" ]]
}

_is_valid_json() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
}

# Refuse to commit anything that looks like a live credential. These files are
# rewritten by apps we do not control, so a future app version can reintroduce
# a plaintext secret into a file that was clean when it was first tracked.
# Fail closed: an unrecognized secret shape should be added here, not ignored.
# Secret detection is gitleaks-first. gitleaks maintains ~170 upstream rules
# (AWS, GitHub, Stripe, Slack, Perplexity, ...) so we do not hand-maintain them.
#
# It is NOT sufficient on its own. Measured against this machine's real config
# on 2026-08-26, gitleaks caught 1 of 4 live keys present. semgrep's p/secrets
# ruleset caught 0 of 4 and is not used. The supplemental patterns below cover
# exactly the gaps that were demonstrated, and nothing more:
#   - ctx7sk-   Context7      (no upstream rule)
#   - sk_       RevenueCat    (no upstream rule)
#   - xkeysib-  Brevo         (no upstream rule, AND base64url-encoded into a
#                              URL path, so no raw-text scanner can see it)
# Add a pattern here only with a known-bad case proving the gap.
SUPPLEMENTAL_PATTERNS=(
  'ctx7sk-[A-Za-z0-9-]{16,}'
  'sk_[A-Za-z0-9]{20,}'
  'xkeysib-[A-Za-z0-9-]{16,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  # Belt-and-braces on shapes gitleaks allowlists as well-known documentation
  # examples, or that score below its entropy floor. Cheap to check; a real
  # key of these shapes must never slip through.
  # (No literal example key here on purpose - secret scanners flag one even
  # inside a comment, and they are right to.)
  '(AKIA|ASIA)[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
)

# Fail closed: without gitleaks we have only the narrow supplement, which is
# not enough to certify a file as clean. Refuse rather than commit blind.
if ! command -v gitleaks >/dev/null 2>&1; then
  log "ERROR: gitleaks not found on PATH; refusing to run"
  log "Install: brew install gitleaks"
  exit 1
fi

_gitleaks_finding() {
  local f="$1" report rule
  report="$(mktemp)"
  # gitleaks exits 1 when it finds leaks; that is a result, not a failure.
  gitleaks detect --no-git --source "${f}" --redact \
    --report-format json --report-path "${report}" >/dev/null 2>&1 || true
  rule="$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if d:
    print(d[0].get("RuleID", "unknown-rule"))' "${report}" 2>/dev/null)"
  rm -f "${report}"
  [[ -n "${rule}" ]] && {
    echo "gitleaks:${rule}"
    return 0
  }
  return 1
}

_supplemental_finding() {
  local f="$1" pat decoded
  for pat in "${SUPPLEMENTAL_PATTERNS[@]}"; do
    grep -Eqi "${pat}" "${f}" 2>/dev/null && {
      echo "${pat}"
      return 0
    }
  done

  # Decode long base64url runs and re-scan. This is how the Brevo key hid:
  # https://mcp.brevo.com/v1/brevo/mcp/<base64url of {"api_key":"xkeysib-..."}>
  decoded="$(
    python3 - "${f}" <<'PYEOF' 2>/dev/null
import base64, re, sys
raw = open(sys.argv[1], "r", errors="ignore").read()
out = []
for seg in re.findall(r"[A-Za-z0-9_-]{32,}", raw):
    for pad in range(4):
        try:
            out.append(base64.urlsafe_b64decode(seg + "=" * pad).decode("utf-8"))
        except Exception:
            continue
        break
print("\n".join(out))
PYEOF
  )" || decoded=""

  if [[ -n "${decoded}" ]]; then
    for pat in "${SUPPLEMENTAL_PATTERNS[@]}"; do
      printf '%s' "${decoded}" | grep -Eqi "${pat}" 2>/dev/null \
        && {
          echo "${pat} (base64-encoded)"
          return 0
        }
    done
  fi
  return 1
}

_has_secret() {
  local f="$1" hit
  if hit="$(_gitleaks_finding "${f}")"; then
    echo "${hit}"
    return 0
  fi
  if hit="$(_supplemental_finding "${f}")"; then
    echo "${hit}"
    return 0
  fi
  return 1
}

if [[ ! -d "${REPO}/.git" ]]; then
  log "ERROR: no git repo at ${REPO}"
  log "Initialize it first (see repo README)."
  exit 1
fi

copied=0
skipped=0
matched_pattern=""

for entry in "${TRACKED[@]}"; do
  dest_rel="${entry%%|*}"
  src="${entry#*|}"
  dest="${REPO}/${dest_rel}"

  if [[ ! -f "${src}" ]]; then
    log "SKIP ${dest_rel}: source missing (${src})"
    skipped=$((skipped + 1))
    continue
  fi

  if ! _is_quiescent "${src}"; then
    log "SKIP ${dest_rel}: file is being written, will retry next run"
    skipped=$((skipped + 1))
    continue
  fi

  if ! _is_valid_json "${src}"; then
    log "SKIP ${dest_rel}: source is not valid JSON, refusing to commit"
    skipped=$((skipped + 1))
    continue
  fi

  if matched_pattern="$(_has_secret "${src}")"; then
    log "SKIP ${dest_rel}: matches secret pattern /${matched_pattern}/ — refusing to commit"
    log "  Move the credential out of ${src} (Keychain + a launcher script), then re-run."
    skipped=$((skipped + 1))
    continue
  fi

  mkdir -p "$(dirname "${dest}")"
  # Copy to a temp file in the destination dir, validate, then move into place,
  # so an interrupted copy never leaves a partial file staged.
  tmp="${dest}.tmp.$$"
  cp "${src}" "${tmp}"
  if ! _is_valid_json "${tmp}"; then
    log "SKIP ${dest_rel}: copy failed JSON validation, discarding"
    rm -f "${tmp}"
    skipped=$((skipped + 1))
    continue
  fi
  mv "${tmp}" "${dest}"
  chmod 600 "${dest}"
  copied=$((copied + 1))
done

if [[ "${copied}" -eq 0 ]]; then
  log "nothing copied (${skipped} skipped); exiting"
  exit 0
fi

# Stage tracked paths individually; never `git add .`
for entry in "${TRACKED[@]}"; do
  dest_rel="${entry%%|*}"
  [[ -f "${REPO}/${dest_rel}" ]] && git -C "${REPO}" add -- "${dest_rel}"
done

if git -C "${REPO}" diff --cached --quiet; then
  log "no content change; nothing to commit"
  exit 0
fi

changed="$(git -C "${REPO}" diff --cached --name-only | tr '\n' ' ' | sed 's/ $//')"
stat_line="$(git -C "${REPO}" diff --cached --shortstat | sed 's/^ *//')"

captured_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"
git -C "${REPO}" commit --quiet \
  -m "auto: ${changed} (${stat_line})" \
  -m "Captured ${captured_at} by claude-config-backup.sh"
log "committed: ${changed} — ${stat_line}"

if git -C "${REPO}" remote get-url origin >/dev/null 2>&1; then
  if git -C "${REPO}" push --quiet origin HEAD 2>/dev/null; then
    log "pushed to origin"
  else
    log "WARN: push failed; commit is safe locally, will retry next run"
  fi
else
  log "no origin remote configured; commit is local only"
fi
