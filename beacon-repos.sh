#!/usr/bin/env bash
set -euo pipefail

# beacon-repos.sh — For each repo in ~/Developer/beacon-biosignals owned by
# beacon-biosignals: show status, pull if clean.
#
# Configuration only; all logic lives in lib/repo-walker.sh.
# Override the directory with BEACON_REPOS_DIR.

REPO_WALKER_DEVDIR="${BEACON_REPOS_DIR:-${HOME}/Developer/beacon-biosignals}"
REPO_WALKER_ORGS="beacon-biosignals"
REPO_WALKER_DESC="Pull all repos in ~/Developer/beacon-biosignals owned by beacon-biosignals."
REPO_WALKER_DIRVAR="BEACON_REPOS_DIR"

SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SELF_PATH}")" && pwd)"
# shellcheck source=lib/repo-walker.sh
source "${SCRIPT_DIR}/lib/repo-walker.sh"

repo_walker_main "$@"
