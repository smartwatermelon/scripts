#!/usr/bin/env -S python3 -I
"""docs-tidy: quarterly ~/Documents tidy. Plan, then approve.

Run `docs-tidy --help` for commands and env overrides.
Design: docs/plans/2026-10-21-docs-tidy-design.md
"""

import argparse
import datetime
import errno
import glob
import hashlib
import json
import os
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import time

# Top-level Documents items that never archive.
KEEP = {
    "army",
    "DD214.pdf",
    "ssn.pdf",
    "Andrew Rich 1989 GED.pdf",
    "Issue COE.pdf",
    "1Password Emergency Kit A3-KCMDEC-my.pdf",
}

POINTER = "ARCHIVED-TO-GOOGLE-DRIVE.txt"
TAX_POINTER = "ARCHIVED-YEARS.txt"
CREDIT = "credit-reports"
SNAPSHOT_PREFIX = "Documents - "
SKIPNAMES = {".DS_Store", ".localized"}
SECTIONS = ["archive", "snapshot-merge", "snapshot", "dupes", "credit"]
MAX_PLAN_AGE_DAYS = 14
FREE_RESERVE = 2 * 1024**3
DUPE_MIN_SIZE = 1024
DUPE_EXCLUDE_SUFFIXES = (".app", ".bundle", ".photoslibrary", ".rtfd", ".pages", ".numbers", ".key", ".workflow")
SF_DATALESS = 0x40000000
TAG_XATTR = "com.apple.metadata:_kMDItemUserTags"
PEOPLE = {
    "Andrew": {"ar", "amr", "andrew"},
    "Jen": {"jr", "jmr", "jen", "jennifer"},
}
AGENCIES = ("Equifax", "Experian", "TransUnion")
CANON_RE = re.compile(r"^\d{4}-\d{2} (Andrew|Jen) (Equifax|Experian|TransUnion)\.pdf$")
REQUEST_RE = re.compile(r"^\d{4}-\d{2} (Andrew|Jen) Request Form\.pdf$")
BLANK_REQUEST = "Blank Annual Credit Report Request Form.pdf"
DATE_RE = re.compile(r"(?<!\d)((?:19|20)\d{2})[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12]\d|3[01])(?!\d)")

IS_MAC = sys.platform == "darwin"


class Refuse(Exception):
    """A guard refused the whole operation."""


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- config


def today():
    v = os.environ.get("DOCS_TIDY_TODAY")
    if v:
        return datetime.date.fromisoformat(v)
    return datetime.date.today()


def doc_root():
    return os.path.abspath(os.environ.get("DOCS_TIDY_DOC") or os.path.expanduser("~/Documents"))


def state_dir():
    return os.environ.get("DOCS_TIDY_STATE") or os.path.expanduser("~/.local/state/docs-tidy")


def drive_root():
    v = os.environ.get("DOCS_TIDY_DRIVE")
    if v:
        return os.path.abspath(v)
    hits = glob.glob(os.path.expanduser("~/Library/CloudStorage/GoogleDrive-*/My Drive"))
    if len(hits) != 1:
        raise Refuse(f"expected exactly one Google Drive root, found {len(hits)}: {hits}; set DOCS_TIDY_DRIVE")
    return hits[0]


def drivefs_dir():
    v = os.environ.get("DOCS_TIDY_DRIVEFS")
    if v == "none":
        return None
    if v:
        return v
    hits = [
        d
        for d in glob.glob(os.path.expanduser("~/Library/Application Support/Google/DriveFS/[0-9]*/"))
        if os.path.isfile(os.path.join(d, "mirror_sqlite.db"))
    ]
    return hits


def cutoff_date(d):
    return datetime.date(d.year - 4, 1, 1)


def cutoff_ts(d):
    c = cutoff_date(d)
    return datetime.datetime(c.year, c.month, c.day).timestamp()


# ---------------------------------------------------------------- hashing


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def brctl_download(path):
    if IS_MAC and shutil.which("brctl"):
        subprocess.run(["brctl", "download", path], check=False, capture_output=True)


def md5_with_retry(path, dataless=False):
    """Hash a file, fetching it from iCloud first when it is dataless.

    ETIMEDOUT (errno 60 on macOS) on a dataless file is retried after a fresh
    `brctl download`, up to 3 times; the 2026-10-21 run lost 9 files to it.
    """
    if dataless:
        brctl_download(path)
    for attempt in range(4):
        try:
            return md5_file(path)
        except OSError as e:
            if e.errno not in (60, errno.ETIMEDOUT) or attempt == 3:
                raise
            brctl_download(path)
            time.sleep(1)
    raise AssertionError("unreachable")


