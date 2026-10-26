# What was scrubbed, and how

The workflows and SQL in this repo are exports of a live system, passed through `tools/scrub.py`. The rule file it reads is not committed because it contains the identifiers it removes. This note lists every category so a reader can judge what is real and what is a placeholder.

## Removed outright

- n8n `pinData` and `staticData` (could carry real rows), `shared` and version blocks (carry the n8n project and owner), timestamps, archive flags.
- Every workflow that was a one-off, a test, a temporary recovery job or unrelated to this system.
- The account list itself, every contact, every outcome row, every sheet's contents. Only aggregates (RESULTS.md, results/latest.json) are published.

## Replaced with placeholders

| Thing | Placeholder |
|---|---|
| Credential ids and names | `CRED_SUPABASE`, `CRED_ANTHROPIC`, `CRED_APIFY`, ... (see .env.example) |
| Webhook ids | `00000000-0000-4000-8000-000000000001` and so on |
| Random webhook path for the register stream | `REPLACE_WITH_RANDOM_PATH` |
| Workflow ids (cross-references between workflows) | `WF_<SLUG>` |
| Supabase project refs | `YOUR_SUPABASE_PROJECT_REF`, `OTHER_SUPABASE_PROJECT_REF` |
| Google Sheet ids | `SHEET_ID_SDR_CALL_LIST`, `SHEET_ID_RAW_ACCOUNT_LIST`, `SHEET_ID_DEMO_JOBS`, `SHEET_ID_SCREENING_LOG`, `SHEET_ID_OUTREACH_QUEUE` |
| Telegram chat id | `TELEGRAM_CHAT_ID` |
| Agent routine id, n8n project id | `ROUTINE_ID`, `N8N_PROJECT_ID` |
| Owner and ops mailboxes | `owner@example.com`, `ops@example.com` |
| Editor and webhook hostnames, server IP | `n8n.example.com`, `hooks.example.com`, `SERVER_IP` |

## Renamed to keep the employer unnamed

- The database schema and the function prefix that carried the employer's name became `account_intel` and `intel_*`; the employer-branded product line became `it_equipment`. Workflow names lost their employer prefix (`AI D1 - ...`).
- The employer's name in prose became "the vendor"; the SDR's name became "the SDR"; the CRM, dialler and contact-enrichment tool are described, not named; the CRM-side assistant is "the CRM-side agent".
- The six customer case-study names and one headline statistic in the why-now prompt's proof-point list became `Customer A` to `Customer F` and `[vendor headline statistic]`, because they identify the vendor. The structure of the prompt is unchanged.
- The competitor list in the careers-page scan kept every competitor and replaced the vendor's own entry with `own_brand`.

## Kept as-is

- The fictional demo agency, its fictional client and fictional candidates in the recruitment workflows (all `example.com` addresses).
- The owner's own name where it appears as author or demo consultant.
- Every rule, weight, threshold, prompt and regex. Nothing about how the system decides was changed.

## Verification

- Every page of the SQL dump was checked against an md5 computed in the database before scrubbing.
- A residual grep for the employer, the SDR, the tools, every real account name that appeared in the project notes, every sheet id, the chat id, the project ref and the server IP returns nothing.
- `gitleaks detect` runs clean on the tree (config in `.gitleaks.toml`).
