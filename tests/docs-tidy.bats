#!/usr/bin/env bats
# bats tests for docs-tidy.py (plan / show / apply) against fixture trees.
#
# Run from repo root:  bats tests/docs-tidy.bats
#
# Every env override is set in setup(), so no test can fall back to the real
# ~/Documents, Drive mount, DriveFS DB or state dir. A test that needs a
# different date passes DOCS_TIDY_TODAY per command (`run env ...`).

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:?must be run via bats}")/.." && pwd)"
  SCRIPT="${REPO_ROOT}/docs-tidy.py"
  DOC="${BATS_TEST_TMPDIR:?}/Documents"
  DRIVE="${BATS_TEST_TMPDIR:?}/My Drive"
  STATE="${BATS_TEST_TMPDIR:?}/state"
  PLAN="${STATE}/plan-2026-10-21.json"
  STASH="${DRIVE}/probably-dupes/2026-10-21"
  ARCHIVE="${DRIVE}/Documents Archive"
  mkdir -p "${DOC}" "${DRIVE}"
  export DOCS_TIDY_DOC="${DOC}"
  export DOCS_TIDY_DRIVE="${DRIVE}"
  export DOCS_TIDY_STATE="${STATE}"
  export DOCS_TIDY_DRIVEFS=none
  export DOCS_TIDY_TODAY=2026-10-21
}

# Restore permissions that a test removed (chmod 000 / 555), so bats can
# clean up its temp dir.
teardown() {
  chmod -R u+rwx "${BATS_TEST_TMPDIR:?}"
}

# is_mac: true on macOS, where Finder tags and osascript exist.
is_mac() {
  [[ "${OSTYPE}" == darwin* ]]
}

# settags FILE TAG...: write Finder tags (macOS only).
settags() {
  local file="$1" hex
  shift
  hex="$(python3 -I -c 'import plistlib, sys; print(plistlib.dumps(sys.argv[1:], fmt=plistlib.FMT_BINARY).hex())' "$@")"
  xattr -wx com.apple.metadata:_kMDItemUserTags "${hex}" "${file}"
}

# want_tags FILE EXPECTED: the file's Finder tags as a Python list repr.
want_tags() {
  local hex got
  hex="$(xattr -px com.apple.metadata:_kMDItemUserTags "$1")"
  got="$(python3 -I -c 'import plistlib, sys; print(plistlib.loads(bytes.fromhex("".join(sys.argv[1].split()))))' "${hex}")"
  if [ "${got}" != "$2" ]; then
    printf 'tags: %s\n got: %s\nwant: %s\n' "$1" "${got}" "$2" >&2
    return 1
  fi
}

# mk PATH STAMP [CONTENT]: create a file under DOC with an mtime of STAMP
# (touch -t format, CCYYMMDDhhmm).
mk() {
  local path="${DOC}/$1" stamp="$2" content="${3:-content of $1}"
  mkdir -p "${path%/*}"
  printf '%s' "${content}" >"${path}"
  touch -t "${stamp}" "${path}"
}

# mkbig PATH STAMP CHAR: like mk, with 2 KiB of CHAR as the content, enough
# to pass the 1 KiB dupe threshold.
mkbig() {
  local pad
  pad="$(printf '%2048s' '')"
  mk "$1" "$2" "${pad// /$3}"
}

# mksock DIR NAME: create a Unix socket. Bind a relative name after cd, since
# macOS caps socket paths at 104 bytes and BATS_TEST_TMPDIR is long there.
mksock() {
  (cd "${DOC}/$1" && python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$2")
}

# want_in PLANFILE EXPR EXPECTED: EXPR (Python, plan bound to `p`) must
# print EXPECTED.
want_in() {
  local got
  got="$(python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2")"
  if [ "${got}" != "$3" ]; then
    printf 'expr: %s\n got: %s\nwant: %s\n' "$2" "${got}" "$3" >&2
    return 1
  fi
}

want() {
  want_in "${PLAN}" "$1" "$2"
}

# want_srcs SECTION EXPECTED: the sorted rel paths planned for SECTION.
want_srcs() {
  want "sorted(e['rel'] for e in p['entries'] if e['section'] == '$1')" "$2"
}

# want_file PATH EXPECTED: PATH holds exactly EXPECTED.
want_file() {
  local got
  got="$(<"$1")"
  if [ "${got}" != "$2" ]; then
    printf 'file: %s\n got: %s\nwant: %s\n' "$1" "${got}" "$2" >&2
    return 1
  fi
}

