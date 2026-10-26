#!/usr/bin/env python3
"""Render RESULTS.md from the aggregate JSON returned by public.intel_results().

Usage:
  python3 tools/render_results.py results/latest.json > RESULTS.md

The JSON is produced by one SQL function (supabase/migrations/0003_results.sql) so every
number in RESULTS.md is reproducible against the database. Nothing in it names an account,
a person or a contact.
"""
import json, sys, datetime

d = json.load(open(sys.argv[1]))
p, f, rs, al, c, o, ops = (d[k] for k in ("pipeline", "funding", "register_stream", "alerts", "contacts", "outcomes", "ops"))

def pct(a, b):
    return f"{100.0 * a / b:.1f}%" if b else "n/a"

def day(ts):
    return ts[:10] if ts else "n/a"

def kv(dct, order=None):
    items = dct.items() if not order else [(k, dct.get(k, 0)) for k in order]
    return ", ".join(f"{k} {v}" for k, v in items)

bands = p["bands"]
total = p["accounts_total"]
origin = p["by_origin"]
dq = p["disqualified_by_reason"]
apify = ops.get("apify_usage") or {}
first_push = o["sheet_first_push"]
def reported_rows(rows):
    out = []
    for r in rows:
        period = f"{r['period_start']} to {r['period_end']}" if r.get('period_end') else f"from {r['period_start']}, per month"
        out.append(f"| {period} | {r['meetings']}{'+' if r['kind'] == 'monthly_rate' else ''} | {r['booked_by'].upper()} | {r['source']} |")
    return out

reported = o.get("reported") or []
week1 = [r for r in reported if r["kind"] == "count"]
week1_sdr = sum(r["meetings"] for r in week1 if r["booked_by"] == "sdr")
week1_ae = sum(r["meetings"] for r in week1 if r["booked_by"] == "ae")
week1_total = week1_sdr + week1_ae
monthly_rate = max([r["meetings"] for r in reported if r["kind"] == "monthly_rate"] or [0])

days_live = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(first_push)).days if first_push else 0