def is_dataless(st):
    return bool(getattr(st, "st_flags", 0) & SF_DATALESS)


def load_drivefs(doc, dirs):
    """Return {rel_path: (md5, size, mtime_ms)} from the DriveFS mirror DB."""
    if dirs is None:
        return {}
    if isinstance(dirs, str):
        dirs = [dirs]
    base = os.path.basename(doc.rstrip("/"))
    out = {}
    for d in dirs:
        db = os.path.join(d, "mirror_sqlite.db")
        if not os.path.isfile(db):
            log(f"warning: no mirror_sqlite.db in {d}")
            continue
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            rows = con.execute(
                "select local_stable_id, parent_local_stable_id, local_filename, local_type,"
                " local_md5_checksum, local_size, local_mtime_ms from mirror_item"
            ).fetchall()
            con.close()
        except sqlite3.Error as e:
            log(f"warning: cannot read {db}: {e}")
            continue
        byid = {r[0]: r for r in rows}
        roots = {r[0] for r in rows if r[1] == -1 and r[2] == base}
        if not roots:
            continue

        def rel(i):
            parts = []
            seen = set()
            while i in byid and byid[i][1] != -1 and i not in seen:
                seen.add(i)
                parts.append(byid[i][2])
                i = byid[i][1]
            return i, "/".join(reversed(parts))

        for r in rows:
            if r[3] != 1 or not r[4]:
                continue
            root, p = rel(r[0])
            if root in roots:
                out[p] = (r[4], r[5], r[6])
    return out


# ---------------------------------------------------------------- inventory


def inventory(doc, drivefs):
    """Walk Documents. Return (files, skipped).

    files: {rel: dict(size, mtime, dataless, md5, md5_src)}; regular files only.
    skipped: [(rel, kind)] for symlinks, sockets, FIFOs and devices.
    """
    files, skipped = {}, []
    hashed = 0
    for root, dirs, names in os.walk(doc, followlinks=False):
        for d in list(dirs):
            p = os.path.join(root, d)
            if os.path.islink(p):
                skipped.append((os.path.relpath(p, doc), "symlink"))
        for n in names:
            if n in SKIPNAMES:
                continue
            p = os.path.join(root, n)
            rel = os.path.relpath(p, doc)
            try:
                st = os.lstat(p)
            except OSError as e:
                skipped.append((rel, f"lstat failed: {e.strerror}"))
                continue
            if not stat.S_ISREG(st.st_mode):
                skipped.append((rel, file_kind(st.st_mode)))
                continue
            mtime_ms = st.st_mtime_ns // 1_000_000
            dataless = is_dataless(st)
            md5, src = None, None
            hit = drivefs.get(rel)
            if hit and hit[1] == st.st_size and hit[2] == mtime_ms:
                md5, src = hit[0], "drivefs"
            elif not dataless:
                try:
                    md5, src = md5_file(p), "local"
                    hashed += 1
                except OSError as e:
                    skipped.append((rel, f"read failed: {e.strerror}"))
                    continue
            files[rel] = dict(size=st.st_size, mtime=st.st_mtime, dataless=dataless, md5=md5, md5_src=src)
    skipped.sort()
    return files, skipped


def file_kind(mode):
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
        return "device"
    return "other"


def top(rel):
    return rel.split("/", 1)[0]


def unit_of(rel):
    """The unit a path belongs to: its top-level entry, or tax/<year>."""
    parts = rel.split("/")
    if parts[0] == "tax" and len(parts) > 1:
        return "/".join(parts[:2])
    return parts[0]


def under(rel, prefix):
    return rel == prefix or rel.startswith(prefix + "/")


# ---------------------------------------------------------------- credit names


def read_tags(path):
    """Finder tag names (colour suffix stripped), or None when unreadable."""
    if not (IS_MAC and shutil.which("xattr")):
        return None
    r = subprocess.run(["xattr", "-px", TAG_XATTR, path], capture_output=True, text=True)
    if r.returncode != 0:
        return []
    try:
        tags = plistlib.loads(bytes.fromhex("".join(r.stdout.split())))
    except Exception:
        return []
    return [t.split("\n", 1)[0] for t in tags]


def write_tags(path, tags):
    if not (IS_MAC and shutil.which("xattr")):
        return False
    hexval = plistlib.dumps(list(tags), fmt=plistlib.FMT_BINARY).hex()
    subprocess.run(["xattr", "-wx", TAG_XATTR, hexval, path], check=True, capture_output=True)
    return True