@test "cutoff is Jan 1 four years back: 2026-10-21 -> 2022-01-01" {
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "p['cutoff']" "2022-01-01"
}

@test "cutoff is Jan 1 four years back: 2027-01-05 -> 2023-01-01" {
  run env DOCS_TIDY_TODAY=2027-01-05 "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_in "${STATE}/plan-2027-01-05.json" "p['cutoff']" "2023-01-01"
}

@test "--help describes the commands" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *plan* && "${output}" == *show* && "${output}" == *apply* ]]
}

@test "an old unit archives and a recent unit stays" {
  mk "old/a.txt" 201901010000
  mk "old/sub/b.txt" 202012311200
  mk "oldfile.pdf" 201805050000
  mk "new/a.txt" 201901010000
  mk "new/b.txt" 202603010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs archive "['old/a.txt', 'old/sub/b.txt', 'oldfile.pdf']"
  want "sorted(u['rel'] for u in p['units'])" "['old', 'oldfile.pdf']"
  want "[e['dst'] for e in p['entries'] if e['rel'] == 'old/a.txt'][0]" "${ARCHIVE}/old/a.txt"
  [ -f "${STATE}/plan-2026-10-21.txt" ]
  [[ "${output}" == *"Archive units (2)"* ]]
}

@test "KEEP items never archive and are not counted" {
  mk "army/dd.pdf" 201001010000
  mk "DD214.pdf" 201001010000
  mk "ssn.pdf" 201001010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "len(p['entries'])" "0"
  want "len(p['units'])" "0"
}

@test "tax years split: an old year archives, a year with one recent file stays" {
  mk "tax/2019/w2.pdf" 202002010000
  mk "tax/2021/w2.pdf" 202102010000
  mk "tax/2021/amended.pdf" 202203010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs archive "['tax/2019/w2.pdf']"
  want "[u['rel'] for u in p['units']]" "['tax/2019']"
}

@test "a socket and a symlink are skipped, not planned" {
  mk "old/a.txt" 201901010000
  ln -s a.txt "${DOC}/old/link"
  mksock old sock
  [ -S "${DOC}/old/sock" ]
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs archive "['old/a.txt']"
  want "sorted(p['skipped'])" "[['old/link', 'symlink'], ['old/sock', 'socket']]"
}

@test "snapshot: merge a unique file, stash a dupe, stash a superseded file" {
  mk "keep.txt" 202501010000 "same bytes"
  mk "conflict.txt" 202501010000 "local version"
  mk "Documents - HOST/copy-of-keep.txt" 202001010000 "same bytes"
  mk "Documents - HOST/only/here.txt" 202001010000 "unique"
  mk "Documents - HOST/conflict.txt" 202001010000 "snapshot version"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs snapshot-merge "['Documents - HOST/only/here.txt']"
  want "[e['dst'] for e in p['entries'] if e['section'] == 'snapshot-merge'][0]" "${DOC}/only/here.txt"
  want_srcs snapshot "['Documents - HOST/conflict.txt', 'Documents - HOST/copy-of-keep.txt']"
  want "p['snapshots']['Documents - HOST']['superseded']" "['Documents - HOST/conflict.txt']"
  want "[e['dst'] for e in p['entries'] if e['rel'] == 'Documents - HOST/conflict.txt'][0]" \
    "${STASH}/Documents - HOST/conflict.txt"
  # Snapshot folders are never archive units, however old.
  want_srcs archive "[]"
}

@test "dupes: credit-reports wins, then earliest mtime" {
  mkbig "a/one.bin" 202405010000 x
  mkbig "b/two.bin" 202305010000 x
  mkbig "c/three.bin" 202305010000 x
  mkbig "credit-reports/r.pdf" 202501010000 y
  mkbig "other/r.pdf" 202301010000 y
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "len(p['dupe_groups'])" "2"
  want "sorted(g['keep'] for g in p['dupe_groups'])" "['b/two.bin', 'credit-reports/r.pdf']"
  want_srcs dupes "['a/one.bin', 'c/three.bin', 'other/r.pdf']"
  want "[e['dst'] for e in p['entries'] if e['rel'] == 'a/one.bin'][0]" "${STASH}/a/one.bin"
}

