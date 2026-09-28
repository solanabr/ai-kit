# Integrating arbitrary Token-2022 mints

For vaults, pools, lending markets and payment flows that accept mints they didn't create, and for issuers checking where a mint can trade. The model already knows the general dangers (fee-on-transfer, freeze, permanent delegate); this file adds current venue behavior and the checks that are easy to miss. Security checklist: [security.md, Token-2022 section](../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).

## Accepting a mint on-chain

- Allow-list extension types with targeted lookups (`get_extension::<PermanentDelegate>()`, `TransferHook`, `PausableConfig`, `TransferFeeConfig`, ...) and reject what you don't handle. `StateWithExtensions::unpack` also accepts 82-byte classic SPL mints, so one path covers both programs.
- A dormant extension can wake up: a TransferFeeConfig at 0 bps or a TransferHook with no program but a live authority can be switched on later. Reject on a live authority, or re-check on every deposit.
- Credit the balance delta after `transfer_checked` (`.reload()`), not the argument. Exact-out math needs `calculate_inverse_epoch_fee`.
- Hooked mints need the extra accounts forwarded; `token_interface::transfer_checked` drops them ([transfer-hooks.md](transfer-hooks.md)).
- A paused mint must not block unrelated instructions; check `PausableConfig.paused` per mint ([issuer-controls.md](issuer-controls.md)).
- Payouts to users: a destination with required memo needs a memo CPI right before the transfer; users with CPI Guard can't have tokens pulled by owner signature inside your CPI (use a top-level approve plus a delegate transfer).

## Venue support (read from each program's source, 2026-09-28)

"Badge" means the venue's admin must approve the specific mint; "rejected" means no path.

| Extension                    | Orca Whirlpools      | Raydium CPMM / CLMM   | Meteora DAMM v2                        | Kamino (klend)            | marginfi v2          |
| ---------------------------- | -------------------- | --------------------- | -------------------------------------- | ------------------------- | -------------------- |
| Transfer fee                 | allowed              | allowed               | allowed                                | only at 0 bps             | allowed (fee netted) |
| Transfer hook                | badge, works         | badge, but swaps fail | free only with no program and no authority; else badge, but swaps fail | only with no hook program | works                |
| Permanent delegate           | badge                | badge                 | badge                                  | allowed                   | no filter            |
| Non-transferable             | rejected             | badge                 | badge                                  | rejected                  | no filter            |
| Default frozen               | badge                | badge                 | badge                                  | allowed                   | no filter            |
| Pausable                     | badge                | badge                 | badge                                  | only while not paused     | no filter            |
| Mint close authority         | badge                | badge                 | badge                                  | allowed                   | no filter            |
| Confidential transfer        | public balances only | badge                 | badge                                  | allowed, auto-approve off | no filter            |
| Interest-bearing / scaled UI | allowed              | allowed               | badge                                  | scaled UI only            | no filter            |
| Metadata                     | allowed              | allowed               | allowed                                | allowed                   | no filter            |

Sources: `orca-so/whirlpools` `programs/whirlpool/src/util/v2/token.rs`; `raydium-io/raydium-cp-swap` and `raydium-io/raydium-clmm` `is_supported_mint()`; `MeteoraAg/cp-amm` `programs/cp-amm/src/utils/token.rs`; `Kamino-Finance/klend` `programs/klend/src/utils/constraints.rs`; `mrgnlabs/marginfi-v2`. Orca also needs a badge for any mint with a freeze authority, and rejects extensions it doesn't list (PermissionedBurn, ConfidentialMintBurn, group and member). Raydium and DAMM v2 badges skip every per-extension check.

- **A badge is not working hook support.** Raydium CPMM, CLMM and Meteora DAMM v2 can approve a hooked mint, but their swap CPIs never forward the hook's extra accounts, so every swap fails. Orca (SwapV2 forwards `TransferHookA/B` accounts) and marginfi (`invoke_transfer_checked`) work; Meteora DLMM does per its SDK and IDL (program source is closed).
- marginfi has no program-level extension filter: bank creation is admin-only, so the admin is the check.
- Kamino accepts permanent-delegate mints without extra checks, unlike the AMMs.
- Jupiter routes through these venues. Its Token-2022 fee-taking needs `instructionVersion=V2` (since October 2025); the legacy path fails with `IncorrectTokenProgramID` (6014).
- Wallets (checked from public snippets only): Phantom shows the transfer-fee percentage on send and warns on permanent delegate. Solflare and Backpack advertise extension support without per-extension detail. Test a real mint in each wallet you depend on.

## Risk signals and real incidents

- RugCheck scores freeze and mint authority and flags transfer-hook mints as dangerous; Phantom warns on permanent delegate. Expect traders to see these within minutes of launch.
- Documented incidents: the 2025 ZK ElGamal proof bugs (no loss, confidential transfers off for about a year); permanent delegate used to burn buyers' tokens seconds after purchase (2024); the BONKKILLER freeze-authority honeypot (April 2024, about $1.62M pulled). Hook sell-blockers, mint close-and-reinit and pause abuse are real risks but have no public, dated incident yet; describe them as risks, not history.
- Before trusting a hooked mint, check the hook program's upgrade authority (`solana program show <hook>`) and who can update its ExtraAccountMetaList.
