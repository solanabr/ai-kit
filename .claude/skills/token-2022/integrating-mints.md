# Integrating arbitrary Token-2022 mints

For vaults, pools, lending markets, frontends and payment flows that accept mints they didn't create, and for issuers checking where a mint can trade. The model already knows the general dangers (fee-on-transfer, freeze, permanent delegate); this file adds current venue behavior and the checks that are easy to miss. Security checklist: [security.md, Token-2022 section](../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).

## Accepting a mint on-chain

- Allow-list extension types with targeted lookups (`get_extension::<PermanentDelegate>()`, `TransferHook`, `PausableConfig`, `TransferFeeConfig`, ...) and reject what you don't handle. `StateWithExtensions::unpack` also accepts 82-byte classic SPL mints, so one path covers both programs.
- A dormant extension can wake up: a TransferFeeConfig at 0 bps or a TransferHook with no program but a live authority can be switched on later. Reject on a live authority, or re-check on every deposit and decide what withdrawals do when a later check fails, since users already inside can't leave through a mint that has since been paused or hooked.
- An authority set to `None` can't be set again, so a renounced delegate, hook, pause or fee authority stays as it is, unless a live mint close authority lets the mint be closed at zero supply and recreated. A renounced fee authority locks the fee but doesn't make it safe: fees go up to 10,000 bps with `maximum_fee` up to `u64::MAX`, and a `newer_transfer_fee` scheduled before the renounce still activates at its epoch. Check both `older_transfer_fee` and `newer_transfer_fee`.
- Who can still change a mint: the freeze authority (also controls DefaultAccountState via `UpdateDefaultAccountState`), and the authorities of MetadataPointer, GroupPointer, ScaledUiAmount (multiplier, immediate if the timestamp is past), InterestBearing (rate, immediate), TransferHook (program), TransferFeeConfig (fee, after two epochs), Pausable, PermissionedBurn, confidential transfer mint (auditor key, auto-approve), and the update authorities of TokenMetadata and TokenGroup.
- Hooked mints need the extra accounts forwarded; `token_interface::transfer_checked` drops them ([transfer-hooks.md](transfer-hooks.md)).
- A paused mint must not block unrelated instructions; check `PausableConfig.paused` per mint ([issuer-controls.md](issuer-controls.md)).
- Payouts to users: a destination with required memo needs a memo CPI right before the transfer; users with CPI Guard can't have tokens pulled by owner signature inside your CPI (use a top-level approve plus a delegate transfer).

## Clients: wallets, frontends, payments

Payment and checkout flows (PYUSD and other Token-2022 stablecoins) read the mint's owner program first and use the Token-2022 program ID for ATAs and transfers. Verified with Kit 0.19:

```ts
import { unwrapOption, parseBase64RpcAccount } from '@solana/kit';
import { fetchMint, decodeToken, TOKEN_PROGRAM_ADDRESS, TOKEN_2022_PROGRAM_ADDRESS } from '@solana-program/token-2022';

// A wallet's tokens across both programs (Kit has no helper)
const rs = await Promise.all([TOKEN_PROGRAM_ADDRESS, TOKEN_2022_PROGRAM_ADDRESS].map((programId) =>
  rpc.getTokenAccountsByOwner(owner, { programId }, { encoding: 'base64' }).send()));
const tokens = rs.flatMap((r) => r.value.map(({ pubkey, account }) => decodeToken(parseBase64RpcAccount(pubkey, account))));

const { data } = await fetchMint(rpc, mintAddress); // works on classic mints too (extensions: none)
const exts = unwrapOption(data.extensions) ?? [];
const hook = exts.find((e) => e.__kind === 'TransferHook');
const needsHookPath = !!hook && hook.programId !== '11111111111111111111111111111111';
const metadata = exts.find((e) => e.__kind === 'TokenMetadata'); // only if MetadataPointer points at the mint

// Fee preview (Kit has no helper): same rounding as the program
const fee = exts.find((e) => e.__kind === 'TransferFeeConfig');
const { epoch } = await rpc.getEpochInfo().send();
const feeOf = (amount: bigint) => {
  if (!fee) return 0n;
  const t = epoch >= fee.newerTransferFee.epoch ? fee.newerTransferFee : fee.olderTransferFee;
  const f = (amount * BigInt(t.transferFeeBasisPoints) + 9_999n) / 10_000n; // ceil
  return f > t.maximumFee ? t.maximumFee : f;
};
```

Send with the hook-aware helper, not `transferToATA` ([transfer-hooks.md](transfer-hooks.md)).