@test "dupes: .git paths, small files and bundles are excluded" {
  mkbig "repo/.git/objects/x" 202501010000 g
  mkbig "other/x" 202501010000 g
  mkbig "Thing.app/Contents/x" 202501010000 h
  mkbig "loose/x" 202501010000 h
  mkbig "Doc.pages/x" 202501010000 i
  mkbig "loose2/y" 202501010000 i
  mkbig "Search.workflow/Contents/document.wflow" 202501010000 j
  mkbig "loose3/document.wflow" 202501010000 j
  mk "small1/s.txt" 202501010000 "tiny"
  mk "small2/s.txt" 202501010000 "tiny"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "len(p['dupe_groups'])" "0"
  want_srcs dupes "[]"
}

@test "dupes: files inside a git working tree are excluded, at any depth" {
  # A .git directory at the top of one unit, and a .git file (a worktree or
  # submodule) two levels down in another.
  mkdir -p "${DOC}/proj/.git"
  mkbig "proj/src/data.bin" 202501010000 w
  mkbig "outside/data.bin" 202501010000 w
  mk "notes/deep/sub/.git" 202501010000 "gitdir: elsewhere"
  mkbig "notes/deep/sub/lib/z.bin" 202501010000 z
  mkbig "elsewhere/z.bin" 202501010000 z
  # Control: the same layout with no .git entry is still a dupe group.
  mkbig "plain/src/data.bin" 202501010000 v
  mkbig "plain2/data.bin" 202601010000 v
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs dupes "['plain2/data.bin']"
}

@test "dupes: node_modules paths are excluded" {
  mkbig "site/node_modules/pkg/index.js" 202501010000 n
  mkbig "other/index.js" 202501010000 n
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "len(p['dupe_groups'])" "0"
}

@test "dupes: copies inside one unit are deliberate and stay" {
  mkbig "Resume/_base/template.md" 202301010000 t
  mkbig "Resume/_archived/acme/template.md" 202401010000 t
  mkbig "icons/airship.png" 202301010000 p
  mkbig "icons/dirigible.png" 202401010000 p
  mkbig "tax/2024/form.pdf" 202401010000 f
  mkbig "tax/2025/form.pdf" 202501010000 f
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  # Only the tax pair spans two units (tax/2024 and tax/2025).
  want_srcs dupes "['tax/2025/form.pdf']"
}

@test "dupes: copies in the keeper's unit stay; copies in other units are stashed" {
  mkbig "a/one.bin" 202301010000 x
  mkbig "a/one-copy.bin" 202401010000 x
  mkbig "b/two.bin" 202402010000 x
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "[g['keep'] for g in p['dupe_groups']]" "['a/one.bin']"
  want_srcs dupes "['b/two.bin']"
}

@test "credit: names are parsed into renames; an unparseable name needs manual" {
  mk "credit-reports/20240615 AMR Experian report.pdf" 202406150000
  mk "credit-reports/JR trans union.pdf" 202302100000
  mk "credit-reports/2024-10 Jen Equifax.pdf" 202410010000
  mk "credit-reports/mystery.pdf" 202401010000
  mk "credit-reports/.rename-log-2026-10-21.tsv" 202601010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "sorted((e['rel'], e['dst'].rsplit('/', 1)[1], e['tags']) for e in p['entries'] if e['section'] == 'credit' and not e['retag_only'])" \
    "[('credit-reports/20240615 AMR Experian report.pdf', '2024-06 Andrew Experian.pdf', ['Andrew', 'Experian']), ('credit-reports/JR trans union.pdf', '2023-02 Jen TransUnion.pdf', ['Jen', 'TransUnion'])]"
  want "p['needs_manual']" "[['credit-reports/mystery.pdf', 'no person']]"
}

@test "credit: a rename that would collide needs manual" {
  mk "credit-reports/2024-06 Andrew Experian.pdf" 202406010000
  mk "credit-reports/AMR experian.pdf" 202406200000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "[e['rel'] for e in p['entries'] if e['section'] == 'credit' and not e['retag_only']]" "[]"
  want "p['needs_manual'][0][0]" "credit-reports/AMR experian.pdf"
}