def canonical_tags(name):
    m = CANON_RE.match(name)
    if m:
        return [m.group(1), m.group(2)]
    m = REQUEST_RE.match(name)
    if m:
        return [m.group(1), "AnnualCreditReport"]
    if name == BLANK_REQUEST:
        return ["AnnualCreditReport"]
    return None


def name_date(name, mtime):
    m = DATE_RE.search(name)
    if m:
        return f"{m.group(1)}-{m.group(2)}"
    return time.strftime("%Y-%m", time.localtime(mtime))


def parse_credit(name, mtime):
    """Return (new_name, tags) or (None, reason)."""
    low = name.lower()
    if not low.endswith(".pdf"):
        return None, "not a PDF"
    tokens = set(re.split(r"[^a-z]+", low[:-4]))
    ym = name_date(name, mtime)
    if low.startswith("fact act request form"):
        people = [p for p, keys in PEOPLE.items() if tokens & keys]
        if len(people) == 1:
            return f"{ym} {people[0]} Request Form.pdf", [people[0], "AnnualCreditReport"]
        if not people:
            return BLANK_REQUEST, ["AnnualCreditReport"]
        return None, "more than one person"
    people = [p for p, keys in PEOPLE.items() if tokens & keys]
    if len(people) != 1:
        return None, "no person" if not people else "more than one person"
    squashed = re.sub(r"[^a-z]", "", low)
    agencies = [a for a in AGENCIES if a.lower() in squashed]
    if len(agencies) != 1:
        return None, "no agency" if not agencies else "more than one agency"
    return f"{ym} {people[0]} {agencies[0]}.pdf", [people[0], agencies[0]]


# ---------------------------------------------------------------- plan


