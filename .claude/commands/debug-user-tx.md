---
description: "Replay a user's failing transaction on forked state and map the error to source"
---

Debug the failing transaction described in $ARGUMENTS. The answer the developer needs is where in this repo it failed: the handler, constraint or `require!` with `file:line`, why it failed, and a fix. References: [testing.md](../skills/ext/solana-dev/skills/solana-dev/references/testing.md) (LiteSVM, Surfpool), [surfpool/cheatcodes.md](../skills/ext/solana-dev/skills/solana-dev/references/surfpool/cheatcodes.md), [transactions-v1.md](../skills/ext/solana-dev/skills/solana-dev/references/transactions-v1.md).

## Inputs

| Input | Notes |
|---|---|
| `signature` | Preferred: fetch and diagnose in seconds. If the user only pasted an error message, ask for it first. |
| `instruction` + `wallet` | When the tx never landed: the serialized tx, or accounts plus data. |
| `cluster`, `rpc` | Default from `Anchor.toml` `[provider]` or `.env`. Public RPCs rate-limit, so prefer the project's provider (e.g. Helius). |
| `program` | Default: IDs from `declare_id!` / `Anchor.toml`. |

## Modes

- **A, signature given:** steps 1-4 and 6. Replay (5) only when the on-chain evidence is inconclusive.
- **B, never landed:** build the tx from the instruction, replay it (5), then map the error from the replay logs (3-4) and check state (6).
- **C, failing program is not in this repo** (Jupiter, Token program...): skip source mapping, diagnose from logs and account state, and say the root cause is outside this codebase.

## Steps

1. **Fetch** with `getTransaction` and `{"encoding":"json","maxSupportedTransactionVersion":1,"commitment":"confirmed"}`. The version must be the integer `1`: with `0` or omitted, v1 transactions fail with `-32015`. Cache the response as `.claude/debug/tx-<first 8 chars of sig>.json` and re-read it from there. Use `meta.err`, `meta.logMessages`, pre/post balances and token balances, `meta.innerInstructions`, `slot`, `message.accountKeys`, `message.instructions`, and `message.transactionConfig` (v1 transactions carry the CU limit and priority fee there instead of ComputeBudget instructions).
2. **Failing instruction:** the index is `meta.err.InstructionError[0]`; don't go by position (legacy and v0 txs usually start with ComputeBudget instructions). For v0 txs with lookup tables, index into `accountKeys ++ meta.loadedAddresses.writable ++ meta.loadedAddresses.readonly`, or CPI-heavy txs resolve the wrong program. A program ID that is not ours means mode C.
3. **Handler:** instruction `data` is base58 in `json` encoding; decode it first. Anchor: match the first 8 bytes against `instructions[].discriminator` in `target/idl/<program>.json` (this also covers custom discriminators). Pinocchio/native: usually the first byte, matched against the `process_instruction` dispatch.
4. **Error to source**, logs first:
   - `AnchorError thrown in <file>:<line>` is the exact location; quote it.
   - `AnchorError caused by account: <name>` points at a constraint on that `#[derive(Accounts)]` field; the `Left:` / `Right:` lines show the compared values.
   - The program's own `Program log:` lines and `Program <id> failed: <reason>`.

   Then map `Custom(N)` for Anchor programs:

   | Code | Meaning |
   |---|---|
   | 100-103 | Instruction missing, fallback not found, (de)serialization failed: client and program out of sync |
   | 2000s | Constraints: 2000 mut, 2001 has_one, 2002 signer, 2003 `constraint =`, 2004 owner, 2005 rent-exempt, 2006 seeds, 2011 close, 2012 address, 2014 token mint, 2015 token owner, 2016-2018 mint authority / freeze authority / decimals, 2019 space, 2021-2023 token program |
   | 2500-2506 | `require!` family (`require_eq!`, `require_keys_eq!`, `require_gt!`, ...) |
   | 3000s | Accounts: 3002 discriminator mismatch, 3003 did not deserialize, 3005 not enough keys, 3006 not mutable, 3007 owned by wrong program, 3010 not signer, 3012 not initialized |
   | 4100, 4102 | `DeclaredProgramIdMismatch`, `InvalidNumericConversion` |
   | 6000+ | The program's `#[error_code]` variants, at `offset` (default 6000) + discriminant: the variant's explicit `= N` if it sets one, else the previous variant's + 1. A second enum compiles fine and also defaults to 6000, so check every enum in the program — two whose ranges overlap decode to the same code. Report the variant, its `#[msg]` text and `file:line`. |

   Pinocchio/native: map `Custom(N)` to the program's error enum or constants; standard `ProgramError` variants map by name.