@test "apply moves, verifies, deletes the source, rmdirs empty dirs and appends the pointer" {
  mk "old/a.txt" 201901010000 "alpha"
  mk "old/sub/b.txt" 201901010000 "beta"
  mk "old/sub/.DS_Store" 201901010000 "junk"
  mk "tax/2018/w2.pdf" 201902010000 "w2"
  mk "recent.txt" 202601010000 "stay"
  printf 'earlier notes\n' >"${DOC}/ARCHIVED-TO-GOOGLE-DRIVE.txt"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  want_file "${ARCHIVE}/old/a.txt" "alpha"
  want_file "${ARCHIVE}/old/sub/b.txt" "beta"
  want_file "${ARCHIVE}/tax/2018/w2.pdf" "w2"
  [ ! -e "${DOC}/old" ]
  [ ! -e "${DOC}/tax/2018" ]
  [ -f "${DOC}/recent.txt" ]
  run head -1 "${DOC}/ARCHIVED-TO-GOOGLE-DRIVE.txt"
  [ "${output}" = "earlier notes" ]
  grep -q "On 2026-10-21, docs-tidy" "${DOC}/ARCHIVED-TO-GOOGLE-DRIVE.txt"
  grep -q "2018" "${DOC}/tax/ARCHIVED-YEARS.txt"
  run grep -c '^OK' "${STATE}/apply-2026-10-21.tsv"
  [ "${output}" = "3" ]
  run grep -c '^ERR' "${STATE}/apply-2026-10-21.tsv"
  [ "${output}" = "0" ]
}

@test "apply keeps a directory that still holds other files" {
  mk "old/a.txt" 201901010000 "alpha"
  mksock old sock
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  [ ! -e "${DOC}/old/a.txt" ]
  [ -S "${DOC}/old/sock" ]
}

@test "apply merges and stashes a snapshot" {
  mk "keep.txt" 202501010000 "same bytes"
  mk "Documents - HOST/copy.txt" 202001010000 "same bytes"
  mk "Documents - HOST/only/here.txt" 202001010000 "unique"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  want_file "${DOC}/only/here.txt" "unique"
  [ -f "${STASH}/Documents - HOST/copy.txt" ]
  [ ! -e "${DOC}/Documents - HOST" ]
}

@test "apply refuses a plan older than 14 days" {
  mk "old/a.txt" 201901010000
  run env DOCS_TIDY_TODAY=2026-10-01 "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run env DOCS_TIDY_TODAY=2026-10-20 "${SCRIPT}" apply "${STATE}/plan-2026-10-01.json"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"19 days old"* ]]
  [ -f "${DOC}/old/a.txt" ]
  [ ! -e "${ARCHIVE}" ]
}

@test "apply refuses when the Drive root is missing" {
  mk "old/a.txt" 201901010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  rmdir "${DRIVE}"
  run "${SCRIPT}" apply
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Drive root missing"* ]]
  [ -f "${DOC}/old/a.txt" ]
}

@test "plan --notify posts a FAILED notification when plan refuses" {
  # A stub osascript records the call, so no real notification pops up. On
  # Linux the script logs the notification instead; accept either.
  local bin="${BATS_TEST_TMPDIR:?}/bin"
  mkdir -p "${bin}"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/osascript.log"\n' "${BATS_TEST_TMPDIR}" >"${bin}/osascript"
  chmod +x "${bin}/osascript"
  rmdir "${DOC}"
  run env PATH="${bin}:${PATH}" "${SCRIPT}" plan --notify
  [ "${status}" -eq 2 ]
  local seen="${output}"
  if [[ -f "${BATS_TEST_TMPDIR}/osascript.log" ]]; then
    seen="$(<"${BATS_TEST_TMPDIR}/osascript.log")"
  fi
  [[ "${seen}" == *"docs-tidy plan FAILED"* ]]
}

@test "apply records an error and keeps the source when it changed after planning" {
  mkbig "a/keep.bin" 202301010000 x
  mkbig "b/stash.bin" 202401010000 x
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs dupes "['b/stash.bin']"
  printf 'edited' >>"${DOC}/b/stash.bin"
  run "${SCRIPT}" apply
  [ "${status}" -eq 1 ]
  [ -f "${DOC}/b/stash.bin" ]
  [ ! -e "${STASH}/b/stash.bin" ]
  grep -q '^ERR	dupes' "${STATE}/apply-2026-10-21.tsv"
  [[ "${output}" == *"source changed since plan"* ]]
}

@test "apply skips an archive unit that changed after planning" {
  mk "old/a.txt" 201901010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  mk "old/new.txt" 202605010000
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  [ -f "${DOC}/old/a.txt" ]
  [[ "${output}" == *"unit changed since plan, skipped: old"* ]]
}

@test "a missing source with an existing destination counts as done" {
  mk "old/a.txt" 201901010000 "alpha"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  mkdir -p "${ARCHIVE}/old"
  cp -p "${DOC}/old/a.txt" "${ARCHIVE}/old/a.txt"
  rm "${DOC}/old/a.txt"
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  grep -q "^OK	archive	.*already done" "${STATE}/apply-2026-10-21.tsv"
}

