#!/usr/bin/env python3
"""Export scrubber for the gtm-engine repo.

Reads raw n8n exports and the raw SQL dump, writes scrubbed copies into the repo.
Every replacement is listed in RULES so the scrub is auditable.
"""
import json, re, sys, os, pathlib, collections

S = pathlib.Path(sys.argv[1])          # scratchpad
REPO = pathlib.Path(sys.argv[2])       # repo root
RAW = S / "raw"

# ---- rules live in an untracked file so the real identifiers never enter the repo ----
# tools/scrub_rules.local.json = {"workflows": {"<n8n id>": ["folder", "slug"], ...},
#                                 "rules": [["<regex>", "<replacement>"], ...],   # applied in order
#                                 "credentials": {"<live credential name>": ["CRED_X", "Display name"], ...}}
# docs/SCRUBBING.md describes every category of rule used for this repo.
_cfg = json.load(open(pathlib.Path(__file__).with_name("scrub_rules.local.json")))
WORKFLOWS = {k: tuple(v) for k, v in _cfg["workflows"].items()}
RULES = [tuple(x) for x in _cfg["rules"]]
COMPILED = [(re.compile(p), r) for p, r in RULES]
CRED_NAMES = {k: tuple(v) for k, v in _cfg["credentials"].items()}

DROP_TOP = {"shared", "activeVersion", "activeVersionId", "versionId", "versionCounter", "sourceWorkflowId",
            "triggerCount", "createdAt", "updatedAt", "isArchived", "meta", "pinData", "staticData", "active"}

webhook_ids = {}
def webhook_placeholder(v):
    if v not in webhook_ids:
        webhook_ids[v] = "00000000-0000-4000-8000-%012d" % (len(webhook_ids) + 1)
    return webhook_ids[v]

wf_slug = {wid: f"WF_{slug.upper().replace('-', '_')}" for wid, (_, slug) in WORKFLOWS.items()}
hits = collections.Counter()

def scrub_text(s):
    for wid, slug in wf_slug.items():
        if wid in s:
            s = s.replace(wid, slug); hits[wid] += 1
    for pat, rep in COMPILED:
        s, n = pat.subn(rep, s)
        if n: hits[pat.pattern] += n
    return s

def walk(o, key=None):
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
                out[scrub_text(k)] = walk(v, k)
        return out
    if isinstance(o, list):
        return [walk(x) for x in o]
    if isinstance(o, str):
        return scrub_text(o)
    return o

def do_workflows():
    for wid, (folder, slug) in WORKFLOWS.items():
        src = RAW / f"{wid}.json"
        wf = json.loads(src.read_text())
        wf = {k: v for k, v in wf.items() if k not in DROP_TOP}
        wf["id"] = wf_slug[wid]
        wf = walk(wf)
        # node ids are random uuids, harmless, keep. Drop per-node webhook paths that were random.
        dst = REPO / "workflows" / folder / f"{slug}.json"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")

def do_sql():
    parts = [(RAW / "sql" / "0001_schema.sql").read_text()]
    fn = "\n\n".join((RAW / "sql" / f"fn_0{i}.sql").read_text().rstrip("\n") for i in range(1, 6))
    out_dir = REPO / "supabase" / "migrations"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "0001_schema.sql").write_text(scrub_text(parts[0]))
    (out_dir / "0002_functions.sql").write_text(scrub_text(fn) + "\n")

def do_text_file(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(scrub_text(pathlib.Path(src).read_text()))

if __name__ == "__main__":
    do_workflows()
    do_sql()
    for extra in sys.argv[3:]:
        a, b = extra.split("=", 1)
        do_text_file(a, REPO / b)
    for k, v in sorted(hits.items(), key=lambda x: -x[1]):
        print(f"{v:5d}  {k}")
    print("webhook ids:", len(webhook_ids))