def build_plan(doc, drive, drivefs_dirs, day):
    drivefs = load_drivefs(doc, drivefs_dirs)
    files, skipped = inventory(doc, drivefs)
    cut = cutoff_ts(day)
    date = day.isoformat()
    arch_base = os.path.join(drive, "Documents Archive")
    dupe_base = os.path.join(drive, "probably-dupes", date)
    entries = []

    def entry(section, rel, dst, **extra):
        f = files[rel]
        e = dict(section=section, src=os.path.join(doc, rel), dst=dst, rel=rel, md5=f["md5"],
                 size=f["size"], mtime=f["mtime"], dataless=f["dataless"])
        e.update(extra)
        entries.append(e)
        return e

    # 1. archive units
    unit_names = []
    for name in sorted(os.listdir(doc)):
        p = os.path.join(doc, name)
        if (name.startswith(".") or name.startswith(SNAPSHOT_PREFIX) or name in (CREDIT, "tax", POINTER)
                or name in KEEP or os.path.islink(p)):
            continue
        unit_names.append(name)
    tax = os.path.join(doc, "tax")
    if os.path.isdir(tax) and not os.path.islink(tax):
        for y in sorted(os.listdir(tax)):
            if y.startswith(".") or y == TAX_POINTER or os.path.islink(os.path.join(tax, y)):
                continue
            unit_names.append(f"tax/{y}")
    units, archived = [], set()
    for u in unit_names:
        members = [r for r in files if under(r, u)]
        if not members:
            continue
        newest = max(files[r]["mtime"] for r in members)
        if newest >= cut:
            continue
        units.append(dict(rel=u, newest=newest, files=len(members), bytes=sum(files[r]["size"] for r in members),
                          tax=u.startswith("tax/")))
        for r in sorted(members):
            entry("archive", r, os.path.join(arch_base, r), unit=u)
            archived.add(r)

    def in_snapshot(r):
        return top(r).startswith(SNAPSHOT_PREFIX)

    local = {r for r in files if r not in archived and not in_snapshot(r)}

    # 2. snapshots
    outside_md5 = {files[r]["md5"] for r in local if files[r]["md5"]}
    merge_dst = {}
    snapshots, needs_review = {}, []
    for host_dir in sorted({top(r) for r in files if in_snapshot(r)}):
        s = dict(merge=[], stash=0, stash_bytes=0, superseded=[], review=0, files=0)
        snapshots[host_dir] = s
        for r in sorted(x for x in files if under(x, host_dir) and x != host_dir):
            s["files"] += 1
            f = files[r]
            inner = r[len(host_dir) + 1:]
            stash_dst = os.path.join(dupe_base, r)
            if not f["md5"]:
                needs_review.append(r)
                s["review"] += 1
                continue
            if f["md5"] in outside_md5:
                entry("snapshot", r, stash_dst, why="dupe")
                s["stash"] += 1
                s["stash_bytes"] += f["size"]
                continue
            if not os.path.lexists(os.path.join(doc, inner)) and inner not in merge_dst:
                entry("snapshot-merge", r, os.path.join(doc, inner))
                merge_dst[inner] = f["md5"]
                outside_md5.add(f["md5"])
                s["merge"].append(r)
                continue
            entry("snapshot", r, stash_dst, why="superseded")
            s["stash"] += 1
            s["stash_bytes"] += f["size"]
            s["superseded"].append(r)

    # 3. dupes
    # Skip any file inside a git working tree: stashing it breaks the project.
    git_cache = {}

    def in_work_tree(r):
        parts = r.split("/")[:-1]
        for i in range(len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in git_cache:
                git_cache[d] = os.path.lexists(os.path.join(doc, d, ".git"))
            if git_cache[d]:
                return True
        return False

    def dupe_ok(r):
        f = files[r]
        if f["size"] < DUPE_MIN_SIZE or not f["md5"]:
            return False
        for c in r.split("/"):
            if c in (".git", "node_modules") or c.endswith(DUPE_EXCLUDE_SUFFIXES):
                return False
        return not in_work_tree(r)

    groups = {}
    for r in local:
        if dupe_ok(r):
            groups.setdefault(files[r]["md5"], []).append(r)
    dupe_groups, stashed = [], set()
    for md5, members in sorted(groups.items(), key=lambda kv: min(kv[1])):
        # Copies inside one unit are deliberate (templates, renamed copies):
        # only copies in different units count as dupes.
        if len({unit_of(r) for r in members}) < 2:
            continue
        ranked = sorted(members, key=lambda r: (top(r) != CREDIT, top(r) not in KEEP, files[r]["mtime"], len(r), r))
        keep = ranked[0]
        # Copies in the keeper's own unit stay with it. KEEP items are
        # protected: never stash them, even as a duplicate.
        stash = [r for r in ranked[1:] if unit_of(r) != unit_of(keep) and top(r) not in KEEP]
        if not stash:
            continue
        dupe_groups.append(dict(md5=md5, size=files[keep]["size"], keep=keep, stash=stash))
        for r in stash:
            entry("dupes", r, os.path.join(dupe_base, r), keep=keep)
            stashed.add(r)

    # 4. credit
    needs_manual, credit = [], []
    cdir = os.path.join(doc, CREDIT)
    if os.path.isdir(cdir) and not os.path.islink(cdir):
        names = sorted(os.listdir(cdir))
        existing = set(names)
        proposals = []
        for n in names:
            rel = f"{CREDIT}/{n}"
            if n.startswith(".") or n in SKIPNAMES:
                continue
            if rel not in files:
                if os.path.isdir(os.path.join(cdir, n)) and not os.path.islink(os.path.join(cdir, n)):
                    needs_manual.append((rel, "directory"))
                continue
            if rel in stashed:
                continue
            tags = canonical_tags(n)
            if tags is not None:
                have = read_tags(os.path.join(cdir, n))
                if have is not None and sorted(have) != sorted(tags):
                    proposals.append((n, n, tags, have))
                continue
            new, why = parse_credit(n, files[rel]["mtime"])
            if new is None:
                needs_manual.append((rel, why))
                continue
            proposals.append((n, new, why, None))
        targets = {}
        for old, new, _tags, _have in proposals:
            targets.setdefault(new, []).append(old)
        for old, new, tags, have in proposals:
            if old != new and (len(targets[new]) > 1 or new in existing):
                needs_manual.append((f"{CREDIT}/{old}", f"would collide on {new!r}"))
                continue
            e = entry("credit", f"{CREDIT}/{old}", os.path.join(cdir, new), tags=tags,
                      retag_only=(old == new), old_tags=have)
            credit.append(e)
    needs_manual.sort()

    return dict(
        version=1,
        date=date,
        created=datetime.datetime.now().isoformat(timespec="seconds"),
        cutoff=cutoff_date(day).isoformat(),
        doc=doc,
        drive=drive,
        drivefs=bool(drivefs),
        inventory=dict(files=len(files), md5_drivefs=sum(1 for f in files.values() if f["md5_src"] == "drivefs"),
                       md5_local=sum(1 for f in files.values() if f["md5_src"] == "local"),
                       md5_unknown=sum(1 for f in files.values() if not f["md5"]),
                       dataless=sum(1 for f in files.values() if f["dataless"])),
        units=units,
        snapshots=snapshots,
        dupe_groups=dupe_groups,
        entries=entries,
        skipped=[list(x) for x in skipped],
        needs_review=needs_review,
        needs_manual=[list(x) for x in needs_manual],
    )


# ---------------------------------------------------------------- summary


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000
    return str(n)


def fmt_ts(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))


