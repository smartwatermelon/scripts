# docs-tidy: quarterly Documents tidy (design)

## Why

On 2026-10-21 `~/Documents` (iCloud-synced, backed up to Google Drive as
machine ASIAGO) was tidied by hand: 9.1 GB of iCloud quota, about 4 GB of it
duplicates. Old items moved to Google Drive, an old machine snapshot was
de-duplicated, and credit reports were renamed to `YYYY-MM Person Agency.pdf`
with Finder tags. This tool repeats that each quarter.

The run is **plan, then approve**. launchd writes a plan and sends a
notification. Nothing moves until Andrew runs `docs-tidy apply`.

A launchd spike (2026-10-21) showed an Aqua LaunchAgent running
`/opt/homebrew/bin/python3` can read `~/Documents`, `~/Downloads`, the Drive
mount and the DriveFS databases with no TCC prompt, so the plan step runs
under launchd.

## Files

| Path | What |
| --- | --- |
| `docs-tidy.py` | Python entrypoint, mode 755, `#!/usr/bin/env -S python3 -I`. Symlinked as `~/.local/bin/docs-tidy`. |
| `LaunchAgents/com.asiago.docs-tidy.plist` | Runs `docs-tidy plan --notify` at 10:00 on Jan 1, Apr 1, Jul 1, Oct 1. `RunAtLoad` false, Aqua only. |
| `tests/docs-tidy.bats` | Fixture-tree tests; run on Ubuntu CI, so macOS-only calls are guarded. |

Python, not Bash: the job reads SQLite, hashes files and writes binary
plists. Doing that in Bash would mean shelling out to Python anyway.

## Commands

- `docs-tidy plan [--notify]` writes `plan-YYYY-MM-DD.json` and
  `plan-YYYY-MM-DD.txt` to the state dir, prints the text summary, and with
  `--notify` posts a macOS notification with the counts.
- `docs-tidy show [PLAN]` prints the text summary of the newest plan.
- `docs-tidy apply [PLAN] [--skip SECTION ...]` executes a plan.

## Configuration (env overrides exist for tests)

| Setting | Default | Env |
| --- | --- | --- |
| Documents root | `~/Documents` | `DOCS_TIDY_DOC` |
| Drive root | glob `~/Library/CloudStorage/GoogleDrive-*/My Drive` (exactly one match, else error) | `DOCS_TIDY_DRIVE` |
| DriveFS dir | glob `~/Library/Application Support/Google/DriveFS/[0-9]*/` containing `mirror_sqlite.db`; `none` disables | `DOCS_TIDY_DRIVEFS` |
| State dir | `~/.local/state/docs-tidy` | `DOCS_TIDY_STATE` |
| Today | local date | `DOCS_TIDY_TODAY` (`YYYY-MM-DD`) |

Archive destination: `<Drive>/Documents Archive/<rel>`.
Dupes destination: `<Drive>/probably-dupes/<plan date>/<rel>`.

`KEEP` is a visible list at the top of the script. These top-level items
never archive: `army`, `DD214.pdf`, `ssn.pdf`, `Andrew Rich 1989 GED.pdf`,
`Issue COE.pdf`, `1Password Emergency Kit A3-KCMDEC-my.pdf`. Plan counts
exclude them, so the counts in the notification are the real counts.

## Cutoff

The cutoff is 00:00 local on Jan 1 of `(today.year - 4)`. In Oct 2026 that is
2022-01-01; in Jan 2027 it is 2023-01-01.

## Inventory

1. List regular files only (`S_ISREG` on `lstat`). Sockets, FIFOs and
   symlinks are reported as skipped and never planned. The 2026-10-21 run
   failed on a git `fsmonitor--daemon.ipc` socket.
2. Skip `.DS_Store` and `.localized` everywhere.
3. MD5 source, in order:
   1. the DriveFS mirror DB (`mirror_item.local_md5_checksum`), when its size
      and mtime match `lstat`;
   2. a local hash, when the file is not dataless (macOS `st_flags &
      0x40000000`, `SF_DATALESS`);
   3. otherwise unknown. Never download a file just to plan.

## Plan sections (applied in this order)

1. **archive.** Units are the top-level entries of Documents, except
   dotfiles, `Documents - *`, `credit-reports`, `tax`, the pointer file and
   `KEEP`. Each `tax/<year>` is its own unit. A unit archives when its newest
   regular-file mtime is before the cutoff. Every file in it maps to
   `<Drive>/Documents Archive/<rel>`.
