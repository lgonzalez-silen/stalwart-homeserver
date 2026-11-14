#!/usr/bin/env python3
"""
mbox2maildir.py: convert one user's Dovecot mbox store into a Maildir++ tree for `vandelay import maildir`.

  python3 -I mbox2maildir.py --mail-dir /var/lib/migrate/alice/mail \
      --spool /var/lib/migrate/alice/spool-INBOX --out /var/lib/migrate/alice-maildir \
      [--exclude '^Old-Backup$'] [--dry-run]

Rewritten 2026-11-07 (the earlier version skipped nested folders, stamped every message with the
conversion time, mangled names, and re-serialized messages through the email package).

What it does
- Walks --mail-dir recursively: every regular file is an mbox folder; its relative path is the folder
  name, "/" = hierarchy. --spool becomes INBOX (Maildir root). Dovecot index files are skipped.
- Splits messages on "From " lines, using Dovecot's Content-Length when it lands on a boundary (so
  unescaped "From " lines inside bodies don't split a message), else the next "\\nFrom " line.
- Message bytes are copied verbatim, except Dovecot's own bookkeeping headers are removed
  (X-IMAPbase, X-IMAP, X-UID, Status, X-Status, X-Keywords, Content-Length): IMAP clients never saw them.
- Flags: Status R -> S (seen); X-Status A -> R (answered), F -> F (flagged), T -> D (draft),
  D -> T (deleted, which Vandelay skips by default); X-Keywords $Forwarded/Forwarded -> P.
- Received date: from the "From " line (mbox delivery time); used in the Maildir file name (which
  Vandelay reads as the received time) and as the file mtime.
- Names: Maildir++ uses "." as the hierarchy separator, so a literal "." inside a folder name is
  written as U+2024 (ONE DOT LEADER); rename back after export (see manifest).
- Writes <out>/manifest.tsv: folder, maildir_dir, messages, deleted_skipped_by_vandelay, bytes.
"""
import argparse
import mmap
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

DOT = "․"
SKIP_FILES = re.compile(r"^(dovecot.*|\.subscriptions|subscriptions|\.imap)$")
DROP_HEADERS = {b"x-imapbase", b"x-imap", b"x-uid", b"status", b"x-status", b"x-keywords", b"content-length"}
def _site_tz():
    import json, os
    try:
        return json.load(open(os.environ.get("NV_SITE", "/etc/nv/site.json")))["server"].get("timezone") or "UTC"
    except (OSError, ValueError, KeyError):
        return "UTC"


TZ = timezone.utc   # set in main() from --tz / site.json
FROM_RE = re.compile(rb"^From \S+\s+(\w{3} \w{3}\s+\d{1,2} \d{2}:\d{2}:\d{2}) (\d{4})")


def from_line_ts(line: bytes, fallback: float) -> int:
    m = FROM_RE.match(line)
    if not m:
        return int(fallback)
    try:
        s = (m.group(1) + b" " + m.group(2)).decode()
        s = re.sub(r"\s+", " ", s)
        # mbox From_ dates are in the OLD server's local time: --tz, else server.timezone in site.json, else UTC
        return int(datetime.strptime(s, "%a %b %d %H:%M:%S %Y").replace(tzinfo=TZ).timestamp())
    except ValueError:
        return int(fallback)


def split_headers(raw: bytes):
    """Return (header_block, body) where header_block excludes the blank separator line."""
    i = raw.find(b"\n\n")
    if i < 0:
        return raw, b""
    return raw[: i + 1], raw[i + 2 :]


def parse_header_lines(hdr: bytes):
    """Yield (name_lower, full_line_bytes_including_continuations)."""
    cur_name, cur = None, []
    for line in hdr.splitlines(keepends=True):
        if line[:1] in (b" ", b"\t") and cur:
            cur.append(line)
            continue
        if cur:
            yield cur_name, b"".join(cur)
        name = line.split(b":", 1)[0].strip().lower() if b":" in line else b""
        cur_name, cur = name, [line]
    if cur:
        yield cur_name, b"".join(cur)


def iter_messages(data):
    """Yield (from_line, raw_message_bytes) from an mbox mmap/bytes."""
    n = len(data)
    pos = 0
    if not data[:5] == b"From ":
        nxt = data.find(b"\nFrom ")
        if nxt < 0:
            return
        pos = nxt + 1
    while pos < n:
        eol = data.find(b"\n", pos)
        if eol < 0:
            return
        from_line = bytes(data[pos:eol])
        start = eol + 1
        hdr_end = data.find(b"\n\n", start)
        end = -1
        if hdr_end >= 0:
            m = re.search(rb"(?im)^Content-Length:\s*(\d+)\s*$", bytes(data[start:hdr_end + 1]))
            if m:
                cand = hdr_end + 2 + int(m.group(1))
                # Dovecot: message, then one "\n", then next "From "
                if cand >= n or data[cand:cand + 6] == b"\nFrom " or data[cand:cand + 5] == b"From ":
                    end = cand
        if end < 0:
            nxt = data.find(b"\nFrom ", hdr_end if hdr_end >= 0 else start)
            end = nxt + 1 if nxt >= 0 else n
        raw = bytes(data[start:end])
        yield from_line, raw
        # advance to the next From line
        if end >= n:
            return
        nxt = end if data[end:end + 5] == b"From " else data.find(b"\nFrom ", end - 1)
        if nxt < 0:
            return
        pos = nxt if data[nxt:nxt + 5] == b"From " else nxt + 1