def section_counts(plan):
    c = {s: [0, 0] for s in SECTIONS}
    for e in plan["entries"]:
        c[e["section"]][0] += 1
        c[e["section"]][1] += e["size"]
    return c


def summary(plan):
    out = []
    w = out.append
    inv = plan["inventory"]
    w(f"docs-tidy plan {plan['date']}  (cutoff {plan['cutoff']})")
    w(f"Documents: {plan['doc']}")
    w(f"Drive:     {plan['drive']}")
    w(f"Inventory: {inv['files']} files; md5 from DriveFS {inv['md5_drivefs']}, local {inv['md5_local']},"
      f" unknown {inv['md5_unknown']}; dataless {inv['dataless']}")
    w("")
    w("Sections:")
    for s, (n, b) in section_counts(plan).items():
        w(f"  {s:15} {n:6} files  {human(b):>10}")
    w(f"  {'skipped':15} {len(plan['skipped']):6}")
    w(f"  {'needs-review':15} {len(plan['needs_review']):6}")
    w(f"  {'needs-manual':15} {len(plan['needs_manual']):6}")
    w("")
    w(f"Archive units ({len(plan['units'])}):")
    for u in plan["units"]:
        w(f"  {u['rel']}  newest {fmt_ts(u['newest'])}  {u['files']} files  {human(u['bytes'])}")
    w("")
    w(f"Snapshots ({len(plan['snapshots'])}):")
    for host, s in plan["snapshots"].items():
        w(f"  {host}: {s['files']} files; merge {len(s['merge'])}, stash {s['stash']} ({human(s['stash_bytes'])}),"
          f" of which superseded {len(s['superseded'])}; needs review {s['review']}")
        for r in s["merge"]:
            w(f"    merge      {r}")
        for r in s["superseded"]:
            w(f"    superseded {r}")
    w("")
    w(f"Dupe groups ({len(plan['dupe_groups'])}):")
    for g in plan["dupe_groups"]:
        w(f"  {human(g['size'])} x{1 + len(g['stash'])}  {g['md5']}")
        w(f"    keep   {g['keep']}")
        for r in g["stash"]:
            w(f"    stash  {r}")
    w("")
    credit = [e for e in plan["entries"] if e["section"] == "credit"]
    w(f"Credit renames ({len(credit)}):")
    for e in credit:
        tags = ", ".join(e["tags"])
        if e["retag_only"]:
            w(f"  retag  {os.path.basename(e['src'])}  [{tags}]")
        else:
            w(f"  {os.path.basename(e['src'])}  ->  {os.path.basename(e['dst'])}  [{tags}]")
    w("")
    w(f"Skipped, not regular files ({len(plan['skipped'])}):")
    for rel, kind in plan["skipped"]:
        w(f"  {kind:8} {rel}")
    w("")
    w(f"Needs review, md5 unknown ({len(plan['needs_review'])}):")
    for r in plan["needs_review"]:
        w(f"  {r}")
    w("")
    w(f"Needs manual ({len(plan['needs_manual'])}):")
    for rel, why in plan["needs_manual"]:
        w(f"  {rel}  ({why})")
    return "\n".join(out) + "\n"


def post(title, msg):
    if IS_MAC and shutil.which("osascript"):
        script = f"display notification {json.dumps(msg)} with title {json.dumps(title)}"
        subprocess.run(["osascript", "-e", script], check=False)
    else:
        log(f"notify: {title}: {msg}")


def notify(plan):
    c = section_counts(plan)
    msg = (f"archive {c['archive'][0]}, merge {c['snapshot-merge'][0]}, snapshot {c['snapshot'][0]},"
           f" dupes {c['dupes'][0]}, credit {c['credit'][0]}. Run: docs-tidy show")
    post(f"docs-tidy plan {plan['date']}", msg)


# ---------------------------------------------------------------- commands


def newest_plan(sd):
    hits = sorted(glob.glob(os.path.join(sd, "plan-*.json")))
    if not hits:
        raise Refuse(f"no plan in {sd}; run: docs-tidy plan")
    return hits[-1]