@test "apply errors when the destination exists with other content" {
  mk "old/a.txt" 201901010000 "alpha"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  mkdir -p "${ARCHIVE}/old"
  printf 'different' >"${ARCHIVE}/old/a.txt"
  run "${SCRIPT}" apply
  [ "${status}" -eq 1 ]
  [ -f "${DOC}/old/a.txt" ]
  want_file "${ARCHIVE}/old/a.txt" "different"
}

@test "--skip dupes leaves dupes in place" {
  mkbig "a/keep.bin" 202301010000 x
  mkbig "b/stash.bin" 202401010000 x
  mk "old/a.txt" 201901010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply --skip dupes
  [ "${status}" -eq 0 ]
  [ -f "${DOC}/a/keep.bin" ]
  [ -f "${DOC}/b/stash.bin" ]
  [ ! -e "${DRIVE}/probably-dupes" ]
  [ ! -e "${DOC}/old" ]
}

@test "apply renames credit reports and writes the rename log" {
  mk "credit-reports/20240615 AMR Experian report.pdf" 202406150000 "pdf"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  [ -f "${DOC}/credit-reports/2024-06 Andrew Experian.pdf" ]
  [ ! -e "${DOC}/credit-reports/20240615 AMR Experian report.pdf" ]
  grep -q "20240615 AMR Experian report.pdf	2024-06 Andrew Experian.pdf	Andrew,Experian" \
    "${DOC}/credit-reports/.rename-log-2026-10-21.tsv"
  # A credit-only apply moved nothing to Drive, so it writes no pointer.
  [ ! -e "${DOC}/ARCHIVED-TO-GOOGLE-DRIVE.txt" ]
}

@test "apply of dupes rmdirs the emptied parent but not an untouched sibling" {
  mkbig "a/keep.bin" 202301010000 x
  mkbig "b/c/stash.bin" 202401010000 x
  mk "b/c/.DS_Store" 202401010000 "junk"
  mk "b/sibling/.DS_Store" 202401010000 "junk"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  [ -f "${STASH}/b/c/stash.bin" ]
  [ ! -e "${DOC}/b/c" ]
  [ -f "${DOC}/b/sibling/.DS_Store" ]
  [ -f "${DOC}/a/keep.bin" ]
}

@test "--skip repeats to skip more than one section" {
  mkbig "a/keep.bin" 202301010000 x
  mkbig "b/stash.bin" 202401010000 x
  mk "old/a.txt" 201901010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply --skip dupes --skip archive
  [ "${status}" -eq 0 ]
  [ -f "${DOC}/b/stash.bin" ]
  [ -f "${DOC}/old/a.txt" ]
}

@test "--skip rejects an unknown section" {
  run "${SCRIPT}" apply --skip bogus
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid choice"* ]]
}

@test "show prints the newest plan" {
  mk "old/a.txt" 201901010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" show
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"docs-tidy plan 2026-10-21"* ]]
  [[ "${output}" == *"old  newest 2019-01-01"* ]]
}

@test "credit retag: only a missing canonical tag triggers it, and the user's tags are kept" {
  if ! is_mac; then skip "Finder tags need macOS"; fi
  mk "credit-reports/2024-10 Jen Equifax.pdf" 202410010000
  mk "credit-reports/2024-06 Andrew Experian.pdf" 202406010000
  settags "${DOC}/credit-reports/2024-10 Jen Equifax.pdf" $'Important\n6' Jen
  # Canonical tags present (one with a colour suffix) plus a user tag: no retag.
  settags "${DOC}/credit-reports/2024-06 Andrew Experian.pdf" Andrew $'Experian\n4' Mine
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want "[e['rel'] for e in p['entries'] if e['section'] == 'credit']" "['credit-reports/2024-10 Jen Equifax.pdf']"
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  want_tags "${DOC}/credit-reports/2024-10 Jen Equifax.pdf" "['Important\\n6', 'Jen', 'Equifax']"
  want_tags "${DOC}/credit-reports/2024-06 Andrew Experian.pdf" "['Andrew', 'Experian\\n4', 'Mine']"
}

@test "credit rename keeps the file's existing tags and adds the canonical ones" {
  if ! is_mac; then skip "Finder tags need macOS"; fi
  mk "credit-reports/AMR experian.pdf" 202406200000
  settags "${DOC}/credit-reports/AMR experian.pdf" $'Important\n6'
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  want_tags "${DOC}/credit-reports/2024-06 Andrew Experian.pdf" "['Important\\n6', 'Andrew', 'Experian']"
}

