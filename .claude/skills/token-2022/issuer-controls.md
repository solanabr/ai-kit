# Issuer controls (extensions 3, 6, 12, 26–28)

Mint close authority, default account state, permanent delegate, pausable and permissioned burn, plus the Foundation tooling that composes them. Official guides: [permissioned-burn](https://solana.com/docs/tokens/extensions/permissioned-burn), [pausable](https://solana.com/docs/tokens/extensions/pausable), [permanent-delegate](https://solana.com/docs/tokens/extensions/permanent-delegate), [default-state](https://solana.com/docs/tokens/extensions/default-state), [close-mint](https://solana.com/docs/tokens/extensions/close-mint), [Token ACL](https://solana.com/docs/tokenization/token-acl). Behavior below verified 2026-09-28 in LiteSVM (token-2022 11.0.0 and 11.1.0) and with `cargo build-sbf`.

## Compliant issuance: start from Mosaic

For stablecoins, RWAs and other permissioned assets, the Foundation's [Mosaic](https://github.com/solana-foundation/mosaic) SDK and CLI (`@solana/mosaic-sdk`, `@solana/mosaic-cli`, 0.2.0) already wire these extensions together, and its SDK unit tests pass. Templates:

| Template | Extensions | List mode |
|---|---|---|
| Stablecoin | Metadata, Pausable, Confidential Balances, Permanent Delegate | blocklist by default |
| Arcade token | Metadata, Pausable, Permanent Delegate | allowlist |
| Tokenized security | Stablecoin set + PermissionedBurn + ScaledUiAmount | configurable |

- Token ACL wiring is opt-in (`--enable-srfc37`, off by default). New accounts start frozen only in allowlist mode with sRFC-37 enabled; otherwise they start initialized.
- A fee payer other than the mint authority is supported (sponsored deploys, for example through Kora).
- CLI: `mosaic create stablecoin|arcade-token|tokenized-security`, `force-transfer`, `force-burn`, `inspect-mint`, `allowlist|blocklist add|remove`, `token-acl ...`.
- Mosaic 0.2.0 depends on `@solana/kit` ^6.10 and `@solana-program/token-2022` ^0.10, older than the versions in [the index](../token-2022.md#versions-checked-2026-09-28). Keep it in its own package or script if the app uses Kit 8. Its SDK README lists even older versions; trust `package.json`.
- Build by hand only when the templates don't fit.

## Allow and block lists: Token ACL (sRFC-37)

- The mint uses DefaultAccountState(Frozen) and delegates its freeze authority to the Token ACL program (`TACLkU6CiCdkQN2MjoyDkVg2yAH9zkxiHDsiztQ52TP`). A gate program decides whether a wallet may thaw its own account without the issuer; the reference allow/block list gate is `GATEzzqxhJnsWF6vHRsgtixxSB8PaQdcqGEVTEHWiULz`.
- Both are on devnet and mainnet. The token-acl repo includes a completed audit report (Accretion, 2025). sRFC-37 itself is not final, so the interface can still change.
- Clients: `@solana/token-acl-sdk`, `@solana/token-acl-gate-sdk`, `cargo install token-acl-cli`.
- Compared with a transfer hook, gating happens at thaw time, so transfers pay no extra compute. Venues see a default-frozen mint, which Orca, Raydium and Meteora DAMM v2 badge-gate ([integrating-mints.md](integrating-mints.md)).

## PermissionedBurn (28)

While a burn authority is set, `Burn`/`BurnChecked` fail with `InvalidInstruction` (custom error 12), even for the holder. Use the extension's own burn instructions, signed by the holder (or delegate) and the burn authority:

```ts
// Kit @solana-program/token-2022 0.19
getPermissionedBurnCheckedInstruction({
  account,
  mint,
  permissionedBurnAuthority,
  authority: holder,
  amount,
  decimals,
});
```

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

- Reading the config with 3.x: `cfg.authority.get()` returns `Option<Address>` (3.x uses `MaybeNull`, not `OptionalNonZeroPubkey`).
- Code built on interface 2.x can still call `get_extension::<T>()` on these mints, but `get_extension_types()` fails with `InvalidAccountData`.
- `solana-test-validator` (token-2022 10.0.0) and Mollusk (a mid-2025 mainnet dump) reject PermissionedBurn; test in LiteSVM or load a newer program ([testing.md](testing.md)).
- Mint with Kit: `extension('PermissionedBurn', { authority: some(burnAuthority) })` in `getCreateMintInstructionPlan`.

## Pausable (26, 27)

- While paused, `transfer_checked`, `mint_to` and `burn` fail with `MintPaused` (custom error 67), and so do permanent-delegate transfers and confidential-transfer instructions. Kit: `getPauseInstruction`, `getResumeInstruction`.
- Anchor 1.2 has `extensions::pausable::authority` on `init` and `pausable_initialize`, `pausable_pause` and `pausable_resume` CPIs in `anchor_spl::token_2022_extensions`. Interface 2.x (what `anchor-spl` uses) has `PausableConfig`, so `get_extension::<PausableConfig>()` works in Anchor programs.
- Protocols that hold the token must not let a paused mint block shared instructions (liquidations, other assets' withdrawals). Check `PausableConfig.paused` before acting and isolate per-mint paths.

## Permanent delegate (12), default frozen (6), mint close (3)

- Permanent delegate can transfer or burn from any holder, including after a sale. It was used in 2024 to burn buyers' tokens seconds after purchase. Wallets and rug checkers reportedly flag these mints (Phantom shows a warning), so expect users to treat the mint as custodial. Revoke it unless the asset needs clawback.
- DefaultAccountState(Frozen): every new account starts frozen, including ATAs others create. Build the thaw path (Token ACL or your own) before launch; without a freeze authority the mint fails with `MintCannotFreeze` (16). A freeze authority can't be added after creation, but one kept from launch and used later trapped holders in the 2024 BONKKILLER honeypot; check it before buying or listing.
- Mint close needs zero supply. See the close-and-reinitialize risk in [security.md](../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).
- Authorities outlive the launch: put the pause, burn, delegate and freeze authorities you still need on a multisig and revoke the rest.
