# nvlib: helpers shared by the server tools (nv-fetch, nv-spam-mirror, nv-google-trim, nv-junk-report,
# nv-set-password). Installed to /usr/local/lib/nv/ by recipe/09-ops.sh; the tools add that folder to sys.path.
# One place for: site settings, the Stalwart admin API (with error checking), uploads, the server's Message-ID index,
# and reading Gmail's special folders.
import json, os, urllib.request

API = "http://127.0.0.1:8080"
KEYFILE = "/root/.secrets/laptop-api.key"   # admin API key limited to 127.0.0.1/::1 (recipe/07)
MAIL = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
ADMIN = ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"]
_key = None


def site():
    """site.json, as installed by recipe/09 (NV_SITE overrides the path, for tests)."""
    return json.load(open(os.environ.get("NV_SITE", "/etc/nv/site.json")))


def key():
    global _key
    if _key is None:
        _key = open(KEYFILE).read().strip()
    return _key


class JmapError(RuntimeError):
    """A JMAP method answered with an error (unknownMethod, invalidArguments, forbidden, ...)."""


def jmap(calls, using=MAIL, timeout=120, check=True):
    """Run JMAP method calls; returns methodResponses. With check (default), a method-level error raises
    JmapError instead of being returned, so callers never mistake an error for an empty result."""
    r = urllib.request.Request(API + "/jmap/", data=json.dumps({"using": using, "methodCalls": calls}).encode(),
                               headers={"Authorization": "Bearer " + key(), "Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(r, timeout=timeout))["methodResponses"]
    if check:
        for name, args, tag in out:
            if name == "error":
                raise JmapError(f"{tag}: {args.get('type')} {args.get('description') or ''}".strip())
    return out


def upload(acct, raw, timeout=120):
    """Upload a raw message; returns its blobId. HTTP errors (e.g. 413 too large) are raised as urllib errors."""
    r = urllib.request.Request(f"{API}/jmap/upload/{acct}/", data=raw,
                               headers={"Authorization": "Bearer " + key(), "Content-Type": "message/rfc822"})
    return json.load(urllib.request.urlopen(r, timeout=timeout))["blobId"]


def mid(value):
    """A Message-ID as compared everywhere in these tools: without <>, whitespace or line breaks, case kept."""
    return str(value or "").strip("<> \r\n\t")


def message_ids(acct, skip_roles=(), skip_names=(), page=10000):
    """(ids, number of emails) for every message in the account, except those found only in folders with one of
    skip_roles (e.g. "trash", "junk") or a top-level folder named in skip_names."""
    mbs = jmap([["Mailbox/get", {"accountId": acct, "properties": ["role", "name", "parentId"]}, "m"]])[0][1]["list"]
    skip = [m["id"] for m in mbs if m.get("role") in skip_roles or (m.get("name") in skip_names and not m.get("parentId"))]
    flt = {"inMailboxOtherThan": skip} if skip else None
    ids, pos = [], 0
    while True:
        r = jmap([["Email/query", {"accountId": acct, "position": pos, "limit": page, "filter": flt}, "q"]])[0][1]
        if not r["ids"]:
            break
        ids += r["ids"]; pos += len(r["ids"])
    out = set()
    for i in range(0, len(ids), 500):
        for e in jmap([["Email/get", {"accountId": acct, "ids": ids[i:i + 500], "properties": ["messageId"]}, "g"]])[0][1]["list"]:
            out.update(mid(m) for m in (e.get("messageId") or []))
    return out, len(ids)


def gmail_folders(imap, want=("\\All", "\\Junk", "\\Trash")):
    """{special-use flag: folder name} from Gmail's LIST (the names are localized, the flags are not)."""
    typ, lines = imap.list()
    if typ != "OK":
        raise RuntimeError(f"IMAP LIST failed ({typ})")
    box = {}
    for line in lines:
        s = line.decode()
        flags, name = s.split(")")[0], s.rsplit(' "/" ', 1)[1]
        for f in want:
            if f in flags:
                box[f] = name
    return box
