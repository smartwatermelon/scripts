#!/usr/bin/env bash
set -euo pipefail

# my-repos.sh — For each repo in ~/Developer owned by smartwatermelon,
# nightowlstudiollc or twistedmelonman: show status, pull if clean.
#
# Configuration only; all logic lives in lib/repo-walker.sh.
# Override the directory with MY_REPOS_DIR.
#
# twistedmelonman is the personal account after the 2026-09 org migration
# (smartwatermelon became the org). Without it here, repos already moved to
# the personal account fall outside the walk entirely, and --fix-remotes
# would drop a repo from future walks the moment it corrected one.

REPO_WALKER_DEVDIR="${MY_REPOS_DIR:-${HOME}/Developer}"
REPO_WALKER_ORGS="smartwatermelon|nightowlstudiollc|twistedmelonman"
REPO_WALKER_DESC="Pull all repos in ~/Developer owned by smartwatermelon, nightowlstudiollc or twistedmelonman."
REPO_WALKER_DIRVAR="MY_REPOS_DIR"

SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SELF_PATH}")" && pwd)"
# shellcheck source=lib/repo-walker.sh
source "${SCRIPT_DIR}/lib/repo-walker.sh"

repo_walker_main "$@"
