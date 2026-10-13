#!/usr/bin/env bats
# bats tests for stringprefix.sh
#
# Run from repo root:  bats tests/stringprefix.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${REPO_ROOT}/stringprefix.sh"
}

@test "regression: abc axc yields contiguous prefix 'a', not non-contiguous 'ac'" {
  run "${SCRIPT}" abc axc
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "the longest match is: a" ]
}

@test "same bug class: first character differs, later ones coincidentally match" {
  run "${SCRIPT}" xbc abc
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"the longest match is: " ]]
  [[ "${output}" != *"the longest match is: bc" ]]
}

@test "default no-argument set yields documented example 'ancho'" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "the longest match is: ancho" ]
}

@test "hello help yields 'hel'" {
  run "${SCRIPT}" hello help
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "the longest match is: hel" ]
}

@test "prefix preflight yields 'pref'" {
  run "${SCRIPT}" prefix preflight
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "the longest match is: pref" ]
}

@test "abc xyz yields empty match" {
  run "${SCRIPT}" abc xyz
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"the longest match is: " ]]
}

@test "identical strings abc abc yield 'abc'" {
  run "${SCRIPT}" abc abc
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "the longest match is: abc" ]
}

@test "single-argument usage error exits 1 with syntax message" {
  run "${SCRIPT}" abc
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"syntax:"* ]]
  [[ "${output}" == *"at least two words, or no words for the default set"* ]]
}

@test "three explicit arguments exercise the pairwise loop" {
  # flowchart/flower share "flow"; flour diverges at index 3.
  # Covers the $# -gt 1 array rebuild with more than two elements.
  run "${SCRIPT}" flowchart flower flour
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = "the longest match is: flow" ]
}
