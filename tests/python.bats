#!/usr/bin/env bats
# bats tests for the `python` -> python3 passthru shim
#
# Run from repo root:  bats tests/python.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${REPO_ROOT}/python"
}

@test "regression: an argument containing spaces is passed as ONE argument" {
  # With the pre-fix `command python3 $@`, word splitting broke `-c 'import
  # sys; ...'` into fragments and python3 died with a SyntaxError.
  run "${SCRIPT}" -c 'import sys; print(len(sys.argv), sys.argv[1])' "a b"
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "2 a b" ]
}

@test "regression: exit status from python3 reaches the caller" {
  # Pre-fix this reported 1 (the SyntaxError) instead of the real code.
  run "${SCRIPT}" -c 'import sys; sys.exit(3)'
  [ "${status}" -eq 3 ]
}

@test "a glob-looking argument is not expanded by the shim" {
  run "${SCRIPT}" -c 'import sys; print(sys.argv[1])' '*'
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "*" ]
}

@test "an empty-string argument is preserved" {
  run "${SCRIPT}" -c 'import sys; print(len(sys.argv))' ""
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "2" ]
}

@test "stdin is passed through" {
  run bash -c "echo 'print(1+1)' | '${SCRIPT}' -"
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "2" ]
}

@test "it really invokes python3" {
  run "${SCRIPT}" -c 'import sys; print(sys.version_info[0])'
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "3" ]
}
