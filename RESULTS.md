# Results

Generated 2026-11-09 16:13 UTC from `select public.intel_results();`
(definition in `supabase/migrations/0003_results.sql`). Aggregates only. Re-render with
`python3 tools/render_results.py results/latest.json > RESULTS.md`; the weekly GitHub Action does the same.

## Accounts processed per stage

| Stage | Count | Rate |
|---|---:|---:|
| Accounts in the system | 3349 | book 3186, net-new from press 126, net-new from the register 37 |
| Matched to the companies register | 2867 | 85.6% of all accounts |
| Register match at confidence 0.85 or above | 2500 | 87.2% of matches |
| Disqualified (dead on the register) | 202 | exact-name matches to dissolved or liquidated companies only |
| Disqualified (over 500 staff) | 16 | |
| Disqualified (never-buy industry) | 86 | editable table |
| Disqualified (manual: owned by a colleague, duplicates, test rows) | 44 | |
| LinkedIn enrichment attempted | 3167 | |
| LinkedIn enrichment succeeded | 2722 | 85.9% of attempts |
| Careers pages scanned | 2953 | |
| ATS detected on the careers page | 67 | 2.3% of scanned; ashby 10, hibob 1, lever 1, breezy 2, jazzhr 2, vincere 2, workday 3, bamboohr 12, jobadder 1, pinpoint 4, workable 8, recruitee 4, greenhouse 1, teamtailor 15, smartrecruiters 1 |
| LinkedIn jobs checked | 2905 | |
| Accounts with a live role | 326 | 11.2% of checked (2772 job rows) |
| Accounts with a live role outside the home market | 108 | 3.7% of checked |
| News checked | 3069 | signals by kind: funding 832, ignored 137, layoffs 17, expansion 106, new_office 83, acquisition 180, people_hire 31, project_win 108 |
| Trigger lines written by the LLM | 425 | one per A/B account, regenerated only when the evidence changes |

Bands under scorer v1.6: A 84, B 298, C 1493, D 1474.
A and B together are 11.4% of the accounts.

## Raises found before the press

| Measure | Count |
|---|---:|
| Accounts with a press-announced raise in the last 9 months | 150 |
| Accounts with a confident register raise (SH01 share allotment, amount parsed from the PDF) | 88 |
| Register raises of £250k+ in the last 180 days with no press within 60 days of the allotment | 44 |
| Total parsed from SH01 PDFs in the last 180 days (per-account sums between £1k and £50m) | £590,405,876 |
| Capital filings stored | 486 |
| SH01 PDFs parsed | 334 |
| Net-new funded companies found from the press | 126 |
| ...of which already owned by a colleague in the CRM | 47 (37.3%) |
| ...of which released to the call list | 46 |

The press-to-owned ratio is the finding that justified the register stream: by the time a raise is
in the news, most of those companies are already claimed by someone.

## Register stream (every SH01 filed in the UK)

Listener ran 2026-10-13 to 2026-10-17. 1421 events received.
Outcomes: staged 15, existing 24, promoted 28, rejected 1095, too_small 259. Rejections by rule: SIC 686, not 1, name 32, type 78, status 1, incorporated 297.
37 companies promoted into accounts once a week's allotments reached £250k.

## Alerts

56 alerts sent to the owner's phone (news 49, register_book 6, register_stream 1). Answers: mine 5, other 1, owned 10, unanswered 40.
Alert rules are deliberately strict: one alert per account ever, headcount 10 to 500, £500k to £50m in a week.

## Contact ranking

1086 contacts pulled for 305 companies.
Requests by status: error 1, found 305, no_match 1, none_found 22, no_linkedin 2. Found rate 92.4%,
3.56 named buyers per company on average.

## Cost

Enrichment, jobs and contact scraping run through one pay-per-result provider. Usage this billing cycle:
$100.01 of a $100 cap (checked 2026-11-09).
Against 2722 enriched accounts, 2905 job checks and 1086 contacts that is roughly
$0.037 per enriched account all-in for this cycle.
LLM spend is not metered in the database; the console totals across the whole build were under $20 for
the account-intelligence pipeline (one full-book news sweep plus three why-now regenerations, see
docs/POSTMORTEM-credit-incident.md) and well under $1 a day at steady state. Hosting is one small cloud VM at about €8 a month.

## Outcomes

Call list first pushed 2026-10-12 (28 days ago). 341 rows live;
removed since: owned 29, manual 1, customer 2.

Meetings booked, as reported by the people who booked them (`account_intel.reported_outcomes`):

| Period | Meetings | Booked by | Source |
|---|---:|---|---|
| 2026-10-12 to 2026-10-18 | 4 | SDR | SDR, reported in the weekly sync |
| 2026-10-12 to 2026-10-18 | 1 | AE | AE, own CRM |
| from 2026-10-12, per month | 12+ | SDR | SDR, reported in the weekly sync |

First week the list was live: 5 meetings (4 by the SDR from the sheet, 1 from the AE's own cold email using the generated trigger line).
Since then the SDR reports 12+ meetings a month working from the list.

What the sheet itself captured: statuses recorded worked 31, not_a_fit 3, meeting_booked 4; meetings marked by band
A 2, B 2, 2 of them inside the first seven days. The Status column only
captures outcomes the SDR marks on the sheet, so the sheet-derived counts are a floor, not the full count.

## Calibration against won accounts

Existing customers are kept in the scoring run (never disqualified) so the scorer can be checked
against accounts that actually bought:

| Band at win | Score at win | Lead product at win | Band now |
|---|---:|---|---|
| A | 95.0 | eor | A |
| B | 55.0 | eor | B |

Both were surfaced from public signals before they inbounded. Two points is not a calibration; it is a check that the signal set is pointed the right way.

## Operations

196 watchdog entries: each one is a pipeline failure that was diagnosed and either fixed or escalated by the self-healing routine without a person in the loop.