def load_plan(path):
    path = path or newest_plan(state_dir())
    with open(path) as f:
        return json.load(f), path


def cmd_plan(args):
    day = today()
    doc = doc_root()
    if not os.path.isdir(doc):
        raise Refuse(f"Documents root missing: {doc}")
    plan = build_plan(doc, drive_root(), drivefs_dir(), day)
    sd = state_dir()
    os.makedirs(sd, exist_ok=True)
    base = os.path.join(sd, f"plan-{plan['date']}")
    with open(base + ".json", "w") as f:
        json.dump(plan, f, indent=1)
        f.write("\n")
    text = summary(plan)
    with open(base + ".txt", "w") as f:
        f.write(text)
    sys.stdout.write(text)
    log(f"\nWrote {base}.json and {base}.txt")
    if args.notify:
        notify(plan)
    return 0


def cmd_show(args):
    plan, _ = load_plan(args.plan)
    sys.stdout.write(summary(plan))
    return 0


def cleanup_one(d):
    """rmdir d when it holds only .DS_Store/.localized; return True if removed.

    Never touches a directory that still holds anything else.
    """
    try:
        names = os.listdir(d)
    except OSError:
        return False
    if any(n not in SKIPNAMES for n in names):
        return False
    for n in names:
        p = os.path.join(d, n)
        if os.path.isfile(p) and not os.path.islink(p):
            os.remove(p)
    try:
        os.rmdir(d)
    except OSError:
        return False
    return True


def cleanup_tree(root, stop):
    """Bottom-up cleanup of a moved tree, then of its parents up to (not including) stop."""
    stop = os.path.abspath(stop)
    root = os.path.abspath(root)
    if os.path.isdir(root) and not os.path.islink(root):
        for r, _dirs, _names in os.walk(root, topdown=False):
            if r != root:
                cleanup_one(r)
        d = root
    else:
        d = os.path.dirname(root)
    while d != stop and d.startswith(stop + os.sep) and cleanup_one(d):
        d = os.path.dirname(d)


def move_file(e):
    """Copy, verify, delete. Return (status, md5, note); status is OK or ERR."""
    src, dst = e["src"], e["dst"]
    if not os.path.lexists(src):
        if os.path.exists(dst):
            return "OK", e.get("md5") or "", "already done"
        return "ERR", e.get("md5") or "", "source missing and destination absent"
    st = os.lstat(src)
    if not stat.S_ISREG(st.st_mode):
        return "ERR", "", "source is no longer a regular file"
    h = md5_with_retry(src, is_dataless(st))
    if e.get("md5") and h != e["md5"]:
        return "ERR", h, f"source changed since plan ({e['md5']} -> {h})"
    if os.path.lexists(dst):
        if not os.path.isfile(dst) or md5_file(dst) != h:
            return "ERR", h, "destination exists with different content"
        os.remove(src)
        return "OK", h, "destination already had it"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    for attempt in range(4):
        try:
            shutil.copy2(src, dst)
            break
        except OSError as ex:
            if ex.errno not in (60, errno.ETIMEDOUT) or attempt == 3:
                raise
            brctl_download(src)
            time.sleep(1)
    if md5_file(dst) != h:
        os.remove(dst)
        return "ERR", h, "copy verification failed"
    os.remove(src)
    return "OK", h, ""


def unit_newest(doc, unit):
    p = os.path.join(doc, unit)
    ts = []
    if os.path.isfile(p) and not os.path.islink(p):
        return os.lstat(p).st_mtime
    for r, _d, names in os.walk(p):
        for n in names:
            if n in SKIPNAMES:
                continue
            st = os.lstat(os.path.join(r, n))
            if stat.S_ISREG(st.st_mode):
                ts.append(st.st_mtime)
    return max(ts) if ts else None