5. **Replay** (optional in A, required in B). Run `surfpool start --rpc-url <rpc> --no-tui --no-deploy --skip-signature-verification --log-bytes-limit 0` in the background (`--network devnet` for devnet). `--no-deploy` keeps the on-chain program the user hit; drop it later to test the local fix. Execute with `simulateTransaction` (`sigVerify: false`, `replaceRecentBlockhash: true`, `encoding: "base64"`) or `surfnet_profileTransaction` (logs, CU, pre/post account snapshots); the kit's Surfpool MCP server exposes the same cheatcodes.
   - The fork fetches current state, not state at the failing slot. If the replay passes, the state changed since: rebuild the pre-state with `surfnet_setAccount` / `surfnet_setTokenAccount`, and `surfnet_timeTravel` for clock-dependent checks.
   - LiteSVM, when Surfpool is unavailable or to lock the fix in as a test: load the accounts plus `target/deploy/<name>.so`. Take the accounts from `surfnet_exportSnapshot` with `{"scope":{"preTransaction":"<sig>"}}` after sending the tx to the fork with `sendTransaction` (swap in a fresh blockhash; signatures are not checked), which gives the exact pre-state, or from `getAccountInfo` (current state, same caveat).
6. **Account state:** for each writable account of the failing instruction check owner, rent-exempt lamports, initialization (non-zero data, expected discriminator) and stale fields such as timestamps or oracle prices.

## Common pitfalls

<!-- Adapted from sendaifun/solana-new (debug-program), MIT -->
Most user reports map to one of these; check the diagnosis against them before replaying.

1. `ConstraintSeeds` (2006): the client derives the PDA with different seeds, order or byte encoding than the program.
2. `ConstraintSigner` (2002) / `MissingRequiredSignature`: a required signer is missing from the tx.
3. `BlockhashNotFound` / block height exceeded: blockhash fetched too early; fetch it right before sending and retry until `lastValidBlockHeight`.
4. `AccountNotInitialized` (3012): the init instruction never ran or was not confirmed yet (the fix is not `init_if_needed`).
5. `DeclaredProgramIdMismatch` (4100): `declare_id!` differs from the deployed ID; `anchor keys sync`, rebuild, redeploy.
6. Token transfer fails on the recipient side: its ATA does not exist; create it idempotently first.
7. `ComputationalBudgetExceeded`: over the CU limit (legacy/v0 default: 200k per instruction); set the limit from a simulation plus margin.
8. `MaxLoadedAccountsDataSizeExceeded` on a v1 tx: unset v1 limits are zero; set `computeUnitLimit` and `loadedAccountsDataSizeLimit` in the transaction config.
9. `InsufficientFundsForRent`: an account funded below the rent-exempt minimum for its size.
10. Amounts off by 10^n: hardcoded decimals instead of the mint's `decimals`.
11. `AccountDidNotDeserialize` (3003) / `AccountDataTooSmall`: `space` is not `DISCRIMINATOR.len() + INIT_SPACE`, or the struct grew without a realloc.
12. System error 0, "already in use": creating an account that exists; check before sending the init.
13. `ConstraintMut` (2000) / `AccountNotMutable` (3006): the account is not `mut` in the program or not writable in the client.
14. `AccountOwnedByWrongProgram` (3007) or `IncorrectProgramId` on token ops: SPL Token vs Token-2022 mismatch; pass the mint owner's token program everywhere.
15. Transaction too large: 1232 bytes for legacy/v0 (use lookup tables or split); v1 allows 4096 bytes where the wallet supports it.
16. Wrong mint in SOL-funded DeFi flows: the program expects wrapped SOL; wrap (`NATIVE_MINT` ATA, transfer, `syncNative`) and close the ATA to unwrap.
17. Tx expires unprocessed on mainnet: missing or low priority fee (`setComputeUnitPrice` from `getRecentPrioritizationFees` for v0; `priorityFee` total for v1).
18. A just-created account reads as missing: commitment mismatch; confirm and read at the same commitment.
19. `InstructionFallbackNotFound` (101) or garbled decoding: the client IDL is older than the deployed program; rebuild and regenerate the client.
20. Lamports or data left after close: a manual close without zeroing; use `close = destination`.
21. `CallDepthExceeded`: CPI nesting deeper than the runtime allows; flatten the call chain.

## Report

Print it in chat; write a file only if the user asks.

```
## Debug report: <short sig | reconstructed>
Cluster, slot, fee payer, wallet
### Failure
Instruction #i -> program <id> (<this repo | external>), handler `<name>` at <file>:<line>
Error: <Name> (<N>) "<msg>", defined at <file>:<line>
### Root cause (likely)
<paragraph tying the error to the handler's logic and the observed state>; guard at <file>:<line>
### Writable accounts
| account | role | observed | expected | status |
### Program logs (last 10-15 lines)
### Reproduction
<surfpool command and replay call, or the LiteSVM test>
### Next steps
1. Fix, with file:line  2. Client-side mitigation  3. Regression test to add
```

## Guardrails

- Never ask for a private key; simulation and replay need no signatures.
- Never broadcast to a real cluster. This command is read and replay only.
- If the failing program is not in the workspace, say so instead of inventing a source mapping.
