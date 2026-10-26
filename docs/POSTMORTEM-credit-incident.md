# Postmortem: LLM credit exhaustion silently degraded output (13 Oct 2026)

Status: resolved. Severity: medium (no data loss, no bad data written; several hours of missing and stale trigger lines, nobody paged).

## What happened

The account-intelligence pipeline uses Claude Sonnet in three places: classifying news items (D5), extracting raises from the funding scanner (D12), and writing the trigger line and discovery question for every A/B account (D7). All three ran on an Anthropic Console organisation that had been loaded with $20 of prepaid credit on 5 Oct.

Between 12 and 13 Oct the pipeline did a full-book news sweep (about 2,900 accounts) and three complete why-now regenerations (each one a few hundred Sonnet calls, triggered by scorer changes that invalidated every line). That used the $20. From that point every model call returned "credit balance is too low".

Nothing failed. The model nodes in n8n were configured with `onError: continueErrorOutput`, so each failed call was routed to the node's error output instead of raising. The downstream nodes had nothing on the error branch, so the executions completed green with no output, the hourly health check saw no failed executions, the watchdog routine was never fired, and the SDR's sheet kept showing yesterday's lines.

It was noticed by a person reading the executions list and wondering why the why-now queue was not draining.

## Timeline

- 5 Oct: client-facing Console organisation created, $20 loaded, API key put into n8n as the only Anthropic credential.
- 12 Oct, afternoon: full-book news sweep.
- 12 Oct, evening: scorer v1.2 to v1.4, each change regenerating all A/B lines.
- 13 Oct, morning: scorer v1.5 and the country rule, one more regeneration. Credit runs out some time in the morning.
- 13 Oct, ~midday: why-now queue not draining; executions green; model nodes' error outputs carrying "credit balance is too low".
- 13 Oct, afternoon: D7 changed to hard-stop on model failure; six LLM workflows moved to a second credential; incident written up.

## Why monitoring missed it

Three independent decisions combined:

1. The model nodes used an error output so that one bad account could not kill a batch of 150. Correct for per-item failures, wrong for an account-wide failure that affects every item the same way.
2. The health check (`intel_health`) measures queue movement and landed rows, not model outcomes. An empty result from a model node is indistinguishable from "no accounts needed a line".
3. The error-alert workflow fires on failed executions. A workflow that catches its own errors never fails.

Each decision was reasonable on its own. Together they produced a pipeline that could run out of its most important input and report itself healthy.

## Fixes

- D7 now raises a hard error when its model calls fail, which routes through the error-alert workflow to the self-healing routine and, if the routine cannot fix it, to a person. The rule is written into the hosting runbook: a model node with an error output needs an explicit Stop and Error on that output in any workflow that matters.
- Credit follows purpose, not workflow. Two Anthropic credentials exist in n8n: a general one for pre-revenue work (own pipeline, demos, the account-intelligence build) and a client-facing one that only paying-client workflows use, because that is the organisation a data processing agreement names and the invoice comes from. Switching a workflow between them is one credential reference per model node.
- Full sweeps are announced before they run. A full-book Sonnet sweep is roughly $10 to $15; steady state is 50 to 150 calls a day, well under $1.
- Why-now regeneration became evidence-driven the same week (`why_now.scorer_evidence` and `band_at_generation`): a line is rewritten only when the scorer's evidence, the score version or the band changes, which removed roughly 120 unnecessary calls a day and made the sweep that caused this incident impossible to trigger by accident.

## Lessons

- "Continue on error" at the item level needs a circuit breaker at the batch level. If every item in a batch fails the same way, that is an outage, not noise.
- Health checks must measure the thing the pipeline is for. Queue depth and row counts are proxies; "how many lines did the model actually write in the last hour" is the signal.
- Spend is an input like any other and gets a usage read in the hourly health check. The same pattern was applied to the scraping provider nine days later when its monthly cap was hit silently (D2 and D4b had been failing soft for a day); the health check now reads provider usage hourly and raises an issue at 80% of the cap.
- The total spend across the whole build was under $20. The cost of the incident was not money, it was a day of stale lines on the SDR's sheet and the realisation that green executions are not the same as a working pipeline.