def cmd_apply(args):
    plan, path = load_plan(args.plan)
    day = today()
    skip = set(args.skip or [])
    bad = skip - set(SECTIONS)
    if bad:
        raise Refuse(f"unknown section(s) for --skip: {sorted(bad)}; valid: {SECTIONS}")
    plan_day = datetime.date.fromisoformat(plan["date"])
    age = (day - plan_day).days
    if age > MAX_PLAN_AGE_DAYS:
        raise Refuse(f"plan {path} is {age} days old (max {MAX_PLAN_AGE_DAYS}); re-run: docs-tidy plan")
    doc, drive = plan["doc"], plan["drive"]
    if not os.path.isdir(drive):
        raise Refuse(f"Drive root missing: {drive}")
    todo = [e for e in plan["entries"] if e["section"] not in skip]
    need = sum(e["size"] for e in todo if e.get("dataless")) + FREE_RESERVE
    free = shutil.disk_usage(doc).free
    if free < need:
        raise Refuse(f"free space {human(free)} on the Documents volume is below {human(need)}"
                     " (dataless sources plus 2 GiB)")

    cut = cutoff_ts(plan_day)
    results = []  # (status, section, md5, src, dst, note)
    skipped_units = []
    moved_roots = set()
    date = day.isoformat()
    credit_log = []
    t0 = time.time()

    for section in SECTIONS:
        if section in skip:
            log(f"skip section {section}")
            continue
        ents = [e for e in plan["entries"] if e["section"] == section]
        if not ents:
            continue
        log(f"{section}: {len(ents)} entries")
        bad_units = set()
        if section == "archive":
            for u in sorted({e["unit"] for e in ents}):
                n = unit_newest(doc, u)
                if n is not None and n >= cut:
                    bad_units.add(u)
                    skipped_units.append((u, n))
                    log(f"  unit changed since plan, skipped: {u} (newest {fmt_ts(n)})")
        for i, e in enumerate(ents):
            if section == "archive" and e["unit"] in bad_units:
                continue
            try:
                if section == "credit":
                    st, h, note = apply_credit(e, credit_log)
                else:
                    st, h, note = move_file(e)
            except Exception as ex:  # record and continue; one file must not stop the run
                st, h, note = "ERR", e.get("md5") or "", f"{type(ex).__name__}: {ex}"
            results.append((st, section, h, e["src"], e["dst"], note))
            if st == "OK" and section != "credit":
                if section == "archive":
                    moved_roots.add(os.path.join(doc, e["unit"]))
                elif section in ("snapshot", "snapshot-merge"):
                    moved_roots.add(os.path.join(doc, top(e["rel"])))
                else:
                    # The file itself, so cleanup only walks upward from it and
                    # never sweeps sibling directories nothing moved from.
                    moved_roots.add(e["src"])
            if st == "ERR":
                log(f"  ERR {e['src']}: {note}")
            if (i + 1) % 500 == 0:
                log(f"  {i + 1}/{len(ents)}  {time.time() - t0:.0f}s")

    ok = [r for r in results if r[0] == "OK"]
    errs = [r for r in results if r[0] == "ERR"]
    # Credit entries rename in place, so they never belong in the pointer.
    moved = [r for r in ok if r[1] != "credit"]
    # Pointers first: writing tax/ARCHIVED-YEARS.txt keeps tax/ from being
    # removed as empty when its last year moves.
    if moved:
        write_pointer(plan, moved, date)
    for root in sorted(moved_roots, key=len, reverse=True):
        cleanup_tree(root, doc)
    if credit_log:
        lp = os.path.join(doc, CREDIT, f".rename-log-{date}.tsv")
        new = not os.path.exists(lp)
        with open(lp, "a") as f:
            if new:
                f.write("old_name\tnew_name\ttags\n")
            for row in credit_log:
                f.write("\t".join(row) + "\n")
    sd = state_dir()
    os.makedirs(sd, exist_ok=True)
    with open(os.path.join(sd, f"apply-{date}.tsv"), "a") as f:
        for st, section, h, src, dst, note in results:
            f.write(f"{st}\t{section}\t{h}\t{src}\t{dst}" + (f"\t{note}" if note else "") + "\n")

    by = {}
    for st, section, *_ in results:
        by.setdefault(section, [0, 0])[0 if st == "OK" else 1] += 1
    log("")
    for s in SECTIONS:
        if s in by:
            log(f"{s:15} ok {by[s][0]:6}  err {by[s][1]:6}")
    for u, n in skipped_units:
        log(f"skipped unit (changed since plan): {u}  newest {fmt_ts(n)}")
    log(f"done in {time.time() - t0:.0f}s; log: {os.path.join(sd, f'apply-{date}.tsv')}")
    if errs:
        log(f"\n{len(errs)} error(s):")
        for _st, section, _h, src, _dst, note in errs:
            log(f"  [{section}] {src}: {note}")
        return 1
    return 0


