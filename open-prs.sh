#!/usr/bin/env bash
# open-prs.sh — one line per repo, listing every open PR across your orgs.
#
# Filters (pick at most one):
#   --mine       hide dependabot/bot PRs
#   --bots       only dependabot/bot PRs
#
# Renderers (pick at most one):
#   --count      one line per repo, counts only
#   --urls       include the URL for each PR
#
# Filters and renderers compose: `--mine --count` counts only your own PRs.
#
#   --limit N    cap results (default 200, max 1000 -- gh's own ceiling)
#
# Why `gh search prs` and not `gh repo list`:
#   `gh repo list --json pullRequests` gives you only a totalCount -- there is
#   no way to reach the PR titles or numbers through it. It also defaults to
#   the authenticated user's own repos, so org repos are silently missing
#   unless you name the org. `gh search prs --owner X --owner Y` covers every
#   owner in a single API call and returns real PR fields.
set -euo pipefail
unset CDPATH

# Add or remove owners here.
OWNERS=(smartwatermelon nightowlstudiollc)

DEFAULT_LIMIT=200

# gh search itself rejects anything outside 1-1000. Validating here means a bad
# value fails with our message before we spend an API call on it.
MAX_LIMIT=1000

# Print the usage block: every comment line from line 2 up to the first line
# that is not a comment. Sentinel-based rather than a hardcoded range, so
# adding a flag or a paragraph here cannot truncate or over-print the help.
function usage() {
  sed -n '2,/^[^#]/{ /^[^#]/d; p; }' "$0"
}

# Filter and render are independent choices, tracked separately so they
# compose. Each rejects a second flag of its own kind rather than silently
# taking the last one.
filter_mode=""
render_mode=""
limit="${DEFAULT_LIMIT}"

function set_filter() {
  if [[ -n "${filter_mode}" && "${filter_mode}" != "$1" ]]; then
    echo "cannot combine --${filter_mode} and --$1" >&2
    exit 1
  fi
  filter_mode="$1"
}

function set_render() {
  if [[ -n "${render_mode}" && "${render_mode}" != "$1" ]]; then
    echo "cannot combine --${render_mode} and --$1" >&2
    exit 1
  fi
  render_mode="$1"
}

while (($# > 0)); do
  case "$1" in
    --mine) set_filter mine ;;
    --bots) set_filter bots ;;
    --count) set_render count ;;
    --urls) set_render urls ;;
    --limit)
      # Consume the value here; the loop's trailing shift handles the flag.
      if (($# < 2)); then
        echo "--limit needs a number" >&2
        exit 1
      fi
      if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "--limit needs a positive integer, got: $2" >&2
        exit 1
      fi
      if (($2 > MAX_LIMIT)); then
        echo "--limit cannot exceed ${MAX_LIMIT} (gh's own ceiling), got: $2" >&2
        exit 1
      fi
      limit="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 1
      ;;
  esac
  shift
done

owner_args=()
for o in "${OWNERS[@]}"; do
  owner_args+=(--owner "${o}")
done

# A bot PR is either flagged is_bot by the API or has a dependabot-shaped
# login. Checking both because app-authored PRs are not consistently flagged.
is_bot='(.author.is_bot or (.author.login | test("dependabot|renovate|\\[bot\\]$")))'

case "${filter_mode}" in
  mine) filter="map(select(${is_bot} | not))" ;;
  bots) filter="map(select(${is_bot}))" ;;
  *) filter="." ;;
esac

case "${render_mode}" in
  count)
    render='map("\(.[0].repository.nameWithOwner): \(length)")'
    ;;
  urls)
    render='map("\(.[0].repository.nameWithOwner):\n" + (map("  #\(.number) \(.title)\n    \(.url)") | join("\n")))'
    ;;
  *)
    render='map("\(.[0].repository.nameWithOwner): " + (map("#\(.number) \(.title)") | join(" | ")))'
    ;;
esac

# --archived=false MUST use the equals form. `--archived false` parses as a
# standalone boolean followed by a stray search term "false", which matches
# nothing and exits 0 -- a silent empty result, not an error.
#
# A full result set is indistinguishable from a truncated one -- both just
# return `limit` rows -- so warn when we come back at the ceiling rather than
# let a silently-short list read as the full picture.
#
# `>=` is deliberate and must stay. Exactly `limit` results warns even when
# nothing was dropped; that false positive is the price of catching every
# real truncation. Changing this to `>` would make the warning unreachable,
# because the count can never exceed the limit gh was given.
raw="$(
  gh search prs \
    --state open \
    --archived=false \
    "${owner_args[@]}" \
    --limit "${limit}" \
    --json repository,number,title,author,url
)"

total="$(printf '%s' "${raw}" | jq 'length')"
if ((total >= limit)); then
  printf 'warning: hit the --limit ceiling of %s; results may be truncated. Re-run with a larger --limit.\n' \
    "${limit}" >&2
fi

printf '%s' "${raw}" | jq -r "${filter}
  | group_by(.repository.nameWithOwner)
  | ${render}
  | .[]"
