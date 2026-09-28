# Issuer controls (extensions 1–3, 6, 12, 26–28)

Mint close authority, default account state, permanent delegate, pausable, permissioned burn and transfer-fee collection, plus the Foundation tooling that composes them. Official guides: [permissioned-burn](https://solana.com/docs/tokens/extensions/permissioned-burn), [pausable](https://solana.com/docs/tokens/extensions/pausable), [permanent-delegate](https://solana.com/docs/tokens/extensions/permanent-delegate), [default-state](https://solana.com/docs/tokens/extensions/default-state), [close-mint](https://solana.com/docs/tokens/extensions/close-mint), [transfer-fees](https://solana.com/docs/tokens/extensions/transfer-fees), [Token ACL](https://solana.com/docs/tokenization/token-acl). Behavior below verified 2026-09-28 in LiteSVM (token-2022 11.0.0 and 11.1.0) and with `cargo build-sbf`.

## Compliant issuance: Mosaic

For stablecoins, RWAs and other permissioned assets, the Foundation's [Mosaic](https://github.com/solana-foundation/mosaic) SDK and CLI wire these extensions together. Templates:

| Template | Extensions | List mode |
|---|---|---|
| Stablecoin | Metadata, Pausable, Confidential Balances, Permanent Delegate | blocklist by default |
| Arcade token | Metadata, Pausable, Permanent Delegate | allowlist |
| Tokenized security | Stablecoin set + PermissionedBurn + ScaledUiAmount | configurable |

- The published 0.2.0 packages have problems: `@solana/mosaic-cli` 0.2.0 crashes on start (`ERR_MODULE_NOT_FOUND`), and `@solana/mosaic-sdk` 0.2.0 derives confidential keys per token account (or per owner and mint), not per wallet ([confidential.md](confidential.md)). Mosaic's main branch fixes both; use it from source until 0.2.1 is on npm.
- Mosaic targets `@solana/kit` 6 and `@solana-program/token-2022` 0.10, and relies on a root npm override to force token-acl-sdk onto that token-2022 version; a plain `npm i @solana/mosaic-sdk` doesn't apply it. Keep Mosaic in its own package or script if the app uses Kit 8.
- Token ACL wiring is opt-in (`--enable-srfc37`, off by default). New accounts start frozen only in allowlist mode with sRFC-37 enabled; otherwise they start initialized. A fee payer other than the mint authority is supported (sponsored deploys, for example through Kora).
- CLI commands: `mosaic create stablecoin|arcade-token|tokenized-security`, `force-transfer`, `force-burn`, `inspect-mint`, `allowlist|blocklist add|remove`, `token-acl ...`.

## Allow and block lists: Token ACL (sRFC-37)

- The mint uses DefaultAccountState(Frozen) and delegates its freeze authority to the Token ACL program (`TACLkU6CiCdkQN2MjoyDkVg2yAH9zkxiHDsiztQ52TP`). A gate program decides whether a wallet may thaw its own account without the issuer; the reference allow/block list gate is `GATEzzqxhJnsWF6vHRsgtixxSB8PaQdcqGEVTEHWiULz`.
- Deployment status is inconsistent upstream: the token-acl README lists the program address as mainnet, while the solana.com guide says both "deployed on devnet, mainnet after the audits" and "audited and production-ready". Audit reports are in the repo. Confirm the program on the cluster you target.
- sRFC-37 is not final, so the interface can still change.
- Clients: `@solana/token-acl-sdk`, `@solana/token-acl-gate-sdk` (both on `@solana/kit` 6; token-acl-sdk pins `@solana-program/token-2022` 0.12.0), `cargo install token-acl-cli`.
- Gating happens at thaw time, so transfers pay no extra compute. Venues see a default-frozen mint, which Orca, Raydium and Meteora DAMM v2 badge-gate ([integrating-mints.md](integrating-mints.md)).

## PermissionedBurn (28)

While a burn authority is set, `Burn`/`BurnChecked` fail with `InvalidInstruction` (custom error 12), even for the holder. Use the extension's own burn instructions, signed by the holder (or delegate) and the burn authority:

```ts
// Kit @solana-program/token-2022 0.19; getPermissionedBurnInstruction is the unchecked variant
getPermissionedBurnCheckedInstruction({ account, mint, permissionedBurnAuthority, authority: holder, amount, decimals });
```

A wrong burn authority fails with `InvalidAccountData` (a program error, not a custom code).

Anchor 1.2: `anchor-spl` pins `spl-token-2022-interface` 2.x, which has no PermissionedBurn. Add 3.x under another name; it compiles side by side and `?` converts its errors:

```toml
t22v3 = { package = "spl-token-2022-interface", version = "3.1" }
```

```rust
use t22v3::extension::{permissioned_burn::{instruction as pb_ix, PermissionedBurnConfig}, BaseStateWithExtensions, StateWithExtensions};

let ix = pb_ix::burn_checked(
    &token_program.key(), &token_account.key(), &mint.key(),
    &burn_authority.key(), &owner.key(), &[], amount, decimals,
)?;
invoke_signed(&ix, &[token_account, mint, burn_authority, owner], signer_seeds)?;
```

- Reading the config with 3.x: `cfg.authority.get()` returns `Option<Address>`.
- Code built on interface 2.x can still call `get_extension::<T>()` on these mints, but `get_extension_types()` fails with `InvalidAccountData`.
- `solana-test-validator` (token-2022 10.0.0) and Mollusk (a mid-2025 mainnet dump) reject PermissionedBurn; test in LiteSVM or load a newer program ([testing.md](testing.md)).
- The authority changes only through `SetAuthority`; there is no update instruction.

## Pausable (26, 27)

- While paused, `transfer_checked`, `mint_to` and `burn` (permissioned burns included) fail with `MintPaused` (custom error 67), and so do permanent-delegate transfers and confidential-transfer instructions. Kit: `getPauseInstruction`, `getResumeInstruction`; Kit extension kind `PausableConfig`.
- Still allowed while paused: approve and revoke, freeze and thaw, closing accounts, authority changes, and withdrawing or harvesting withheld transfer fees, which moves tokens to the withdraw authority's destination.
- Anchor 1.2 has `extensions::pausable::authority` on `init` and `pausable_initialize`, `pausable_pause` and `pausable_resume` CPIs in `anchor_spl::token_2022_extensions`. Interface 2.x (what `anchor-spl` uses) has `PausableConfig`, so `get_extension::<PausableConfig>()` works in Anchor programs.
- Protocols that hold the token must not let a paused mint block shared instructions (liquidations, other assets' withdrawals). Check `PausableConfig.paused` before acting and isolate per-mint paths.

## Permanent delegate (12), default frozen (6), mint close (3)

- The permanent delegate can transfer or burn from any holder's public balance, including after a sale. Wallets and rug checkers reportedly flag these mints, so expect users to treat the mint as custodial. Revoke it unless the asset needs clawback.
- The permanent delegate can't reach encrypted balances: confidential transfer, withdraw and burn accept only the owner's signature. On a mint with both (Mosaic's stablecoin template), clawback covers public balances only. Keep `auto_approve_new_accounts` off to choose who holds encrypted balances, and keep a freeze authority, since a frozen account can't send, withdraw or burn confidentially.
- DefaultAccountState(Frozen): every new account starts frozen, including ATAs others create. Build the thaw path (Token ACL or your own) before launch; without a freeze authority the mint fails with `MintCannotFreeze` (16). The freeze authority can also switch the default later with `UpdateDefaultAccountState`; once it is revoked, the default can never change.
- Mint close needs zero supply. See the close-and-reinitialize risk in [security.md](../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).
- Authorities outlive the launch: put the pause, burn, delegate and freeze authorities you still need on a multisig and revoke the rest.

## Collecting transfer fees (1, 2)

- Fees sit in each destination account; no helper finds them. Query `getProgramAccounts` on the Token-2022 program with `memcmp` offset 0 = the mint (skip `dataSize` filters: extra extensions change the size), decode with `getTokenDecoder`, and keep accounts whose `TransferFeeAmount.withheldAmount > 0`.
- Harvest (`getHarvestWithheldTokensToMintInstruction`) is permissionless, works on frozen accounts and moves fees into the mint; then `getWithdrawWithheldTokensFromMintInstruction` needs only the withdraw authority. `WithdrawWithheldTokensFromAccounts` skips the mint step but needs the authority on every batch.
- One transaction fits about 31 sources for harvest and 30 for withdraw-from-accounts (the 1,232-byte limit, not compute, at about 450 CU per account). The CLI batches 25.
- Both instructions log `Error harvesting` and still succeed when a source has the wrong mint or no fee extension. Read the logs and re-read balances.
- Kit's `numTokenAccounts` must equal `sources.length`: if it is smaller, the first sources are read as signers and skipped without an error.
- With `withdraw_withheld_authority` set to None, fees can be harvested but never withdrawn.
- A renounced fee authority locks the current and scheduled fee; fees can be up to 10,000 bps with `maximum_fee` up to `u64::MAX`.