def apply_credit(e, credit_log):
    src, dst = e["src"], e["dst"]
    old, new = os.path.basename(src), os.path.basename(dst)
    if not e["retag_only"]:
        if not os.path.lexists(src):
            if not os.path.exists(dst):
                return "ERR", "", "source missing and destination absent"
        else:
            if os.path.lexists(dst):
                return "ERR", "", "destination exists"
            if e.get("md5") and md5_file(src) != e["md5"]:
                return "ERR", "", "source changed since plan"
            os.rename(src, dst)
    elif not os.path.exists(dst):
        return "ERR", "", "file missing"
    tagged = write_tags(dst, e["tags"])
    credit_log.append((old, new, ",".join(e["tags"])))
    return "OK", e.get("md5") or "", "" if tagged else "tags skipped (not macOS)"


def write_pointer(plan, ok, date):
    doc, drive = plan["doc"], plan["drive"]
    by = {}
    for _st, section, _h, src, dst, _n in ok:
        by.setdefault(section, []).append((src, dst))
    lines = [f"\nOn {date}, docs-tidy (plan {plan['date']}, cutoff {plan['cutoff']}) moved:\n"]
    if "archive" in by:
        done_src = {src for src, _ in by["archive"]}
        done_units = sorted({e["unit"] for e in plan["entries"]
                             if e["section"] == "archive" and e["src"] in done_src})
        lines.append(f"  archive: {len(by['archive'])} files in {len(done_units)} top-level items, unchanged since"
                     f" before {plan['cutoff']}, to\n    {os.path.join(drive, 'Documents Archive')}\n")
        for u in done_units:
            lines.append(f"      {u}\n")
    if "snapshot-merge" in by:
        lines.append(f"  snapshot-merge: {len(by['snapshot-merge'])} files that existed only in a machine snapshot,"
                     " merged into this folder at the same relative paths\n")
    for s, label in (("snapshot", "machine-snapshot files"), ("dupes", "duplicate files")):
        if s in by:
            lines.append(f"  {s}: {len(by[s])} {label} to\n"
                         f"    {os.path.join(drive, 'probably-dupes', plan['date'])}\n")
    lines.append("  Every move was copy, verify checksum, then delete the original.\n")
    with open(os.path.join(doc, POINTER), "a") as f:
        f.writelines(lines)
    done_src = {src for src, _ in by.get("archive", [])}
    years = sorted({e["unit"][4:] for e in plan["entries"]
                    if e["section"] == "archive" and e["unit"].startswith("tax/") and e["src"] in done_src})
    if years:
        tdir = os.path.join(doc, "tax")
        if os.path.isdir(tdir):
            with open(os.path.join(tdir, TAX_POINTER), "a") as f:
                f.write(f"\nOn {date}, these tax years moved to Google Drive:\n  {', '.join(years)}\n\n"
                        f"Location:\n  {os.path.join(drive, 'Documents Archive', 'tax')}\n")


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="docs-tidy",
        description="Quarterly ~/Documents tidy: plan, then approve. `plan` changes nothing on disk except"
                    " the state dir; nothing moves until you run `apply`.",
        epilog="Sections: " + ", ".join(SECTIONS) + ". State dir: $DOCS_TIDY_STATE or ~/.local/state/docs-tidy."
               " Other overrides: DOCS_TIDY_DOC, DOCS_TIDY_DRIVE, DOCS_TIDY_DRIVEFS (none disables),"
               " DOCS_TIDY_TODAY (YYYY-MM-DD).",
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("plan", help="inventory Documents and write plan-YYYY-MM-DD.{json,txt}")
    sp.add_argument("--notify", action="store_true", help="post a macOS notification with the counts")
    ss = sub.add_parser("show", help="print the text summary of a plan")
    ss.add_argument("plan", nargs="?", help="plan JSON (default: newest in the state dir)")
    sa = sub.add_parser("apply", help="execute a plan: copy, verify, delete")
    sa.add_argument("plan", nargs="?", help="plan JSON (default: newest in the state dir)")
    sa.add_argument("--skip", action="append", metavar="SECTION", choices=SECTIONS,
                    help="skip a section; repeat for more: " + ", ".join(SECTIONS))
    args = p.parse_args(argv)
    # Under launchd nobody reads stderr, so a failed --notify plan must say so.
    alert = args.cmd == "plan" and args.notify
    try:
        return {"plan": cmd_plan, "show": cmd_show, "apply": cmd_apply}[args.cmd](args)
    except Refuse as e:
        print(f"docs-tidy: refused: {e}", file=sys.stderr)
        if alert:
            post("docs-tidy plan FAILED", str(e))
        return 2
    except Exception as e:
        if alert:
            post("docs-tidy plan FAILED", f"{type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    sys.exit(main())
