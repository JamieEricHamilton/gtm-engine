#!/usr/bin/env python3
"""Export scrubber for the gtm-engine repo.

Two modes.

Scrub (the export path):
    python3 tools/scrub.py <scratchpad> <repo-root> [src=dst ...]
  Reads raw n8n exports and the raw SQL dump, writes scrubbed copies into the repo. Every
  replacement is listed in tools/scrub_rules.local.json, which is not committed because it contains
  the identifiers it removes. docs/SCRUBBING.md describes every category of rule.

Check (what CI runs on every push):
    python3 tools/scrub.py --check [repo-root]
  Fails if anything that should have been scrubbed has slipped back into the tree:
  - an n8n credential id that is not a CRED_* placeholder, or a webhook id that is not the
    0000...-0000-4000-8000-nnnnnnnnnnnn placeholder
  - a Google Sheet id that is not a SHEET_ID_* placeholder (documentId values and
    docs.google.com/spreadsheets/d/<id> links)
  - a real Supabase project ref (20 lowercase chars before .supabase.co)
  - a hostname that is not in tools/allowed_hosts.txt (so a new n8n/webhook host or an internal
    tool's domain cannot appear without a deliberate allowlist change)
  - a public IPv4 address
  - a Telegram chatId that is a literal number rather than the placeholder or an expression
  - any term in the denylist: the SCRUB_DENYLIST environment variable (comma separated, set as a
    CI secret) and/or the "deny" list in tools/scrub_rules.local.json. Terms are matched as whole
    lowercase word tokens so the terms themselves never appear in the repo.
  When neither denylist source is present the term check is reported as skipped, not passed.
"""
import collections
import json
import os
import pathlib
import re
import sys

# ---------------------------------------------------------------------------------------------
# check mode
# ---------------------------------------------------------------------------------------------

TEXT_SUFFIXES = {".json", ".md", ".sql", ".py", ".sh", ".yml", ".yaml", ".toml", ".txt", ".html",
                 ".js", ".cron", ".example", ".xml", ".Caddyfile"}
TEXT_NAMES = {"Caddyfile", ".env.example", "_headers", "_redirects", "LICENSE"}
SKIP_DIRS = {".git", "__pycache__", "node_modules", "dist", "raw"}

RE_HOST = re.compile(r"https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?=[/:\"'\s)>\]]|$)")
RE_SUPABASE_REF = re.compile(r"\b([a-z]{20})\.supabase\.co\b")
RE_SHEET_URL = re.compile(r"spreadsheets/d/([A-Za-z0-9_-]+)")
RE_IPV4 = re.compile(r"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b")
RE_CRED_ID = re.compile(r"^CRED_[A-Z0-9_]+$")
RE_WEBHOOK = re.compile(r"^00000000-0000-4000-8000-\d{12}$")
RE_SHEET_PLACEHOLDER = re.compile(r"SHEET_ID_[A-Z_]+")
RE_WORD = re.compile(r"[a-z0-9]+")


def text_files(root):
    for p in sorted(root.rglob("*")):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.is_file() and (p.suffix in TEXT_SUFFIXES or p.name in TEXT_NAMES):
            yield p


def private_ip(a, b, c, d):
    a, b = int(a), int(b)
    return a in (0, 10, 127) or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168) or a == 169


def walk_json(o, found):
    """Collect credential ids, webhook ids, documentId values and chatId values from n8n JSON."""
    if isinstance(o, dict):
        if "credentials" in o and isinstance(o["credentials"], dict):
            for c in o["credentials"].values():
                if isinstance(c, dict):
                    found["cred_ids"].append(str(c.get("id", "")))
        if isinstance(o.get("webhookId"), str):
            found["webhook_ids"].append(o["webhookId"])
        doc = o.get("documentId")
        if isinstance(doc, dict) and isinstance(doc.get("value"), str):
            found["sheet_values"].append(doc["value"])
        for key in ("chatId", "chat_id"):
            v = o.get(key)
            if isinstance(v, (str, int)):
                found["chat_ids"].append(str(v))
        for v in o.values():
            walk_json(v, found)
    elif isinstance(o, list):
        for v in o:
            walk_json(v, found)


def load_denylist(root):
    terms = set()
    env = os.environ.get("SCRUB_DENYLIST", "")
    terms.update(t.strip().lower() for t in env.split(",") if t.strip())
    local = root / "tools" / "scrub_rules.local.json"
    if local.exists():
        try:
            terms.update(t.lower() for t in json.load(open(local)).get("deny", []))
        except (OSError, ValueError):
            pass
    return terms