Unity: Solana.Unity-SDK has no Token-2022 support; `TokenProgram.TransferChecked`, `CreateAssociatedTokenAccount`, `WalletBase.Transfer` and its token listing all use the classic program. Derive ATAs with `pubkey.DeriveAssociatedTokenAccount(mint, token2022ProgramId, AssociatedTokenAccountProgram.ProgramIdKey)`, build `TransferChecked` by hand (program ID Token-2022, data `[12, amount u64 LE, decimals]`, extras appended for hooked mints), and resolve hook accounts or parse extensions on a backend.

React Native: `@wallet-ui/react-native-kit` 4.3 pins `@solana/kit` 7, while `@solana-program/token-2022` 0.16 and later need Kit 8; 0.15 is the last Kit 7 release. Check `npm ls @solana/kit`. Confidential-transfer proofs don't run on Hermes ([confidential.md](confidential.md)).

## Venue support (read from each program's source, 2026-09-28)

"Badge" means the venue's admin must approve the specific mint; "rejected" means no path.

| Extension | Orca Whirlpools | Raydium CPMM / CLMM | Meteora DAMM v2 | Kamino (klend) | marginfi v2 |
|---|---|---|---|---|---|
| Transfer fee | allowed | allowed | allowed | only at 0 bps | allowed (fee netted) |
| Transfer hook | badge, works | badge, but swaps fail | free only with no program and no authority; else badge, but swaps fail | only with no hook program | works |
| Permanent delegate | badge | badge | badge | allowed | no filter |
| Non-transferable | rejected | badge | badge | rejected | no filter |
| Default frozen | badge | badge | badge | allowed | no filter |
| Pausable | badge | badge | badge | only while not paused | no filter |
| Mint close authority | badge | badge | badge | allowed | no filter |
| Confidential transfer | public balances only | badge | badge | allowed, auto-approve off | no filter |
| Interest-bearing / scaled UI | allowed | allowed | badge | scaled UI only | no filter |
| Metadata | allowed | allowed | allowed | allowed | no filter |

Sources: `orca-so/whirlpools` `programs/whirlpool/src/util/v2/token.rs`; `raydium-io/raydium-cp-swap` and `raydium-io/raydium-clmm` `is_supported_mint()`; `MeteoraAg/cp-amm` `programs/cp-amm/src/utils/token.rs`; `Kamino-Finance/klend` `programs/klend/src/utils/constraints.rs`; `mrgnlabs/marginfi-v2`. Orca also needs a badge for any mint with a freeze authority, and rejects extensions it doesn't list (PermissionedBurn, ConfidentialMintBurn, group and member). Raydium and DAMM v2 badges skip every per-extension check.

- **A badge is not working hook support.** Raydium CPMM, CLMM and Meteora DAMM v2 can approve a hooked mint, but their swap CPIs never forward the hook's extra accounts, so every swap fails. Orca (SwapV2 forwards `TransferHookA/B` accounts) and marginfi (`invoke_transfer_checked`) work; Meteora DLMM does per its SDK and IDL (program source is closed).
- marginfi has no program-level extension filter: bank creation is admin-only, so the admin is the check.
- Kamino accepts permanent-delegate mints without extra checks, unlike the AMMs.
- Jupiter (from its docs repo `jup-ag/space-station`): limit and DCA orders (Trigger V2) reject transfer-fee and transfer-hook mints unless Jupiter whitelists them, and the older Recurring API takes no Token-2022 mints. Platform fees on Token-2022 tokens through the Metis/v1 path need `instructionVersion=V2`, or fail with `IncorrectTokenProgramID` (6014).
- Wallets (checked from public snippets only): Phantom shows the transfer-fee percentage on send and warns on permanent delegate. Solflare and Backpack advertise extension support without per-extension detail. Test a real mint in each wallet you depend on.

## Risk signals

- Risk scanners reportedly score freeze and mint authority and flag transfer-hook mints (RugCheck), and Phantom reportedly warns on permanent delegate (from public summaries, not checked against their code). Expect traders to see these within minutes of launch.
- Abuse patterns to screen for: freeze-authority honeypots, permanent-delegate clawbacks, hook sell-blockers, mint close-and-reinit and pause abuse. The Token-2022 incident with a public post-mortem is the 2025 ZK ElGamal proof bugs (no funds lost; confidential transfers off for about a year).
- Before trusting a hooked mint, check the hook program's upgrade authority (`solana program show <hook>`) and who can update its ExtraAccountMetaList.