def convert_message(raw: bytes):
    hdr, body = split_headers(raw)
    flags, keep = set(), []
    for name, line in parse_header_lines(hdr):
        if name in DROP_HEADERS:
            val = line.split(b":", 1)[1] if b":" in line else b""
            if name == b"status" and b"R" in val:
                flags.add("S")
            elif name == b"x-status":
                if b"A" in val: flags.add("R")
                if b"F" in val: flags.add("F")
                if b"T" in val: flags.add("D")
                if b"D" in val: flags.add("T")
            elif name == b"x-keywords" and re.search(rb"(^|\s)\$?Forwarded(\s|$)", val):
                flags.add("P")
            continue
        keep.append(line)
    # mbox stores a trailing "\n" separator before the next From line; drop exactly one
    if body.endswith(b"\n\n"):
        body = body[:-1]
    return b"".join(keep) + b"\n" + body, "".join(sorted(flags))


def maildir_name(folder: str) -> str:
    return "." + ".".join(p.replace(".", DOT) for p in folder.split("/"))


def write_folder(mbox: Path, dest: Path, label: str, dry: bool, seq: list):
    count = deleted = size = 0
    if not dry:
        for sub in ("cur", "new", "tmp"):
            (dest / sub).mkdir(parents=True, exist_ok=True)
    fallback = mbox.stat().st_mtime
    with open(mbox, "rb") as fh:
        if os.fstat(fh.fileno()).st_size == 0:
            return 0, 0, 0
        data = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            for from_line, raw in iter_messages(data):
                msg, flags = convert_message(raw)
                ts = from_line_ts(from_line, fallback)
                count += 1
                size += len(msg)
                if "T" in flags:
                    deleted += 1
                if dry:
                    continue
                seq[0] += 1
                fn = dest / "cur" / f"{ts}.M{seq[0]}P{os.getpid()}.nvconvert:2,{flags}"
                with open(fn, "wb") as out:
                    out.write(msg)
                os.utime(fn, (ts, ts))
        finally:
            data.close()
    return count, deleted, size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mail-dir", required=True)
    ap.add_argument("--spool")
    ap.add_argument("--out", required=True)
    ap.add_argument("--exclude", action="append", default=[], help="regex on folder name (repeatable)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--tz", help="old server's time zone for From_ dates (default: server.timezone in site.json, else UTC)")
    a = ap.parse_args()
    global TZ
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo(a.tz or _site_tz())

    mail_dir, out = Path(a.mail_dir), Path(a.out)
    if not a.dry_run:
        if out.exists() and any(out.iterdir()):
            sys.exit(f"{out} exists and is not empty; remove it first (conversion is not incremental)")
        out.mkdir(parents=True, exist_ok=True)
        for sub in ("cur", "new", "tmp"):  # Vandelay requires the root (INBOX) even if empty
            (out / sub).mkdir(exist_ok=True)
    excl = [re.compile(x) for x in a.exclude]

    jobs = []
    if a.spool and Path(a.spool).is_file():
        jobs.append(("INBOX", Path(a.spool), out))
    for p in sorted(mail_dir.rglob("*")):
        if not p.is_file() or any(SKIP_FILES.match(part) for part in p.relative_to(mail_dir).parts):
            continue
        folder = p.relative_to(mail_dir).as_posix()
        if folder.upper() == "INBOX":
            if any(j[0] == "INBOX" for j in jobs):
                sys.exit(f"{p} and --spool are both an INBOX: merge them first (or rename one), nothing converted")
            jobs.insert(0, ("INBOX", p, out))   # no spool: this file is the inbox
            continue
        if any(r.search(folder) for r in excl):
            print(f"skip (excluded): {folder}")
            continue
        jobs.append((folder, p, out / maildir_name(folder)))

    seq = [0]
    rows, total = [], 0
    t0 = time.time()
    for folder, src, dest in jobs:
        c, d, s = write_folder(src, dest, folder, a.dry_run, seq)
        rows.append((folder, dest.name if dest != out else "(root)", c, d, s))
        total += c
        print(f"{c:7d} msgs {d:5d} del {s/1e6:8.1f} MB  {folder}")
    print(f"TOTAL {total} messages in {len(rows)} folders, {time.time()-t0:.0f}s")
    if not a.dry_run:
        with open(out / "manifest.tsv", "w") as f:
            f.write("folder\tmaildir_dir\tmessages\tdeleted_skipped\tbytes\n")
            for r in rows:
                f.write("\t".join(map(str, r)) + "\n")


if __name__ == "__main__":
    main()
