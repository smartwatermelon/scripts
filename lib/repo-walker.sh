# shellcheck shell=bash
# repo-walker.sh — shared implementation for my-repos.sh and beacon-repos.sh.
#
# Not executable and not a command. Wrappers set REPO_WALKER_DEVDIR,
# REPO_WALKER_ORGS, REPO_WALKER_DESC, and REPO_WALKER_DIRVAR, source this
# file, then call repo_walker_main "$@". Sourcing defines functions and the
# REPO_WALKER_* colour constants below; it runs no commands and touches
# nothing outside the shell.

REPO_WALKER_GREEN='\033[0;32m'
REPO_WALKER_YELLOW='\033[0;33m'
REPO_WALKER_RED='\033[0;31m'
REPO_WALKER_CYAN='\033[0;36m'
REPO_WALKER_RESET='\033[0m'

repo_walker_require_config() {
  local missing=()
  [[ -n "${REPO_WALKER_DEVDIR:-}" ]] || missing+=("REPO_WALKER_DEVDIR")
  [[ -n "${REPO_WALKER_ORGS:-}" ]] || missing+=("REPO_WALKER_ORGS")
  [[ -n "${REPO_WALKER_DESC:-}" ]] || missing+=("REPO_WALKER_DESC")
  [[ -n "${REPO_WALKER_DIRVAR:-}" ]] || missing+=("REPO_WALKER_DIRVAR")

  if ((${#missing[@]} > 0)); then
    echo "Error: lib/repo-walker.sh is a library, not a command." >&2
    echo "Missing required configuration: ${missing[*]}" >&2
    echo "Run my-repos.sh or beacon-repos.sh instead." >&2
    exit 2
  fi
}

repo_walker_check_devdir() {
  if [[ ! -d "${REPO_WALKER_DEVDIR}" ]]; then
    echo "Warning: repo directory not found: ${REPO_WALKER_DEVDIR}" >&2
    echo "         nothing to do. Set ${REPO_WALKER_DIRVAR} to override." >&2
    return 1
  fi
  return 0
}

# The wrapper is the outermost frame in the source stack, so BASH_SOURCE[-1]
# names it even though this code lives in the library.
repo_walker_script_name() {
  basename "${BASH_SOURCE[-1]}"
}

repo_walker_usage() {
  local script_name
  script_name="$(repo_walker_script_name)"
  cat <<EOF
Usage: ${script_name} [OPTIONS]

${REPO_WALKER_DESC}

Options:
  --check       Only report dirty repos (no pulls, no network access)
  --show-prs    List open PRs for each repo via gh pr list
  --show-issues List open issues for each repo via gh issue list
  --show-dead-branches
                List local branches whose PRs have merged (report only)
  --check-remotes
                Report repos whose origin points at a stale slug, by asking
                GitHub for each repo's canonical owner/name (report only)
  --fix-remotes Repair what --check-remotes reports: rewrites origin's url
                and pushurl to the canonical owner/repo and refreshes a
                stale remote.origin.gh-resolved. Preserves the URL scheme,
                host alias and port; only the owner/repo segment changes.
  --status      Shorthand for --show-prs --show-issues --show-dead-branches
                --check-remotes
  --skip REPO   Exclude a repo from the walk; repeatable. REPO is either the
                directory name under the repo directory (e.g. 'scripts', or
                'nested/foo') or the owner/repo slug (e.g. 'owner/scripts').
                Matched literally — no globbing.
  --quiet, -q   Suppress per-repo detail; show only summary
  --help, -h    Show this help message and exit

Exit status: 0 when no repo failed (dirty repos are skipped, not failed),
1 when any repo failed its status check, switch, pull or branch restore,
2 on a usage error.
EOF
}

# Both --skip forms reject a missing value the same way; one definition
# keeps the two messages from drifting apart.
repo_walker__skip_requires_value() {
  echo "Error: --skip requires a value (a repo directory name or owner/repo slug)" >&2
  exit 2
}

repo_walker_parse_args() {
  REPO_WALKER_CHECK_ONLY=false
  REPO_WALKER_QUIET=false
  REPO_WALKER_SHOW_PRS=false
  REPO_WALKER_SHOW_ISSUES=false
  REPO_WALKER_SHOW_DEAD_BRANCHES=false
  REPO_WALKER_CHECK_REMOTES=false
  REPO_WALKER_FIX_REMOTES=false
  REPO_WALKER_SKIP=()

  # An index loop, not `for arg in "$@"`: --skip consumes the argument after
  # it, which a for-loop cannot do.
  local arg
  while (($# > 0)); do
    arg="$1"
    case "${arg}" in
      --help | -h)
        repo_walker_usage
        exit 0
        ;;
      --check) REPO_WALKER_CHECK_ONLY=true ;;
      --show-prs) REPO_WALKER_SHOW_PRS=true ;;
      --show-issues) REPO_WALKER_SHOW_ISSUES=true ;;
      --show-dead-branches) REPO_WALKER_SHOW_DEAD_BRANCHES=true ;;
      --check-remotes) REPO_WALKER_CHECK_REMOTES=true ;;
      # Fixing implies checking: the check is what finds the target, so
      # --fix-remotes alone must not be a silent no-op.
      --fix-remotes)
        REPO_WALKER_CHECK_REMOTES=true
        REPO_WALKER_FIX_REMOTES=true
        ;;
      # --status stays a read-only shorthand: it turns on the remote *check*
      # and never the fix, so asking for a status report cannot rewrite
      # config.
      --status)
        REPO_WALKER_SHOW_PRS=true
        REPO_WALKER_SHOW_ISSUES=true
        REPO_WALKER_SHOW_DEAD_BRANCHES=true
        REPO_WALKER_CHECK_REMOTES=true
        ;;
      # A following argument that starts with '-' is rejected rather than
      # consumed: `--skip --check` is a typo, not a request to skip a repo
      # literally named "--check", and silently eating the next flag would
      # hide it.
      --skip)
        if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
          repo_walker__skip_requires_value
        fi
        REPO_WALKER_SKIP+=("$2")
        shift
        ;;
      --skip=*)
        if [[ -z "${arg#--skip=}" ]]; then
          repo_walker__skip_requires_value
        fi
        REPO_WALKER_SKIP+=("${arg#--skip=}")
        ;;
      --quiet | -q) REPO_WALKER_QUIET=true ;;
      *)
        echo "Unknown argument: ${arg}" >&2
        exit 2
        ;;
    esac
    shift
  done

  # --show-prs/--show-issues/--show-dead-branches make network calls; honour --check's no-network
  # contract. Collect every flag --check suppresses first so multi-flag runs (e.g. --status
  # --check) get one coherent warning instead of one line per flag.
  if "${REPO_WALKER_CHECK_ONLY}"; then
    local -a suppressed=()
    "${REPO_WALKER_SHOW_PRS}" && suppressed+=("--show-prs")
    "${REPO_WALKER_SHOW_ISSUES}" && suppressed+=("--show-issues")
    "${REPO_WALKER_SHOW_DEAD_BRANCHES}" && suppressed+=("--show-dead-branches")
    # Name whichever flag the user actually typed. --fix-remotes turns on
    # CHECK_REMOTES too, so reporting "--check-remotes" for a --fix-remotes
    # run would name a flag they never used.
    if "${REPO_WALKER_FIX_REMOTES}"; then
      suppressed+=("--fix-remotes")
    elif "${REPO_WALKER_CHECK_REMOTES}"; then
      suppressed+=("--check-remotes")
    fi

    if ((${#suppressed[@]} == 1)); then
      echo "Warning: ${suppressed[0]} is ignored when --check is set (--check means no network access)" >&2
    elif ((${#suppressed[@]} > 1)); then
      local joined
      joined="$(printf '%s, ' "${suppressed[@]}")"
      joined="${joined%, }"
      echo "Warning: ${joined} are ignored when --check is set (--check means no network access)" >&2
    fi

    REPO_WALKER_SHOW_PRS=false
    REPO_WALKER_SHOW_ISSUES=false
    REPO_WALKER_SHOW_DEAD_BRANCHES=false
    REPO_WALKER_CHECK_REMOTES=false
    REPO_WALKER_FIX_REMOTES=false
  fi

  # --quiet only applies with --check, --show-prs, --show-issues, --show-dead-branches, or --check-remotes
  if "${REPO_WALKER_QUIET}" && ! "${REPO_WALKER_CHECK_ONLY}" && ! "${REPO_WALKER_SHOW_PRS}" && ! "${REPO_WALKER_SHOW_ISSUES}" && ! "${REPO_WALKER_SHOW_DEAD_BRANCHES}" && ! "${REPO_WALKER_CHECK_REMOTES}"; then
    echo "Note: --quiet has no effect without --check, --show-prs, --show-issues, --show-dead-branches, or --check-remotes" >&2
    REPO_WALKER_QUIET=false
  fi

  # --show-prs/--show-issues/--show-dead-branches require gh; jq is used to parse counts/details
  if "${REPO_WALKER_SHOW_PRS}" || "${REPO_WALKER_SHOW_ISSUES}" || "${REPO_WALKER_SHOW_DEAD_BRANCHES}"; then
    if ! command -v gh >/dev/null 2>&1; then
      echo "Error: --show-prs/--show-issues/--show-dead-branches require 'gh' (GitHub CLI) on PATH" >&2
      exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: --show-prs/--show-issues/--show-dead-branches require 'jq' on PATH" >&2
      exit 2
    fi
  fi

  # The remote check needs gh only: it reads one field via gh's own --jq, so
  # it never shells out to jq and must not demand it.
  if "${REPO_WALKER_CHECK_REMOTES}" && ! command -v gh >/dev/null 2>&1; then
    echo "Error: --check-remotes/--fix-remotes require 'gh' (GitHub CLI) on PATH" >&2
    exit 2
  fi
}

repo_walker_indent() { sed 's/^/    /'; }

# Extracts the bare host from a remote URL. Handles:
#   git@HOST:owner/repo.git       (scp-style)
#   ssh://git@HOST/owner/repo.git (ssh URL)
#   https://HOST/owner/repo.git   (https URL)
repo_walker__remote_host() {
  local remote="$1" rest
  case "${remote}" in
    ssh://* | https://* | http://*)
      rest="${remote#*://}"
      rest="${rest#*@}" # drop optional user@
      rest="${rest%%/*}"
      rest="${rest%%:*}" # drop optional :port
      echo "${rest}"
      ;;
    *@*:*)
      # scp-style: git@HOST:owner/repo.git
      rest="${remote#*@}"
      rest="${rest%%:*}"
      echo "${rest}"
      ;;
    *)
      echo "${remote}"
      ;;
  esac
}

# Resolves an SSH config host alias to its real hostname via `ssh -G`, so
# host aliases (e.g. `github-smartwatermelon` with IdentityFile-based
# identity separation) are recognized the same as a literal `github.com`.
# MUST call /usr/bin/ssh explicitly: this repo ships an ssh wrapper on PATH
# that shadows the system binary for 1Password secret injection, and
# invoking it here would be both wrong and wasteful.
#
# Only ssh-style remotes have SSH config to consult; https/http remotes use
# their literal host. If ssh -G fails or produces no hostname, falls back to
# the literal host — never worse than the pre-fix literal-substring check.
#
# REPO_WALKER_SSH_CONFIG, if set, is passed to `ssh -G -F <file>` instead of
# the user's real ~/.ssh/config. This exists solely so tests can exercise
# alias resolution against a fixture without the real ssh config; production
# code never sets it, so production behavior is unaffected.
repo_walker_github_host() {
  local remote="$1" host resolved
  host="$(repo_walker__remote_host "${remote}")"
  [[ -n "${host}" ]] || return 1

  case "${remote}" in
    https://* | http://*)
      resolved="${host}"
      ;;
    *)
      if [[ -n "${REPO_WALKER_SSH_CONFIG:-}" ]]; then
        resolved="$(/usr/bin/ssh -G -F "${REPO_WALKER_SSH_CONFIG}" "${host}" 2>/dev/null | awk '/^hostname /{print $2; exit}')" || true
      else
        resolved="$(/usr/bin/ssh -G "${host}" 2>/dev/null | awk '/^hostname /{print $2; exit}')" || true
      fi
      [[ -n "${resolved}" ]] || resolved="${host}"
      ;;
  esac

  [[ "${resolved}" == "github.com" ]]
}

repo_walker_owner_repo() {
  local remote="$1" host
  host="$(repo_walker__remote_host "${remote}")"
  sed -E "s|.*${host//./\\.}[:/]||; s|\\.git\$||" <<<"${remote}"
}

# True when a repo matches any --skip entry. Accepts either form the user
# sees: the short directory path under REPO_WALKER_DEVDIR ("scripts",
# "nested/foo") or the GitHub slug ("owner/scripts"). Comparison is a
# literal string equality, never a glob or substring — `--skip script` must
# not take out `scripts`, and `--skip 'scr*'` is a repo literally named
# "scr*", not a pattern.
#
# The slug is only computed for remotes that have one; a repo with no origin
# remote still matches on its short name.
# Asks GitHub what a slug's canonical owner/name is. GitHub keeps a redirect
# from every former name of a repo, so a remote left pointing at a
# pre-migration slug (smartwatermelon/dotfiles) still resolves, and the API
# answers with the current name (twistedmelonman/dotfiles). That redirect is
# exactly what makes this check possible; a slug equal to its own full_name
# is correctly pointed.
#
# Prints the canonical slug on success. Returns non-zero without printing
# when the lookup fails — a deleted or private-to-someone-else repo 404s, and
# a 404 must never be read as "canonical", or --fix-remotes would rewrite a
# good remote to an empty string.
repo_walker_canonical_slug() {
  local slug="$1" canon
  canon="$(gh api "repos/${slug}" --jq '.full_name' 2>/dev/null)" || return 1
  [[ -n "${canon}" && "${canon}" == */* ]] || return 1
  echo "${canon}"
}

# Swaps the owner/repo segment of a remote URL, leaving everything else byte
# for byte: scheme, user, host (including an SSH config alias), port, and the
# presence or absence of a .git suffix. Rewriting the whole URL from a
# template instead would silently convert scp-style to https, or flatten a
# `github-smartwatermelon` identity alias back to `github.com` and break the
# key selection the alias exists to provide.
repo_walker_rewrite_slug() {
  local remote="$1" new_slug="$2" old_slug prefix suffix
  old_slug="$(repo_walker_owner_repo "${remote}")"
  [[ -n "${old_slug}" ]] || return 1

  # Split on the LAST occurrence of the old slug: a host alias can legally
  # contain the owner name (git@github-smartwatermelon:smartwatermelon/x.git),
  # and replacing the first match would corrupt the host.
  suffix="${remote##*"${old_slug}"}"
  prefix="${remote%"${old_slug}${suffix}"}"
  echo "${prefix}${new_slug}${suffix}"
}

# Reports, and with --fix-remotes repairs, a repo whose configured remote
# points at a stale slug. Sets REPO_WALKER_REMOTE_STATE to one of ok,
# mispointed, fixed, failed, or skipped so the caller can count without
# re-parsing this function's human-readable output.
#
# Three settings can be stale, and url alone is not enough: a pushurl keeps
# pushes going to the old name, and remote.origin.gh-resolved (written by
# `gh repo set-default`) silently misroutes `gh pr create` even when url is
# correct.
repo_walker_check_remote() {
  local short="$1" remote="$2" repo="$3"
  local slug canon pushurl new_url new_pushurl resolved
  REPO_WALKER_REMOTE_STATE="skipped"

  if ! repo_walker_github_host "${remote}"; then
    if ! "${REPO_WALKER_QUIET}"; then
      echo "  (not a GitHub remote, skipping remote check)"
    fi
    return
  fi

  slug="$(repo_walker_owner_repo "${remote}")"

  if ! canon="$(repo_walker_canonical_slug "${slug}")"; then
    REPO_WALKER_REMOTE_STATE="failed"
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_RED}remote lookup failed${REPO_WALKER_RESET}"
    else
      echo -e "  ${REPO_WALKER_RED}✗ remote lookup failed for ${slug} (deleted, renamed away, or no access)${REPO_WALKER_RESET}"
    fi
    return
  fi

  pushurl="$(git -C "${repo}" config --get remote.origin.pushurl 2>/dev/null || true)"
  resolved="$(git -C "${repo}" config --get remote.origin.gh-resolved 2>/dev/null || true)"

  # Resolved once, on its own line, so the slug comparisons below are plain
  # string tests rather than command substitutions inside [[ ]].
  local pushurl_slug=""
  if [[ -n "${pushurl}" ]]; then
    pushurl_slug="$(repo_walker_owner_repo "${pushurl}")"
  fi

  # A pushurl is stale only when it is a former name of THIS repo: it must
  # canonicalize to the same place as origin without already being spelled
  # that way. A pushurl naming a genuinely different repo is a deliberate
  # triangular setup (fetch from upstream, push to your fork) — rewriting it
  # to canon would silently redirect pushes at upstream, so anything that
  # does not canonicalize to canon is left alone. An unresolvable pushurl is
  # also left alone: without a canonical answer there is nothing to prove it
  # is stale.
  local pushurl_stale=false pushurl_canon=""
  if [[ -n "${pushurl}" && "${pushurl_slug}" != "${canon}" ]]; then
    if pushurl_canon="$(repo_walker_canonical_slug "${pushurl_slug}")" &&
      [[ "${pushurl_canon}" == "${canon}" ]]; then
      pushurl_stale=true
    fi
  fi

  # gh-resolved is only stale when it names a specific repo. `base` is a
  # symbolic value meaning "origin itself", so it follows a corrected url
  # automatically and must not be treated as a mismatch.
  local resolved_stale=false
  if [[ -n "${resolved}" && "${resolved}" != "base" && "${resolved}" != "${canon}" ]]; then
    resolved_stale=true
  fi

  if [[ "${slug}" == "${canon}" ]] && ! "${resolved_stale}" && ! "${pushurl_stale}"; then
    REPO_WALKER_REMOTE_STATE="ok"
    if ! "${REPO_WALKER_QUIET}"; then
      echo -e "  ${REPO_WALKER_GREEN}✓ remote canonical${REPO_WALKER_RESET} (${canon})"
    fi
    return
  fi

  REPO_WALKER_REMOTE_STATE="mispointed"

  if ! "${REPO_WALKER_FIX_REMOTES}"; then
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_YELLOW}mis-pointed${REPO_WALKER_RESET} ${slug} → ${canon}"
    else
      echo -e "  ${REPO_WALKER_YELLOW}⚠ mis-pointed remote: ${slug} → ${canon}${REPO_WALKER_RESET}"
      [[ "${slug}" == "${canon}" ]] || echo "    url:         ${remote}"
      ! "${pushurl_stale}" || echo "    pushurl:     ${pushurl}"
      ! "${resolved_stale}" || echo "    gh-resolved: ${resolved} (misroutes gh pr create)"
      local self_name
      self_name="$(repo_walker_script_name)"
      echo "    fix with: ${self_name} --fix-remotes"
    fi
    return
  fi

  local fix_failed=false fix_output

  if [[ "${slug}" != "${canon}" ]]; then
    new_url="$(repo_walker_rewrite_slug "${remote}" "${canon}")"
    if fix_output="$(git -C "${repo}" remote set-url origin "${new_url}" 2>&1)"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_GREEN}✓ remote fixed${REPO_WALKER_RESET} ${slug} → ${canon}"
        echo "    url: ${new_url}"
      fi
    else
      fix_failed=true
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ failed to set origin url${REPO_WALKER_RESET}"
        echo "${fix_output}" | repo_walker_indent
      fi
    fi
  fi

  if "${pushurl_stale}"; then
    new_pushurl="$(repo_walker_rewrite_slug "${pushurl}" "${canon}")"
    if fix_output="$(git -C "${repo}" remote set-url --push origin "${new_pushurl}" 2>&1)"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo "    pushurl: ${new_pushurl}"
      fi
    else
      fix_failed=true
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ failed to set origin pushurl${REPO_WALKER_RESET}"
        echo "${fix_output}" | repo_walker_indent
      fi
    fi
  fi

  if "${resolved_stale}"; then
    if fix_output="$(git -C "${repo}" config --replace-all remote.origin.gh-resolved "${canon}" 2>&1)"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo "    gh-resolved: ${canon} (was ${resolved})"
      fi
    else
      fix_failed=true
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ failed to update gh-resolved${REPO_WALKER_RESET}"
        echo "${fix_output}" | repo_walker_indent
      fi
    fi
  fi

  if "${fix_failed}"; then
    REPO_WALKER_REMOTE_STATE="failed"
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_RED}remote fix failed${REPO_WALKER_RESET}"
    fi
  else
    REPO_WALKER_REMOTE_STATE="fixed"
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_GREEN}remote fixed${REPO_WALKER_RESET} ${slug} → ${canon}"
    fi
  fi
}

repo_walker_should_skip() {
  local short="$1" remote="$2" entry owner_repo=""

  # parse_args always sets the array, but this must not abort under set -u
  # if called before it. [*] rather than [@] keeps the test one word (SC2199).
  [[ -n "${REPO_WALKER_SKIP[*]+x}" ]] || return 1
  ((${#REPO_WALKER_SKIP[@]} > 0)) || return 1

  [[ -z "${remote}" ]] || owner_repo="$(repo_walker_owner_repo "${remote}")"

  for entry in "${REPO_WALKER_SKIP[@]}"; do
    [[ "${entry}" != "${short}" ]] || return 0
    [[ -z "${owner_repo}" || "${entry}" != "${owner_repo}" ]] || return 0
  done

  return 1
}

# Fetch and display open PRs for a repo. Honors ${REPO_WALKER_QUIET}:
#   quiet: one line  "<short>: N open PRs"
#   normal: "open PRs: N" plus per-PR details
repo_walker_show_prs() {
  local short="$1" remote="$2"
  local owner_repo pr_json pr_count

  if ! repo_walker_github_host "${remote}"; then
    if ! "${REPO_WALKER_QUIET}"; then
      echo "  (not a GitHub remote, skipping PR lookup)"
    fi
    return
  fi

  owner_repo="$(repo_walker_owner_repo "${remote}")"

  if ! pr_json="$(gh -R "${owner_repo}" pr list --state open \
    --json number,title,headRefName,isDraft,author 2>&1)"; then
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_RED}PR fetch failed${REPO_WALKER_RESET}"
    else
      echo -e "  ${REPO_WALKER_RED}✗ PR fetch failed${REPO_WALKER_RESET}"
      echo "${pr_json}" | repo_walker_indent
    fi
    return
  fi

  pr_count="$(jq 'length' <<<"${pr_json}")"

  if "${REPO_WALKER_QUIET}"; then
    if ((pr_count == 1)); then
      echo "  ${short}: ${pr_count} open PR"
    else
      echo "  ${short}: ${pr_count} open PRs"
    fi
  else
    echo -e "  open PRs: ${pr_count}"
    if ((pr_count > 0)); then
      jq -r '.[] | "    #\(.number)  \(.title)  [\(.headRefName)] by \(.author.login // "unknown")\(if .isDraft then " (draft)" else "" end)"' <<<"${pr_json}"
    fi
  fi
}

repo_walker_show_issues() {
  local short="$1" remote="$2"
  local owner_repo issue_json issue_count

  if ! repo_walker_github_host "${remote}"; then
    if ! "${REPO_WALKER_QUIET}"; then
      echo "  (not a GitHub remote, skipping issue lookup)"
    fi
    return
  fi

  owner_repo="$(repo_walker_owner_repo "${remote}")"

  if ! issue_json="$(gh -R "${owner_repo}" issue list --state open \
    --json number,title,labels,author 2>&1)"; then
    if "${REPO_WALKER_QUIET}"; then
      echo -e "  ${short}: ${REPO_WALKER_RED}issue fetch failed${REPO_WALKER_RESET}"
    else
      echo -e "  ${REPO_WALKER_RED}✗ issue fetch failed${REPO_WALKER_RESET}"
      echo "${issue_json}" | repo_walker_indent
    fi
    return
  fi

  issue_count="$(jq 'length' <<<"${issue_json}")"

  if "${REPO_WALKER_QUIET}"; then
    if ((issue_count == 1)); then
      echo "  ${short}: ${issue_count} open issue"
    else
      echo "  ${short}: ${issue_count} open issues"
    fi
  else
    echo -e "  open issues: ${issue_count}"
    if ((issue_count > 0)); then
      jq -r '.[] | "    #\(.number)  \(.title)"
        + (if (.labels | length) > 0 then "  [\([.labels[].name] | join(","))]" else "" end)
        + "  by \(.author.login // "unknown")"' <<<"${issue_json}"
    fi
  fi
}

# Must never abort on a missing origin/HEAD, regardless of whether the
# caller invokes this inside command substitution (which would otherwise
# mask a `set -e` abort) or bare. The `|| true` guarantees the symbolic-ref
# failure cannot propagate, so the fallback below genuinely runs. "main" is
# the intended fallback when origin/HEAD cannot be resolved.
repo_walker_default_branch() {
  local repo="$1" branch ref
  ref="$(git -C "${repo}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || true
  branch="$(sed 's|refs/remotes/origin/||' <<<"${ref}")"
  [[ -n "${branch}" ]] || branch="main"
  echo "${branch}"
}

# Signal 1: every commit on <branch> has an equivalent already upstream.
# `git cherry` prefixes such commits with '-' and unique ones with '+'.
# Empty cherry output means there are no commits on <branch> relative to
# <default> to compare at all, not that they're all equivalent — treat
# that as "not dead" (the safe direction) rather than special-casing it
# into a false positive.
repo_walker_branch_upstream() {
  local repo="$1" default="$2" branch="$3" cherry
  cherry="$(git -C "${repo}" cherry "${default}" "${branch}" 2>/dev/null)" || return 1
  [[ -n "${cherry}" ]] || return 1
  ! grep -q '^+' <<<"${cherry}"
}

repo_walker_show_dead_branches() {
  local short="$1" remote="$2" repo="$3"
  local owner_repo default current branch pr_json pr_num merged_at
  local base changed differing
  local -a dead=() suspect=() unpushed=()
  local -r sep=$'\x1f'
  local failed_lookups=0

  if ! repo_walker_github_host "${remote}"; then
    if ! "${REPO_WALKER_QUIET}"; then
      echo "  (not a GitHub remote, skipping dead-branch lookup)"
    fi
    return
  fi

  owner_repo="$(repo_walker_owner_repo "${remote}")"
  default="$(repo_walker_default_branch "${repo}")"
  current="$(git -C "${repo}" branch --show-current 2>/dev/null || true)"

  while IFS= read -r branch; do
    [[ -n "${branch}" ]] || continue
    [[ "${branch}" != "${default}" ]] || continue
    [[ "${branch}" != "${current}" ]] || continue

    local sha
    sha="$(git -C "${repo}" rev-parse --short "${branch}" 2>/dev/null || echo "?")"

    # Signal 1 — offline, conclusive when it fires.
    if repo_walker_branch_upstream "${repo}" "${default}" "${branch}"; then
      dead+=("${branch}${sep}${sha}${sep}cherry-equivalent")
      continue
    fi

    # Signal 2 — squash merges are invisible to signal 1. stderr is
    # discarded (2>/dev/null) so SSO/auth notices or other stderr chatter
    # cannot poison the JSON parse below when gh exits 0. On a non-zero
    # exit we have no captured stderr to show, so report the exit alone.
    if ! pr_json="$(gh -R "${owner_repo}" pr list --state merged --head "${branch}" \
      --json number,mergedAt,title 2>/dev/null)"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ merged-PR lookup failed for ${branch}${REPO_WALKER_RESET}"
      fi
      ((failed_lookups += 1))
      continue
    fi

    # gh can exit 0 while writing a non-JSON message to stdout (SSO/auth
    # notices, "could not resolve to a Repository"). Guard every jq
    # extraction: `local x` on its own line makes `x="$(cmd)"` a bare
    # command that set -e will kill on failure, and `[[ "" -eq 0 ]]` (and
    # `[[ non-numeric -eq 0 ]]`) are both true in bash, so an unguarded
    # count would silently misclassify a failed lookup as "no PR — unpushed
    # work". Validate with a numeric regex before any arithmetic; treat
    # anything that doesn't match as a distinct, reported failure rather
    # than a 0.
    local pr_count
    if ! pr_count="$(jq 'length' <<<"${pr_json}" 2>/dev/null)" || [[ ! "${pr_count}" =~ ^[0-9]+$ ]]; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ merged-PR lookup for ${branch} returned unparseable output${REPO_WALKER_RESET}"
      fi
      ((failed_lookups += 1))
      continue
    fi

    if ((pr_count == 0)); then
      unpushed+=("${branch}${sep}${sha}")
      continue
    fi

    local pr_num_raw merged_at_raw
    if ! pr_num_raw="$(jq -r '.[0].number' <<<"${pr_json}" 2>/dev/null)" || [[ ! "${pr_num_raw}" =~ ^[0-9]+$ ]]; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ merged-PR lookup for ${branch} returned unparseable output${REPO_WALKER_RESET}"
      fi
      ((failed_lookups += 1))
      continue
    fi
    pr_num="${pr_num_raw}"

    if ! merged_at_raw="$(jq -r '.[0].mergedAt' <<<"${pr_json}" 2>/dev/null)" || [[ -z "${merged_at_raw}" || "${merged_at_raw}" == "null" ]]; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ merged-PR lookup for ${branch} returned unparseable output${REPO_WALKER_RESET}"
      fi
      ((failed_lookups += 1))
      continue
    fi
    merged_at="$(cut -d'T' -f1 <<<"${merged_at_raw}")"

    # Signal 3 — a merged PR does not prove the branch holds no extra work.
    base="$(git -C "${repo}" merge-base "${default}" "${branch}" 2>/dev/null || true)"
    differing=""
    if [[ -n "${base}" ]]; then
      while IFS= read -r changed; do
        [[ -n "${changed}" ]] || continue
        if ! git -C "${repo}" diff --quiet "${default}" "${branch}" -- "${changed}" 2>/dev/null; then
          differing+="${changed} "
        fi
      done < <(git -C "${repo}" diff --name-only "${base}" "${branch}" 2>/dev/null || true)
    fi

    if [[ -n "${differing}" ]]; then
      suspect+=("${branch}${sep}${sha}${sep}${pr_num}${sep}${merged_at}${sep}${differing}")
    else
      dead+=("${branch}${sep}${sha}${sep}PR #${pr_num}, merged ${merged_at}")
    fi
  done < <(git -C "${repo}" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)

  if "${REPO_WALKER_QUIET}"; then
    local -a parts=()
    if ((${#dead[@]} > 0)); then
      if ((${#dead[@]} == 1)); then
        parts+=("${#dead[@]} dead branch")
      else
        parts+=("${#dead[@]} dead branches")
      fi
    fi
    if ((${#suspect[@]} > 0)); then
      parts+=("${#suspect[@]} suspect")
    fi
    if ((${#unpushed[@]} > 0)); then
      parts+=("${#unpushed[@]} unpushed")
    fi
    if ((failed_lookups > 0)); then
      parts+=("${failed_lookups} lookup failed")
    fi
    if ((${#parts[@]} == 0)); then
      echo "  ${short}: 0 dead branches"
    else
      local joined
      joined="$(printf '%s, ' "${parts[@]}")"
      joined="${joined%, }"
      echo "  ${short}: ${joined}"
    fi
    return
  fi

  echo -e "  dead branches: ${#dead[@]}"
  local entry
  for entry in "${dead[@]}"; do
    IFS="${sep}" read -r branch sha why <<<"${entry}"
    echo "    git -C ${repo} branch -D ${branch}    # ${why} (tip ${sha})"
  done
  for entry in "${suspect[@]}"; do
    IFS="${sep}" read -r branch sha pr_num merged_at differing <<<"${entry}"
    echo -e "    ${REPO_WALKER_YELLOW}? ${branch}${REPO_WALKER_RESET} (tip ${sha}) PR #${pr_num} merged ${merged_at}, but files differ:"
    echo "        ${differing}"
  done
  for entry in "${unpushed[@]}"; do
    IFS="${sep}" read -r branch sha <<<"${entry}"
    echo -e "    ${REPO_WALKER_CYAN}↑ ${branch}${REPO_WALKER_RESET} (tip ${sha}) no PR — unpushed work"
  done
}

repo_walker_run_reports() {
  local short="$1" remote="$2" repo="$3"
  if "${REPO_WALKER_SHOW_PRS}"; then
    repo_walker_show_prs "${short}" "${remote}"
  fi
  if "${REPO_WALKER_SHOW_ISSUES}"; then
    repo_walker_show_issues "${short}" "${remote}"
  fi
  if "${REPO_WALKER_SHOW_DEAD_BRANCHES}"; then
    repo_walker_show_dead_branches "${short}" "${remote}" "${repo}"
  fi
}

repo_walker_main() {
  repo_walker_require_config
  repo_walker_parse_args "$@"

  if ! repo_walker_check_devdir; then
    return 0
  fi

  local pulled=0
  local clean=0
  local skipped=0
  local failed=0
  local total=0
  # Distinct from ${skipped}, which counts repos walked but left alone
  # because their tree was dirty. This counts repos --skip excluded before
  # the walk touched them at all.
  local excluded=0
  local mispointed=0
  local remotes_fixed=0
  local remote_failed=0
  local skipped_list=()
  local failed_list=()
  local mispointed_list=()
  local gitdir repo remote short status

  while IFS= read -r gitdir; do
    repo="$(dirname "${gitdir}")"
    remote="$(git -C "${repo}" remote get-url origin 2>/dev/null || true)"

    # Filter to our orgs only
    if ! grep -qE "${REPO_WALKER_ORGS}" <<<"${remote}"; then
      continue
    fi

    short="${repo#"${REPO_WALKER_DEVDIR}"/}"

    # --skip excludes a repo entirely: no output, no reports, and no
    # contribution to ${total}. A skipped repo was never walked, so counting
    # it would make the summary claim work that did not happen.
    if repo_walker_should_skip "${short}" "${remote}"; then
      ((excluded += 1))
      continue
    fi

    ((total += 1))

    if ! "${REPO_WALKER_QUIET}"; then
      echo ""
      echo -e "${REPO_WALKER_CYAN}━━━ ${short} ━━━${REPO_WALKER_RESET}"
      echo -e "  remote: ${remote}"
    fi

    # Runs before the dirty-tree branch below, and before any pull: rewriting
    # a remote URL touches only .git/config, never the worktree, so a dirty
    # repo can still be repaired. Doing it first also means a repo whose
    # remote was stale gets pulled from the corrected URL on this same run
    # instead of needing a second pass.
    if "${REPO_WALKER_CHECK_REMOTES}"; then
      repo_walker_check_remote "${short}" "${remote}" "${repo}"
      case "${REPO_WALKER_REMOTE_STATE}" in
        mispointed)
          ((mispointed += 1))
          mispointed_list+=("${short}")
          ;;
        fixed)
          ((remotes_fixed += 1))
          # A corrected URL is the one the pull below must use.
          remote="$(git -C "${repo}" remote get-url origin 2>/dev/null || echo "${remote}")"
          ;;
        failed) ((remote_failed += 1)) ;;
        *) ;;
      esac
    fi

    # Check for uncommitted changes
    if ! status="$(git -C "${repo}" status --porcelain 2>/dev/null)"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_RED}✗ status check failed${REPO_WALKER_RESET}"
        git -C "${repo}" status --porcelain 2>&1 | repo_walker_indent || true
      fi
      failed_list+=("${short}")
      ((failed += 1))
      repo_walker_run_reports "${short}" "${remote}" "${repo}"
      continue
    fi

    if [[ -n "${status}" ]]; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_YELLOW}⚠ dirty working tree${REPO_WALKER_RESET}"
        echo "${status}" | repo_walker_indent
      fi
      skipped_list+=("${short}")
      ((skipped += 1))
    elif "${REPO_WALKER_CHECK_ONLY}"; then
      if ! "${REPO_WALKER_QUIET}"; then
        echo -e "  ${REPO_WALKER_GREEN}✓ clean${REPO_WALKER_RESET}"
      fi
      ((clean += 1))
    else
      # Determine default branch and switch to it before pulling
      local default_branch current_branch switched switch_output
      default_branch="$(repo_walker_default_branch "${repo}")"

      current_branch="$(git -C "${repo}" branch --show-current 2>/dev/null || true)"
      switched=false
      if [[ "${current_branch}" != "${default_branch}" ]]; then
        if ! switch_output="$(git -C "${repo}" switch "${default_branch}" 2>&1)"; then
          if ! "${REPO_WALKER_QUIET}"; then
            echo -e "  ${REPO_WALKER_RED}✗ switch to ${default_branch} failed${REPO_WALKER_RESET}"
            echo "${switch_output}" | repo_walker_indent
          fi
          failed_list+=("${short}")
          ((failed += 1))
          repo_walker_run_reports "${short}" "${remote}" "${repo}"
          continue
        fi
        if ! "${REPO_WALKER_QUIET}"; then
          echo -e "  ${REPO_WALKER_YELLOW}↳ switched to ${default_branch} (was ${current_branch})${REPO_WALKER_RESET}"
        fi
        switched=true
      fi

      # Clean tree — attempt pull. --force lets a moved upstream tag
      # overwrite ours; --ff-only still guards the branch.
      local pull_ok pull_output
      pull_ok=true
      if pull_output="$(git -C "${repo}" pull --ff-only --force 2>&1)"; then
        if ! "${REPO_WALKER_QUIET}"; then
          if grep -q "Already up to date" <<<"${pull_output}"; then
            echo -e "  ${REPO_WALKER_GREEN}✓ up to date${REPO_WALKER_RESET}"
          else
            echo -e "  ${REPO_WALKER_GREEN}✓ pulled${REPO_WALKER_RESET}"
            echo "${pull_output}" | repo_walker_indent
          fi
        fi
      else
        if ! "${REPO_WALKER_QUIET}"; then
          echo -e "  ${REPO_WALKER_RED}✗ pull failed${REPO_WALKER_RESET}"
          echo "${pull_output}" | repo_walker_indent
        fi
        pull_ok=false
      fi

      # Restore original branch if we switched away
      local restore_ok restore_output
      restore_ok=true
      if "${switched}"; then
        if ! restore_output="$(git -C "${repo}" switch "${current_branch}" 2>&1)"; then
          if ! "${REPO_WALKER_QUIET}"; then
            if "${pull_ok}"; then
              echo -e "  ${REPO_WALKER_RED}✗ pulled but failed to restore branch ${current_branch}${REPO_WALKER_RESET}"
            else
              echo -e "  ${REPO_WALKER_RED}✗ failed to restore branch ${current_branch}${REPO_WALKER_RESET}"
            fi
            echo "${restore_output}" | repo_walker_indent
          fi
          restore_ok=false
        fi
      fi

      if "${pull_ok}" && "${restore_ok}"; then
        ((pulled += 1))
      else
        failed_list+=("${short}")
        ((failed += 1))
      fi
    fi

    repo_walker_run_reports "${short}" "${remote}" "${repo}"

  done < <(find -L "${REPO_WALKER_DEVDIR}" -maxdepth 3 -name .git -type d 2>/dev/null | sort || true)

  # Blaming the org filter when --skip is what emptied the walk would send
  # the user to fix the wrong thing, so report whichever actually applies.
  if ((total == 0)); then
    if ((excluded > 0)); then
      echo "Warning: --skip excluded every repo that matched '${REPO_WALKER_ORGS}' under ${REPO_WALKER_DEVDIR}" >&2
      echo "         ${excluded} repo(s) skipped; nothing left to do." >&2
    else
      echo "Warning: no repos matched '${REPO_WALKER_ORGS}' under ${REPO_WALKER_DEVDIR}" >&2
      echo "         set ${REPO_WALKER_DIRVAR} if the path is wrong." >&2
    fi
  fi

  echo ""
  echo -e "${REPO_WALKER_CYAN}━━━ Summary ━━━${REPO_WALKER_RESET}"
  if "${REPO_WALKER_CHECK_ONLY}"; then
    echo -e "  Total: ${total}  ${REPO_WALKER_GREEN}Clean: ${clean}${REPO_WALKER_RESET}  ${REPO_WALKER_YELLOW}Dirty: ${skipped}${REPO_WALKER_RESET}  ${REPO_WALKER_RED}Failed: ${failed}${REPO_WALKER_RESET}"
  else
    echo -e "  Total: ${total}  ${REPO_WALKER_GREEN}Pulled: ${pulled}${REPO_WALKER_RESET}  ${REPO_WALKER_YELLOW}Skipped: ${skipped}${REPO_WALKER_RESET}  ${REPO_WALKER_RED}Failed: ${failed}${REPO_WALKER_RESET}"
  fi

  if "${REPO_WALKER_CHECK_REMOTES}"; then
    echo -e "  Remotes: ${REPO_WALKER_YELLOW}Mis-pointed: ${mispointed}${REPO_WALKER_RESET}  ${REPO_WALKER_GREEN}Fixed: ${remotes_fixed}${REPO_WALKER_RESET}  ${REPO_WALKER_RED}Lookup failed: ${remote_failed}${REPO_WALKER_RESET}"
  fi

  if ((mispointed > 0)); then
    echo -e "\n  ${REPO_WALKER_YELLOW}Mis-pointed remotes:${REPO_WALKER_RESET}"
    local m
    for m in "${mispointed_list[@]}"; do
      echo "    - ${m}"
    done
    echo -e "\n  Re-run with --fix-remotes to repair these."
  fi

  if ((skipped > 0)); then
    echo -e "\n  ${REPO_WALKER_YELLOW}Skipped (dirty):${REPO_WALKER_RESET}"
    for s in "${skipped_list[@]}"; do
      echo "    - ${s}"
    done
  fi

  if ((failed > 0)); then
    echo -e "\n  ${REPO_WALKER_RED}Failed:${REPO_WALKER_RESET}"
    for f in "${failed_list[@]}"; do
      echo "    - ${f}"
    done
  fi

  # allup reads this status. An if, not `&&`: that returns 1 on success.
  if ((failed > 0)); then
    return 1
  fi
  return 0
}
