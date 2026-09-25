---
name: backend-async
description: "Solana-specific rules for Rust backends and indexers: async RPC client, commitment, RPC limits, stream reconnect and backfill, idempotent indexing, send/confirm with priority fees."
---

# Rust backends and indexers

Only the Solana-specific parts; Axum, Tokio and SQLx are used as usual. Helius APIs (Laserstream, Sender, webhooks): [helius skill](ext/helius/helius-skills/helius/SKILL.md) (install first: `bash .claude/bin/skills.sh add helius`).

## RPC client

- Use the nonblocking `RpcClient` (`solana_rpc_client::nonblocking::rpc_client`) in an `Arc`, with a timeout (`new_with_timeout_and_commitment`). The blocking client runs its own runtime via `block_in_place`, which panics on a current-thread runtime (the `#[tokio::test]` default) and parks a worker otherwise; `anchor-client` needs `features = ["async"]`.
- Keep `spawn_blocking` for CPU work (bulk signing, proofs), not RPC.
- Batch reads: `get_multiple_accounts` (100 keys), `data_slice`, memcmp filters. Unfiltered `getProgramAccounts` is slow or disabled on most providers; index instead. `getSignaturesForAddress` pages at 1,000 via `before`/`until`.
- Retry 429, 5xx and timeouts with jittered backoff and `Retry-After`, not simulation or parameter errors. Public endpoints are for development.
- Transaction v1 is live on mainnet: pass `max_supported_transaction_version: Some(1)` to `get_transaction`/`get_block`, or a single v1 transaction fails the whole block. Geyser detection and 4.x crates: [transactions-v1.md](ext/solana-dev/skills/solana-dev/references/transactions-v1.md).

## Commitment

- `confirmed` for API reads and blockhashes; `processed` only if you handle forks yourself.
- `finalized` before irreversible off-chain effects (crediting deposits, payouts), or treat `confirmed` as provisional and reconcile at finalized.
- Fetch the blockhash and run preflight at the same commitment; a blockhash newer than the preflight bank fails with `BlockhashNotFound`.
- Read your own writes with `min_context_slot` set to the write's slot; load-balanced RPCs otherwise answer from a lagging node.

## Streams

- Subscriptions drop silently and never replay. Run a watchdog (a slot subscription as heartbeat) and resubscribe with backoff.
- On reconnect, backfill the gap: page `getSignaturesForAddress(program, until = last_processed_signature)` backward, then process oldest first through the same idempotent path. Laserstream/Yellowstone take `from_slot = last_processed_slot` ([Laserstream](ext/helius/helius-skills/helius/references/laserstream.md) replays about 24 h; install first: `bash .claude/bin/skills.sh add helius`).
- Yellowstone gRPC: answer server pings with a ping `SubscribeRequest` or load balancers drop the stream; pin `yellowstone-grpc-proto >= 12.6.0` so v1 message config decodes.
- Decode events from `emit_cpi!` inner-instruction data or from instructions, not logs: logs truncate, and `logsSubscribe` carries no account data.

## Indexer rules

- Idempotent writes keyed by `signature` for transactions and `(signature, instruction path)` for events (one transaction can emit several); `ON CONFLICT DO NOTHING`.
- Stamp rows with `slot` (plus Geyser `write_version` for accounts) and upsert account state only when `(slot, write_version)` is newer: backfill and live data interleave.
- Ingest at `confirmed`, mark rows provisional, promote once the slot finalizes, delete rows from slots that never do. At `processed`, also handle Geyser dead-slot status.
- Commit the checkpoint (last slot or signature) in the same DB transaction as its rows.
- Failed transactions (`meta.err`) pay fees and appear in signature lists; skip their state changes.
- Decode with the IDL version live at that slot; upgrades change layouts.
- Alert on ingestion lag (tip slot minus last processed slot).

## Sending transactions

- `get_latest_blockhash_with_commitment(confirmed)` also returns `last_valid_block_height`; expiry is by block height, not time.
- Simulate once to size the compute limit (consumed plus 10-20%); the v0 fee is limit x price, so overshooting wastes lamports. Price from `getRecentPrioritizationFees` over the writable accounts you lock (capped percentile) or [a provider estimate](ext/helius/helius-skills/helius/references/priority-fees.md) (install first: `bash .claude/bin/skills.sh add helius`). In v1 transactions the priority fee is a lamport total, and unset compute and data limits are zero, not defaults.
- Send with `skip_preflight: true` (already simulated) and `max_retries: Some(0)`; rebroadcast the same signed bytes every ~2 s while polling `get_signature_statuses`, until confirmed or the block height passes `last_valid_block_height`.
- Re-sign with a fresh blockhash only after the old one expired, or both can land. Durable nonces for slow or multi-party signing.
- Landing services (Helius Sender, Jito) add tip and preflight rules: [sender.md](ext/helius/helius-skills/helius/references/sender.md) (install first: `bash .claude/bin/skills.sh add helius`).