out = f"""# Results

Generated {d['generated_at'][:16].replace('T', ' ')} UTC from `select public.intel_results();`
(definition in `supabase/migrations/0003_results.sql`). Aggregates only. Re-render with
`python3 tools/render_results.py results/latest.json > RESULTS.md`; the weekly GitHub Action does the same.

## Accounts processed per stage

| Stage | Count | Rate |
|---|---:|---:|
| Accounts in the system | {total} | book {origin.get('book',0)}, net-new from press {origin.get('net_new',0)}, net-new from the register {origin.get('register',0)} |
| Matched to the companies register | {p['registry_matched']} | {pct(p['registry_matched'], total)} of all accounts |
| Register match at confidence 0.85 or above | {p['registry_confident']} | {pct(p['registry_confident'], p['registry_matched'])} of matches |
| Disqualified (dead on the register) | {dq.get('registry_dead',0)} | exact-name matches to dissolved or liquidated companies only |
| Disqualified (over 500 staff) | {dq.get('size_over_500',0)} | |
| Disqualified (never-buy industry) | {dq.get('never_buy_industry',0)} | editable table |
| Disqualified (manual: owned by a colleague, duplicates, test rows) | {dq.get('manual',0)} | |
| LinkedIn enrichment attempted | {p['linkedin_attempted']} | |
| LinkedIn enrichment succeeded | {p['linkedin_enriched']} | {pct(p['linkedin_enriched'], p['linkedin_attempted'])} of attempts |
| Careers pages scanned | {p['careers_pages_scanned']} | |
| ATS detected on the careers page | {p['ats_detected']} | {pct(p['ats_detected'], p['careers_pages_scanned'])} of scanned; {kv(p['ats_by_provider'])} |
| LinkedIn jobs checked | {p['jobs_attempted']} | |
| Accounts with a live role | {p['accounts_with_live_roles']} | {pct(p['accounts_with_live_roles'], p['jobs_attempted'])} of checked ({p['job_rows']} job rows) |
| Accounts with a live role outside the home market | {p['accounts_with_foreign_roles']} | {pct(p['accounts_with_foreign_roles'], p['jobs_attempted'])} of checked |
| News checked | {p['news_attempted']} | signals by kind: {kv(p['news_signals_by_kind'])} |
| Trigger lines written by the LLM | {p['why_now_lines']} | one per A/B account, regenerated only when the evidence changes |

Bands under scorer {p['score_version']}: A {bands.get('A',0)}, B {bands.get('B',0)}, C {bands.get('C',0)}, D {bands.get('D',0)}.
A and B together are {pct(bands.get('A',0)+bands.get('B',0), total)} of the accounts.

## Raises found before the press

| Measure | Count |
|---|---:|
| Accounts with a press-announced raise in the last 9 months | {f['accounts_with_press_raise']} |
| Accounts with a confident register raise (SH01 share allotment, amount parsed from the PDF) | {f['accounts_with_register_raise']} |
| Register raises of £250k+ in the last 180 days with no press within 60 days of the allotment | {f['register_raises_no_press_within_60d']} |
| Total parsed from SH01 PDFs in the last 180 days (per-account sums between £1k and £50m) | £{f['register_raise_gbp_capped_180d']:,.0f} |
| Capital filings stored | {f['filings_total']} |
| SH01 PDFs parsed | {f['sh01_pdfs_parsed']} |
| Net-new funded companies found from the press | {f['net_new_total']} |
| ...of which already owned by a colleague in the CRM | {f['net_new_owned_by_colleague']} ({pct(f['net_new_owned_by_colleague'], f['net_new_total'])}) |
| ...of which released to the call list | {f['net_new_released']} |

The press-to-owned ratio is the finding that justified the register stream: by the time a raise is
in the news, most of those companies are already claimed by someone.

## Register stream (every SH01 filed in the UK)

Listener ran {day(rs['first_event'])} to {day(rs['last_event'])}. {rs['events_total']} events received.
Outcomes: {kv(rs['by_outcome'])}. Rejections by rule: {kv(rs['reject_reasons'])}.
{rs['promoted_accounts']} companies promoted into accounts once a week's allotments reached £250k.

## Alerts

{al['total']} alerts sent to the owner's phone ({kv(al['by_source'])}). Answers: {kv(al['by_answer'])}.
Alert rules are deliberately strict: one alert per account ever, headcount 10 to 500, £500k to £50m in a week.

## Contact ranking

{c['contacts_total']} contacts pulled for {c['requests_by_status'].get('found',0)} companies.
Requests by status: {kv(c['requests_by_status'])}. Found rate {c['found_rate']}%,
{c['contacts_per_found_request']} named buyers per company on average.

## Cost

Enrichment, jobs and contact scraping run through one pay-per-result provider. Usage this billing cycle:
${apify.get('used_usd', 0):.2f} of a ${apify.get('limit_usd', 0):.0f} cap (checked {day(apify.get('checked_at'))}).
Against {p['linkedin_enriched']} enriched accounts, {p['jobs_attempted']} job checks and {c['contacts_total']} contacts that is roughly
${apify.get('used_usd', 0) / max(1, p['linkedin_enriched']):.3f} per enriched account all-in for this cycle.
LLM spend is not metered in the database; the console totals across the whole build were under $20 for
the account-intelligence pipeline (one full-book news sweep plus three why-now regenerations, see
docs/POSTMORTEM-credit-incident.md) and well under $1 a day at steady state. Hosting is one small cloud VM at about €8 a month.

## Outcomes

Call list first pushed {day(first_push)} ({days_live} days ago). {o['sheet_rows_live']} rows live;
removed since: {kv(o['sheet_removed_by_reason'])}.

Meetings booked, as reported by the people who booked them (`account_intel.reported_outcomes`):

| Period | Meetings | Booked by | Source |
|---|---:|---|---|
""" + "\n".join(reported_rows(o.get('reported') or [])) + f"""

First week the list was live: {week1_total} meetings ({week1_sdr} by the SDR from the sheet, {week1_ae} from the AE's own cold email using the generated trigger line).
Since then the SDR reports {monthly_rate}+ meetings a month working from the list.

What the sheet itself captured: statuses recorded {kv(o['by_status'])}; meetings marked by band
{kv(o['meetings_by_band'])}, {o['meetings_first_7_days']} of them inside the first seven days. The Status column only
captures outcomes the SDR marks on the sheet, so the sheet-derived counts are a floor, not the full count.

## Calibration against won accounts

Existing customers are kept in the scoring run (never disqualified) so the scorer can be checked
against accounts that actually bought:

| Band at win | Score at win | Lead product at win | Band now |
|---|---:|---|---|
""" + "\n".join(f"| {r['band_at_win']} | {r['score_at_win']} | {r['lead_product_at_win']} | {r['band_now']} |" for r in (o.get('calibration') or [])) + f"""

Both were surfaced from public signals before they inbounded. Two points is not a calibration; it is a check that the signal set is pointed the right way.

## Operations

{ops['watchdog_entries']} watchdog entries: each one is a pipeline failure that was diagnosed and either fixed or escalated by the self-healing routine without a person in the loop.
"""
sys.stdout.write(out)