2. **snapshot.** For each `Documents - <HOST>` folder, check every file
   against the files that stay local after archive:
   - If its MD5 matches a file outside the snapshots, stash it.
   - If it is unique and `<Documents>/<rel-inside-snapshot>` is absent,
     merge it there (section `snapshot-merge`).
   - If it is unique but that path exists with other content, stash it and
     list it as "superseded".
   - If its MD5 is unknown, list it under "needs review" and plan nothing.
3. **dupes.** Group the files that stay local (not archived, not in
   snapshots) by MD5. Group only files of 1 KiB or larger. Exclude:
   - any path with a `.git` or `node_modules` component, or a component
     ending in `.app`, `.bundle`, `.photoslibrary`, `.rtfd`, `.pages`,
     `.numbers`, `.key` or `.workflow`;
   - any file inside a git working tree: a directory, at any depth, that
     holds a `.git` entry (directory or file). Stashing one copy out of a
     project breaks the project.

   Copies inside the same unit are deliberate (templates, renamed copies
   such as `airship.png` and `dirigible.png`). A unit is a top-level entry
   of Documents, or `tax/<year>`. A group counts only when its copies span
   two or more units. Keep one copy: anything in `credit-reports` wins,
   then a `KEEP` item, then the earliest mtime, then the shortest path,
   then lexical order. Stash the copies in other units. Copies in the
   keeper's own unit stay, and `KEEP` items are never stashed.

   Why: on the 2026-10-21 dry run, the first rule set (no working-tree,
   `node_modules` or unit rule) planned 245 stashes in 167 groups. 93 were
   under `old-pi`, 51 under `Resume` (per-application template copies), 41
   under `Codex` and 33 in `node_modules`. With these rules the same data
   gives 19 stashes in 19 groups.
4. **credit.** For files in `credit-reports` (not dotfiles) whose name does
   not match `^\d{4}-\d{2} (Andrew|Jen) (Equifax|Experian|TransUnion)\.pdf$`
   or the request-form names, propose a rename. Use the person and agency
   rules from the 2026-10-21 `rename.py`: AR, AMR and Andrew mean Andrew;
   JR, JMR, Jen and Jennifer mean Jen.
   - The date comes from a `YYYYMMDD`, `YYYY-MM-DD` or `YYYY_MM_DD` in the
     name, else the file's mtime.
   - Unparseable names, or names that would collide, go to "needs manual".
     Nothing is planned for them.
   - Canonical names whose Finder tags differ from `[Person, Agency]` get a
     retag-only entry.

The text summary shows counts and bytes per section, every archive unit with
its newest mtime, every dupe group (kept path, then stashed paths), every
snapshot merge, every credit rename, and the skipped, needs-review and
needs-manual lists.

## Apply

Each guard below refuses the whole apply with a reason:

- The plan is more than 14 days old. Fix: re-run `plan`.
- The Drive root is missing.
- Free space on the volume of Documents is below the bytes of the dataless
  sources plus 2 GiB.

Per file: copy, verify, delete. This is the pattern proven on 2026-10-21.

1. Re-hash the source. If it differs from the planned MD5, record an error
   and skip the file.
2. If the destination exists with the same MD5, delete the source. If it
   exists with a different MD5, record an error.
3. Copy with `shutil.copy2`, re-hash the destination, and only then delete
   the source.
4. A missing source with an existing destination counts as already done.

For archive units, first re-check that the unit's newest mtime is still
before the cutoff. If not, skip the whole unit and report it.

Before copying, call `brctl download` on each dataless source (macOS only).
On `ETIMEDOUT` (errno 60), call `brctl download` and retry, up to 3 times.
The 2026-10-21 run lost 9 files to this, and all 9 then copied in 5 s.

Credit entries: `os.rename`, then write tags with `xattr -wx
com.apple.metadata:_kMDItemUserTags <binary plist hex>` (macOS only; on other
systems, log that tags were skipped). Append one line per change to
`credit-reports/.rename-log-<date>.tsv`.

After the moves:

- In each source tree that was moved, delete `.DS_Store` and `.localized`.
  Then `rmdir` the empty directories, bottom-up. Never use `rm -rf`, and
  never touch a directory that still holds other files.
- Append a dated section to `<Documents>/ARCHIVED-TO-GOOGLE-DRIVE.txt`
  (create it if missing). When tax years were archived, also append to
  `<Documents>/tax/ARCHIVED-YEARS.txt`.
- Write `apply-<date>.tsv` (OK/ERR, section, md5, src, dst) to the state dir.

Exit 0 if every entry succeeded, else exit 1 and print a summary of the
errors.