@test "credit: a tag write failure is a note on an OK rename, and the rename is logged" {
  mk "credit-reports/AMR experian.pdf" 202406200000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  # Read-only file: the rename still works (the directory is writable) but
  # xattr cannot write the tags.
  chmod 444 "${DOC}/credit-reports/AMR experian.pdf"
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  [ -f "${DOC}/credit-reports/2024-06 Andrew Experian.pdf" ]
  grep -q "AMR experian.pdf	2024-06 Andrew Experian.pdf	Andrew,Experian" \
    "${DOC}/credit-reports/.rename-log-2026-10-21.tsv"
  grep -q "^OK	credit" "${STATE}/apply-2026-10-21.tsv"
  if is_mac; then
    grep -q "^OK	credit.*tags not written" "${STATE}/apply-2026-10-21.tsv"
  fi
}

@test "snapshot: a file whose unit is being archived is stashed, not merged" {
  mk "old/a.txt" 201901010000 "alpha"
  mk "Documents - HOST/old/extra.txt" 201801010000 "only in snapshot"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs archive "['old/a.txt']"
  want_srcs snapshot-merge "[]"
  want "[e['why'] for e in p['entries'] if e['section'] == 'snapshot']" "['unit archived']"
}

@test "notify passes title and message to osascript as argv and logs a failure" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/osascript" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"${BATS_TEST_TMPDIR}/osascript.args"
exit 3
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/osascript"
  run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" "${SCRIPT}" plan --notify
  [ "${status}" -eq 0 ]
  if is_mac; then
    grep -qx '<on run argv>' "${BATS_TEST_TMPDIR}/osascript.args"
    grep -qx '<docs-tidy plan 2026-10-21>' "${BATS_TEST_TMPDIR}/osascript.args"
    grep -q '^<archive 0, ' "${BATS_TEST_TMPDIR}/osascript.args"
    [[ "${output}" == *"notify failed (osascript exit 3)"* ]]
  else
    [[ "${output}" == *"notify: docs-tidy plan 2026-10-21"* ]]
  fi
}

@test "apply writes apply-<date>.tsv before the pointer step, so a pointer failure keeps the record" {
  mk "old/a.txt" 201901010000 "alpha"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  # A directory where the pointer file should be makes write_pointer fail.
  mkdir "${DOC}/ARCHIVED-TO-GOOGLE-DRIVE.txt"
  run "${SCRIPT}" apply
  [ "${status}" -ne 0 ]
  grep -q "^OK	archive	.*old/a.txt" "${STATE}/apply-2026-10-21.tsv"
}

@test "an unreadable directory is skipped and its unit never archives" {
  if [[ "${EUID}" -eq 0 ]]; then skip "root can read a chmod 000 directory"; fi
  mk "old/a.txt" 201901010000
  mk "old/locked/b.txt" 201901010000
  mk "old2/a.txt" 201901010000
  chmod 000 "${DOC}/old/locked"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  want_srcs archive "['old2/a.txt']"
  want "p['skipped']" "[['old/locked', 'unreadable directory']]"
}

@test "apply skips a unit that gained an unreadable directory after planning" {
  if [[ "${EUID}" -eq 0 ]]; then skip "root can read a chmod 000 directory"; fi
  mk "old/a.txt" 201901010000
  mk "old/sub/b.txt" 201901010000
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  chmod 000 "${DOC}/old/sub"
  run "${SCRIPT}" apply
  [ "${status}" -eq 0 ]
  [ -f "${DOC}/old/a.txt" ]
  [[ "${output}" == *"unit has an unreadable directory, skipped: old"* ]]
}

@test "a failed copy records an error, keeps the source and leaves no destination" {
  if [[ "${EUID}" -eq 0 ]]; then skip "root can write a read-only directory"; fi
  mk "old/a.txt" 201901010000 "alpha"
  run "${SCRIPT}" plan
  [ "${status}" -eq 0 ]
  mkdir -p "${ARCHIVE}/old"
  chmod 555 "${ARCHIVE}/old"
  run "${SCRIPT}" apply
  [ "${status}" -eq 1 ]
  want_file "${DOC}/old/a.txt" "alpha"
  [ ! -e "${ARCHIVE}/old/a.txt" ]
  grep -q "^ERR	archive" "${STATE}/apply-2026-10-21.tsv"
}
