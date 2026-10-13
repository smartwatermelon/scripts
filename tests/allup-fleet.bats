#!/usr/bin/env bats
# bats tests for allup-fleet.sh
#
# Run from repo root:  bats tests/allup-fleet.bats
#
# tmux and local-macs are stubbed: the tmux stub logs each call (one argument
# per line, calls separated by "--") and answers -P queries with fake ids.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${REPO_ROOT}/allup-fleet.sh"
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  TMUX_LOG="${BATS_TEST_TMPDIR}/tmux.log"
  mkdir -p "${STUB_DIR}"
  export TMUX_LOG

  cat >"${STUB_DIR}/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" "--" >>"${TMUX_LOG}"
case "$1" in
  has-session) exit "${STUB_HAS_SESSION:-1}" ;;
  new-session | new-window) echo "@7" ;;
  split-window) echo "%9" ;;
esac
STUB
  chmod +x "${STUB_DIR}/tmux"

  export LOCAL_MACS="${STUB_DIR}/local-macs"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" alpha beta\n' >"${LOCAL_MACS}"
  chmod +x "${LOCAL_MACS}"

  export PATH="${STUB_DIR}:${PATH}"
  unset TMUX
}

@test "each host gets its own pane running ssh -t into bash -lic allup" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qxF 'ssh -t alpha.local bash\ -lic\ allup' "${TMUX_LOG}"
  grep -qxF 'ssh -t beta.local bash\ -lic\ allup' "${TMUX_LOG}"
  [ "$(grep -cx 'split-window' "${TMUX_LOG}")" -eq 1 ]
}

@test "remain-on-exit is set before the first ssh starts" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  remain_line="$(grep -nx 'remain-on-exit' "${TMUX_LOG}" | cut -d: -f1)"
  ssh_line="$(grep -n '^ssh -t ' "${TMUX_LOG}" | head -1 | cut -d: -f1)"
  [ "${remain_line}" -lt "${ssh_line}" ]
}

@test "panes are labelled with their host" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx 'alpha' "${TMUX_LOG}"
  grep -qx 'beta' "${TMUX_LOG}"
}

@test "a custom command replaces allup and is quoted for the remote shell" {
  run "${SCRIPT}" 'hostname; uptime'
  [ "${status}" -eq 0 ]
  grep -qxF "ssh -t alpha.local bash\\ -lic\\ hostname\\\\\\;\\\\\\ uptime" "${TMUX_LOG}"
}

@test "outside tmux it creates a session and attaches" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx 'new-session' "${TMUX_LOG}"
  grep -qx 'attach-session' "${TMUX_LOG}"
}

@test "outside tmux it attaches to the allup-fleet session by exact name" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -A2 -x 'attach-session' "${TMUX_LOG}" | grep -qx '=allup-fleet'
}

@test "a failing local-macs exits 1 with a message and no tmux calls" {
  printf '#!/usr/bin/env bash\nexit 3\n' >"${LOCAL_MACS}"
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"local-macs failed"* ]]
  [ ! -e "${TMUX_LOG}" ]
}

@test "inside tmux it adds a window instead of nesting a session" {
  TMUX=/tmp/fake,1,0 run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx 'new-window' "${TMUX_LOG}"
  grep -qx 'select-window' "${TMUX_LOG}"
  ! grep -qx 'new-session' "${TMUX_LOG}"
}

@test "-d starts the panes without attaching" {
  run "${SCRIPT}" -d
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"started 2 hosts"* ]]
  ! grep -qx 'attach-session' "${TMUX_LOG}"
}

@test "an existing allup-fleet session is not clobbered" {
  STUB_HAS_SESSION=0 run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists"* ]]
  ! grep -qx 'new-session' "${TMUX_LOG}"
}

@test "no hosts found exits 1 without touching tmux" {
  printf '#!/usr/bin/env bash\n' >"${LOCAL_MACS}"
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"found no hosts"* ]]
  [ ! -e "${TMUX_LOG}" ]
}
