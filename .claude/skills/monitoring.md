---
name: monitoring
description: "Monitoring and alerting for a deployed Solana program and its services: which on-chain facts to alert on, which off-chain metrics to emit with thresholds, how to wire subscriptions and webhooks to an alert channel."
---

# Monitoring a deployed program

What to watch after `/deploy`, with thresholds, and how to wire it. Generic observability (Prometheus, Grafana, on-call rotation) works as usual; this file is the Solana half. What to do when an alert is real: [deployment.md](deployment.md#incident-response). Auditor checklist [17-logging-monitoring-incident-response.md](ext/auditor-skill/checklists/17-logging-monitoring-incident-response.md) grades the result.

Start by listing, per cluster, the program IDs (`.program-id-*` or `Anchor.toml`), each ProgramData address (`solana program show <PROGRAM_ID>`), the program's config, vault and pause accounts from the IDL, and every service and wallet that signs.

## On-chain facts that are alerts

Each is an account subscription or a webhook filter, not an HTTP error. Page on the first group; ticket the rest.

| Signal | Watch | Fire when |
|---|---|---|
| Program upgraded or authority changed | the ProgramData account (loader-v3), or the program account itself (loader-v4) | any change not matching a release you are executing |
| Admin instruction invoked | transactions on the program filtered to admin instructions | any call outside a planned change |
| Pause flag flipped | the config account's pause field | any change |
| Vault balance outside its band | lamports or token amount of each program-owned vault | a move beyond N% of balance within M slots |
| Invariant broken | e.g. total shares vs vault assets, mint supply vs recorded deposits (`getTokenSupply`) | any divergence beyond rounding |
| Oracle stale | the price account's publish time or slot | age approaching the staleness bound the program enforces, before the program starts rejecting |
| Authority keys used | mint, freeze, fee and multisig member keys | any transaction signed by them that you did not plan |

## Off-chain metrics to emit

| Metric | Unit | Alert |
|---|---|---|
| Transaction land rate per service | landed / sent | below its 7-day baseline for 10+ minutes |
| Attempts to land (resends until confirmed) | count, p50 / p95 | p95 rising while land rate falls: fees too low or RPC degraded |
| Priority fee paid vs the recent-fee percentile you target | lamports | paying above a set cap for 30+ minutes |
| Confirmed-but-not-finalized backlog | transactions | growing for 30+ minutes |
| Indexer lag | slots (tip slot minus last processed slot) | above ~150 slots (about a minute) for 5+ minutes |
| Fee payer and deployer balance | days of runway (balance / 7-day average daily spend) | under 7 days; page under 2 |
| RPC error rate per provider | errors / requests | above 5% for 5 minutes, then fail over |
| Slot lag between providers | slots behind the highest | above ~50 slots for 1 minute: take that provider out |

Measure lag in slots, not seconds: skipped slots make wall-clock lag jump and recover on its own. Every threshold above takes a duration (`for:` in Prometheus), so one late sample doesn't page anyone.

## Wiring

- Source: Helius webhooks on the program and vault addresses (managed, retried, no socket to keep open), `accountSubscribe` / `programSubscribe` over WebSocket for low volume, or Laserstream / Yellowstone gRPC at high volume ([helius skill](ext/helius/helius-skills/helius/SKILL.md); install first: `bash .claude/bin/skills.sh add helius`). Subscriptions drop silently, so the handler needs the heartbeat and backfill from [backend-async.md](backend-async.md#streams).
- Handler: decode with the IDL, compare against the band or invariant, emit a metric and, for page-level signals, post to the alert channel directly as well, so an alert doesn't depend on the metrics stack.
- Alerts land in a channel nobody mutes (PagerDuty, Opsgenie, or a dedicated Discord or Telegram channel with mentions). Say which one; it is the one manual step.
- Check the monitor itself: a synthetic transaction every few minutes (a memo from a monitoring key) that must appear in the pipeline, and an alert when it doesn't.
- After an upgrade, re-read the IDL the handler decodes with; a layout change silently breaks decoding.