def check(root):
    root = pathlib.Path(root).resolve()
    problems = []
    allowed_hosts_file = root / "tools" / "allowed_hosts.txt"
    allowed_hosts = {ln.strip() for ln in allowed_hosts_file.read_text().splitlines()
                     if ln.strip() and not ln.startswith("#")} if allowed_hosts_file.exists() else set()
    deny = load_denylist(root)
    seen_hosts = collections.Counter()

    for p in text_files(root):
        rel = p.relative_to(root)
        if rel == pathlib.Path("tools/allowed_hosts.txt"):
            continue
        text = p.read_text(errors="replace")

        for host in RE_HOST.findall(text):
            seen_hosts[host.lower()] += 1
            if host.lower() not in allowed_hosts:
                problems.append(f"{rel}: hostname not in tools/allowed_hosts.txt: {host}")
        for ref in RE_SUPABASE_REF.findall(text):
            problems.append(f"{rel}: looks like a real Supabase project ref: {ref}.supabase.co")
        for sid in RE_SHEET_URL.findall(text):
            if not RE_SHEET_PLACEHOLDER.fullmatch(sid):
                problems.append(f"{rel}: Google Sheet id in a link is not a SHEET_ID_* placeholder: {sid}")
        for m in RE_IPV4.finditer(text):
            if not private_ip(*m.groups()) and all(int(g) < 256 for g in m.groups()):
                problems.append(f"{rel}: public IPv4 address: {m.group(0)}")
        if deny:
            words = set(RE_WORD.findall(text.lower()))
            for t in sorted(deny & words):
                problems.append(f"{rel}: denylisted term present (token #{sorted(deny).index(t) + 1})")

        if p.suffix == ".json" and rel.parts[0] == "workflows":
            found = collections.defaultdict(list)
            try:
                walk_json(json.loads(text), found)
            except ValueError as e:
                problems.append(f"{rel}: invalid JSON: {e}")
                continue
            for cid in found["cred_ids"]:
                if not RE_CRED_ID.match(cid):
                    problems.append(f"{rel}: credential id is not a CRED_* placeholder: {cid}")
            for wid in found["webhook_ids"]:
                if not RE_WEBHOOK.match(wid):
                    problems.append(f"{rel}: webhook id is not the placeholder pattern: {wid}")
            for v in found["sheet_values"]:
                if v.startswith("={{"):
                    bare = re.sub(r"[^A-Za-z0-9_-]+", " ", v)
                    for tok in bare.split():
                        if len(tok) >= 30 and not RE_SHEET_PLACEHOLDER.fullmatch(tok):
                            problems.append(f"{rel}: sheet id inside an expression: {tok}")
                elif not RE_SHEET_PLACEHOLDER.fullmatch(v):
                    problems.append(f"{rel}: documentId is not a SHEET_ID_* placeholder: {v}")
            for c in found["chat_ids"]:
                if c != "TELEGRAM_CHAT_ID" and not c.startswith("={{") and re.fullmatch(r"-?\d{6,}", c):
                    problems.append(f"{rel}: literal Telegram chat id: {c}")

    for pr in problems:
        print("FAIL", pr)
    status = "skipped (no SCRUB_DENYLIST and no local rules)" if not deny else f"checked {len(deny)} terms"
    print(f"hosts seen: {len(seen_hosts)}; denylist: {status}; problems: {len(problems)}")
    return 1 if problems else 0


# ---------------------------------------------------------------------------------------------
# scrub mode
# ---------------------------------------------------------------------------------------------

DROP_TOP = {"shared", "activeVersion", "activeVersionId", "versionId", "versionCounter", "sourceWorkflowId",
            "triggerCount", "createdAt", "updatedAt", "isArchived", "meta", "pinData", "staticData", "active"}


def scrub(scratch, repo, extras):
    S = pathlib.Path(scratch)
    REPO = pathlib.Path(repo)
    RAW = S / "raw"
    _cfg = json.load(open(pathlib.Path(__file__).with_name("scrub_rules.local.json")))
    WORKFLOWS = {k: tuple(v) for k, v in _cfg["workflows"].items()}
    COMPILED = [(re.compile(p), r) for p, r in (tuple(x) for x in _cfg["rules"])]
    CRED_NAMES = {k: tuple(v) for k, v in _cfg["credentials"].items()}
    wf_slug = {wid: f"WF_{slug.upper().replace('-', '_')}" for wid, (_, slug) in WORKFLOWS.items()}
    hits = collections.Counter()
    webhook_ids = {}

    def webhook_placeholder(v):
        if v not in webhook_ids:
            webhook_ids[v] = "00000000-0000-4000-8000-%012d" % (len(webhook_ids) + 1)
        return webhook_ids[v]

    def scrub_text(s):
        for wid, slug in wf_slug.items():
            if wid in s:
                s = s.replace(wid, slug)
                hits[wid] += 1
        for pat, rep in COMPILED:
            s, n = pat.subn(rep, s)
            if n:
                hits[pat.pattern] += n
        return s

    def walk(o):
        if isinstance(o, dict):
            out = {}
            for k, v in o.items():
                if k == "credentials" and isinstance(v, dict):
                    nv = {}
                    for ctype, c in v.items():
                        cid, cname = CRED_NAMES.get(c.get("name"), ("CRED_" + ctype.upper(), c.get("name")))
                        nv[ctype] = {"id": cid, "name": cname}
                    out[k] = nv
                elif k == "webhookId" and isinstance(v, str):
                    out[k] = webhook_placeholder(v)
                else:
                    out[scrub_text(k)] = walk(v)
            return out
        if isinstance(o, list):
            return [walk(x) for x in o]
        if isinstance(o, str):
            return scrub_text(o)
        return o

    for wid, (folder, slug) in WORKFLOWS.items():
        wf = json.loads((RAW / f"{wid}.json").read_text())
        wf = {k: v for k, v in wf.items() if k not in DROP_TOP}
        wf["id"] = wf_slug[wid]
        wf = walk(wf)
        dst = REPO / "workflows" / folder / f"{slug}.json"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")

    schema = (RAW / "sql" / "0001_schema.sql").read_text()
    fn = "\n\n".join((RAW / "sql" / f"fn_0{i}.sql").read_text().rstrip("\n") for i in range(1, 6))
    out_dir = REPO / "supabase" / "migrations"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "0001_schema.sql").write_text(scrub_text(schema))
    (out_dir / "0002_functions.sql").write_text(scrub_text(fn) + "\n")

    for extra in extras:
        a, b = extra.split("=", 1)
        dst = REPO / b
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(scrub_text(pathlib.Path(a).read_text()))

    for k, v in sorted(hits.items(), key=lambda x: -x[1]):
        print(f"{v:5d}  {k}")
    print("webhook ids:", len(webhook_ids))


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--check":
        sys.exit(check(sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[1]))
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    scrub(sys.argv[1], sys.argv[2], sys.argv[3:])
