---
name: keeper-ops
description: "Running a Solana keeper or crank in production: idempotent crank instructions, losing the race as a normal outcome, one sender per job, slot-based schedules and missed ticks, profitability gate, Jito bundles, unattended signer limits."
---

# Keepers and cranks

A keeper sends the same instruction indefinitely, usually against other keepers: liquidations, order matching, oracle refreshes, auction settlement, reward distribution, vault rebalancing. RPC, confirmation and resend rules are in [backend-async.md](backend-async.md); this file covers what is specific to running one. Auditor checklist [20-rust-offchain-services.md](ext/auditor-skill/checklists/20-rust-offchain-services.md) grades the finished bot.

## Design the instruction for a crowd

The program side, agreed with whoever writes the program:

- "Already done" is its own outcome. Settled, not liquidatable, position closed and tick already processed each get a distinct error code (or succeed as a no-op), so the bot can tell a lost race from a bug.
- Permissionless cranks pay the caller (liquidation bonus, crank fee) from a bounded source, so a crank can't be farmed. A permissioned crank uses a role that can do nothing else, not the admin or upgrade authority.
- Pass the expected outcome as bounds (`min_out`, max price, expected sequence number), so a stale view fails instead of executing at a bad price.
- Work in bounded batches with a cursor stored on-chain, within the compute and 64-account limits, so any keeper can resume where another stopped.

## Classify every outcome

| Outcome | Meaning | Action |
|---|---|---|
| Landed, succeeded | done | record the reward |
| Landed, failed with an "already done" code | lost the race | count it, no alert |
| Landed, failed with any other error | bug or bad input | alert |
| Simulation shows nothing to do | someone got there first | skip the send |
| Block height passed `last_valid_block_height` | expired | re-evaluate from fresh state before re-signing |

Match the code from `InstructionError(index, Custom(code))` against the program's IDL errors. A transaction that lands and fails still pays its base and priority fee, so the lost-race rate is a cost line: simulate against the latest state right before signing.

## One sender per job

Two replicas sending the same crank pay double fees, and double effects if the instruction is not idempotent. Pick one explicitly:

- A lease: a row `(job, holder, epoch, expires_at)` taken with a conditional update, or `pg_try_advisory_lock` on a dedicated connection. Check it before each send, not once at startup: a process paused by GC or a VM migration can wake up holding an expired lease.
- Sharding: each replica owns a hash range of positions or markets.
- Accepting the duplicate, when the instruction is idempotent and a second fee costs less than coordination.

## Schedule on chain time

- Trigger on the value the program checks (Clock `slot` or `unix_timestamp`, an expiry field, `getEpochInfo` for epoch boundaries), not the host clock. `unix_timestamp` is a stake-weighted estimate and can sit seconds away from wall time, so a crank fired by the host clock can arrive early and fail.
- Decide per job what a restart does with ticks missed while down: catch up every one in order (payouts, funding intervals where each period counts), or skip to the current one (oracle refresh, rebalancing). Store the last processed tick with its slot.
- Liquidations are event-driven: subscribe to the oracle and position accounts (`accountSubscribe`, Laserstream) and re-check health on each update, with a periodic full scan as backstop for dropped streams.

## Profitability gate

Send only when the expected reward exceeds base fee (5,000 lamports per signature) + priority fee + tip + rent for accounts the transaction creates + swap slippage, plus a margin. Decide again after simulation, from the simulated amounts, not from the quote. Cap priority fee plus tip per job at a fraction of the reward: a fee war above that cap is a race to let go. In v0 the priority fee is CU limit × price; in v1 it is a lamport total ([backend-async.md](backend-async.md#sending-transactions)).

## Landing together: one transaction or a bundle

When the crank must land with something else (liquidate, then swap the seized collateral):

- One transaction if it fits: a v1 transaction holds 4,096 bytes and 64 accounts.
- Otherwise a Jito bundle: up to 5 transactions, executed in order and all-or-nothing by Jito-Solana leaders. Tip with a SOL transfer to one of the 8 accounts from `getTipAccounts` (pick one at random; minimum 1,000 lamports) inside the main transaction, so a failure doesn't pay it, and never through a lookup table. A failed bundle does not land, so it pays no fee.
- Bundles can be split: when a block is skipped, its transactions can be rebroadcast on their own outside the bundle rules. Give each transaction its own guards (`min_out`, balance or slot assertions) so it is safe alone.
- Leaders not running Jito-Solana ignore bundles and tips. Checked 2026-10-09 against [docs.jito.wtf](https://docs.jito.wtf/lowlatencytxnsend/).

## Unattended signer

- One keypair per keeper, holding only the crank role on-chain; never an upgrade, admin or mint authority.
- Keep a few days of fees in it. Top it up from a separate wallet on a schedule with a per-top-up cap, and alert on runway (balance divided by daily spend), not on a fixed SOL amount.
- Enforce spend limits in code before signing: a per-transaction fee-plus-tip cap, an hourly total, and an allowlist of program IDs the key may invoke. On a breach, stop and page; don't continue.
- Load the key from a secrets manager or a KMS-backed signer at start, never log it, and keep a kill-switch flag the loop reads every iteration.
