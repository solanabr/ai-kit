---
name: token-2022
description: "Token-2022 (Token Extensions) index: rules for every extension, invalid combinations, current versions and SDK support, both token programs in Anchor 1.x, CLI, migration, and routing to per-extension files."
---

# Token-2022 (Token Extensions)

What goes wrong when creating or integrating Token-2022 mints, current to 2026-09-28. Official per-extension guides (Kit and Rust code) live under `https://solana.com/docs/tokens/extensions/`; the files below carry what those guides and model training get wrong.

| Task | Read |
|---|---|
| Transfer hooks: writing a hook (Anchor, Pinocchio), moving hooked mints from clients and programs | [token-2022/transfer-hooks.md](token-2022/transfer-hooks.md) |
| Issuer controls: permissioned burn, pause, permanent delegate, default frozen, mint close, fee collection, Token ACL, Mosaic | [token-2022/issuer-controls.md](token-2022/issuer-controls.md) |
| Confidential transfers, confidential fees, confidential mint/burn | [token-2022/confidential.md](token-2022/confidential.md) |
| Metadata, groups and members, creating mints with the Kit plan | [token-2022/metadata-and-groups.md](token-2022/metadata-and-groups.md) |
| Interest-bearing and scaled UI amount display | [token-2022/display-amounts.md](token-2022/display-amounts.md) |
| Accepting arbitrary mints (programs, frontends, payments, Unity, React Native); DEX and lending support | [token-2022/integrating-mints.md](token-2022/integrating-mints.md) |
| Test harnesses, bundled program versions, error codes | [token-2022/testing.md](token-2022/testing.md) |

Related: Kit client basics in [kit/programs/token-2022.md](ext/solana-dev/skills/solana-dev/references/kit/programs/token-2022.md); security checklist in [security.md, Token-2022 section](ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security); NFTs in [metaplex](ext/metaplex/skills/metaplex/SKILL.md).

Where those references are out of date (checked 2026-09-28):
- security.md says `token_interface` handles all extensions; it doesn't forward transfer-hook accounts (see the Anchor section below).
- kit/programs/token-2022.md says every extension instruction comes before mint initialization; TokenMetadata and TokenGroup/TokenGroupMember come after.
- [migrating-v0.32-to-v1.md](ext/solana-dev/skills/solana-dev/references/anchor/migrating-v0.32-to-v1.md) section 17 moves programs to `spl-token-2022-interface` 2.1. That is right for `anchor-spl` compatibility, but PermissionedBurn needs interface 3.x and `onchain::invoke_transfer_checked` lives in `spl-token-2022` 11.x; both work alongside Anchor 1.2.
- programs/pinocchio.md pins `pinocchio-token-2022` 0.3, which has no extension state; use 0.4 ([transfer-hooks.md](token-2022/transfer-hooks.md)).
- confidential-transfers.md: see [confidential.md](token-2022/confidential.md).

## Versions (checked 2026-09-28)

Training data trails these by one to three majors. Re-check with `npm view <pkg> version` or crates.io before pinning.

| Package | Version | Why it matters |
|---|---|---|
| Token-2022 program | 11.0.0 on mainnet per release notes (confirm with `solana program show`); 11.1.0 on devnet and testnet | 11.0.0 added PermissionedBurn and `Batch`; 11.1.0 (pending on mainnet) brings memo v4 and CPI Guard checks on `WithdrawExcessLamports` |
| `spl-token-2022-interface` | 3.1.2 | state and builders; 3.x uses `MaybeNull<Address>` (`.get()`) instead of `OptionalNonZeroPubkey` |
| `spl-token-2022` | 11.1.0 | only `onchain`/`offchain` helpers and the processor; its other modules are deprecated re-exports |
| `@solana-program/token-2022` | 0.19.0 | Kit client; peer `@solana/kit` ^8.3 (8.0–8.2 run but fail type-checking) |
| `@solana/spl-token` | 0.4.15 | web3.js 1.x client; no ConfidentialMintBurn |
| `anchor-lang` / `anchor-spl` | 1.2.0 | `anchor-spl` pins interface `^2` (no PermissionedBurn) |
| `pinocchio-token-2022` | 0.4.0 | pinocchio 0.11 |
| `solana-zk-sdk` | 7.x | the proof crates 0.6.1, `spl-token-client` 0.19.1 and the CLI need ^7; 8.x pulls a second, incompatible copy |
| `@solana/zk-sdk` | 0.5.x | 0.5.3 changed `signerMessage()`; Kit's own repo pins 0.5.2 |

Support for the newest extensions:

| | Pausable (26/27) | PermissionedBurn (28) | ScaledUiAmount (25) | ConfidentialMintBurn (24) |
|---|---|---|---|---|
| Kit `@solana-program/token-2022` 0.19 | yes | yes | yes | yes |
| `@solana/spl-token` 0.4.15 | yes | yes | yes | no |
| `spl-token` CLI 5.6.1 | yes | yes | yes | no |
| `anchor-spl` 1.2 | constraint + CPI helpers | no (use interface 3.x) | no | no |
| `pinocchio-token-2022` 0.4 | yes | yes | instruction builders only, no state | no |

## Rules for every extension

- Mint extensions are fixed at creation. Allocate exactly the fixed-size length (`getMintSize([...])`, `ExtensionType::try_calculate_account_len::<Mint>(&[...])`), run the pre-initialize instructions, then initialize the mint, in one transaction. TokenMetadata and TokenGroup/TokenGroupMember initialize _after_ the mint, need the mint authority's signature, and realloc into lamports you funded up front. A size mismatch fails with `InvalidAccountData`.
- Token accounts carry extensions the mint requires (TransferFeeAmount, TransferHookAccount, PausableAccount, NonTransferableAccount). The ATA program and Anchor `init` with `token::`/`associated_token::` size them; manual creation uses `getAccountLenForMint` or `GetAccountDataSize`. Owner toggles (MemoTransfer, CpiGuard) on an account created without room need `Reallocate` first.
- ATAs derive from the token program. Pass the Token-2022 ID (`TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`) to ATA derivation, fetches and ATA creation, or you get a different address.
- Transfer with `transfer_checked`. Plain `transfer` fails with `MintRequiredForTransfer` when the source carries TransferFeeAmount, TransferHookAccount or PausableAccount.
- Read a mint's extensions up front and allow-list what you support: `unwrapOption(mint.data.extensions)` (Kit), `getExtensionTypes(mint.tlvData)` (web3.js), `get_extension::<T>()` on-chain. Prefer targeted `get_extension::<T>()` over `get_extension_types()`: interface 2.x (what `anchor-spl` 1.2 uses) returns `InvalidAccountData` for the whole list on a mint carrying PermissionedBurn.
- An authority set to `None` can't be set again, so a renounced extension stays as it is. A renounced fee authority still lets an already scheduled `newer_transfer_fee` take effect.
- Program 11.x has a `Batch` instruction (discriminator 255) that runs several token instructions in one call; Kit `getBatchInstruction`. Batches can't nest.

## Invalid combinations

Mint initialization (`InitializeMint` or `InitializeMint2`; the Kit plan uses v1) rejects these with `InvalidExtensionCombination` (custom error 51). This is the complete list in `check_for_invalid_mint_extension_combinations` (interface crate, program 11.x); Pausable and PermissionedBurn combine with anything:

| Rule | |
|---|---|
| ScaledUiAmount with InterestBearingConfig | pick one |
| TransferFeeConfig with ConfidentialTransferMint | also needs ConfidentialTransferFeeConfig |
| ConfidentialTransferFeeConfig | needs both TransferFeeConfig and ConfidentialTransferMint |
| ConfidentialMintBurn | needs ConfidentialTransferMint |
| NonTransferable with ConfidentialTransferMint | also needs ConfidentialMintBurn |

Allowed despite what guides imply: NonTransferable with TransferFee or TransferHook, and ConfidentialTransfer with TransferHook (the hook receives `u64::MAX` as the amount). DefaultAccountState(Frozen) without a freeze authority fails with `MintCannotFreeze` (16).

## Supporting both token programs (Anchor 1.x)

```rust
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked};

#[derive(Accounts)]
pub struct Pay<'info> {
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: InterfaceAccount<'info, TokenAccount>,
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    pub authority: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>, // Token or Token-2022
}

pub fn pay(ctx: Context<Pay>, amount: u64) -> Result<()> {
    let accounts = TransferChecked {
        from: ctx.accounts.from.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.to.to_account_info(),
        authority: ctx.accounts.authority.to_account_info(),
    };
    // 1.x: CpiContext takes the program Pubkey, not an AccountInfo
    let cpi = CpiContext::new(ctx.accounts.token_program.key(), accounts);
    token_interface::transfer_checked(cpi, amount, ctx.accounts.mint.decimals)
}
```

- `token_interface::transfer_checked` forwards only the four base accounts, so it fails on transfer-hook mints. Programs that may see hooked mints use `spl_token_2022::onchain::invoke_transfer_checked` with `ctx.remaining_accounts` ([transfer-hooks.md](token-2022/transfer-hooks.md)).
- `token::token_program`, `mint::token_program` and `associated_token::token_program` bind each account to the program that was passed in.
- Credit what arrived, not `amount`: with a transfer fee the destination receives less. `.reload()` after the CPI and use the balance delta; exact-out math needs `calculate_inverse_epoch_fee`.
- Extension constraints on `init`: `extensions::metadata_pointer::{authority, metadata_address}`, `extensions::transfer_hook::{authority, program_id}`, `extensions::group_pointer::{authority, group_address}`, `extensions::group_member_pointer::{authority, member_address}`, `extensions::close_authority::authority`, `extensions::permanent_delegate::delegate`, `extensions::pausable::authority` (1.2).
- Anchor 1.2 with `spl-token-2022` 11.x or interface 3.x shares `solana-program-error` 3.x, so `?` converts their errors. A direct `spl-*` dependency still on `solana-program-error` 2.x needs `.map_err(...)` at the boundary.

`init` runs `InitializeMint2` itself, so a mint that also needs an extension without a constraint (TransferFeeConfig, NonTransferable, InterestBearingConfig, DefaultAccountState, ScaledUiAmount, PermissionedBurn) can't use `init`. Create it by hand (the helpers come with `anchor-spl`'s default `token_2022_extensions` feature; ScaledUiAmount uses the interface builder `scaled_ui_amount::instruction::initialize`, PermissionedBurn the 3.x one):

```rust
use anchor_lang::system_program::{self, CreateAccount};
use anchor_spl::token_2022::spl_token_2022::{extension::ExtensionType, pod::PodMint};
use anchor_spl::token_interface::{self, InitializeMint2, TransferFeeInitialize};

let space = ExtensionType::try_calculate_account_len::<PodMint>(&[ExtensionType::TransferFeeConfig])?;
system_program::create_account(
    CpiContext::new(ctx.accounts.system_program.key(),
        CreateAccount { from: ctx.accounts.payer.to_account_info(), to: ctx.accounts.mint.to_account_info() }),
    Rent::get()?.minimum_balance(space), space as u64, &ctx.accounts.token_program.key(),
)?;
token_interface::transfer_fee_initialize(
    CpiContext::new(ctx.accounts.token_program.key(), TransferFeeInitialize {
        token_program_id: ctx.accounts.token_program.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
    }),
    Some(&auth), Some(&auth), fee_bps, max_fee,
)?;
token_interface::initialize_mint2(
    CpiContext::new(ctx.accounts.token_program.key(), InitializeMint2 { mint: ctx.accounts.mint.to_account_info() }),
    decimals, &auth, None,
)?;
```

## Extensions the model already handles

- **Transfer fee** ([transfer-fees](https://solana.com/docs/tokens/extensions/transfer-fees)): withheld in the destination account; the active fee is `get_epoch_fee(current_epoch)` because `SetTransferFee` applies two epochs later. Collection is in [issuer-controls.md](token-2022/issuer-controls.md).
- **Non-transferable**: holders can still burn and close. Minting to an account requires ImmutableOwner on it (`NonTransferableNeedsImmutableOwnership`); ATAs have it.
- **CPI Guard, required memo, immutable owner**: covered by the docs; the integrator impact is in [integrating-mints.md](token-2022/integrating-mints.md).

## spl-token CLI (5.6.1)

- Target Token-2022 with `--program-2022` (or `-p <ID>`; the two conflict).
- `create-token` flags: `--transfer-fee-basis-points <BPS> --transfer-fee-maximum-fee <AMOUNT>` (a UI amount: `5` means 5 tokens), `--enable-metadata` (then `initialize-metadata`), `--enable-group` (then `initialize-group`), `--enable-pause`, `--enable-permissioned-burn`, `--ui-amount-multiplier`, `--interest-rate`, `--transfer-hook <PROGRAM>`, `--enable-permanent-delegate`, `--enable-non-transferable`, `--default-account-state frozen` (needs `--enable-freeze`).
- Later changes: `pause`/`resume`, `update-ui-amount-multiplier`, `set-interest-rate`, `withdraw-withheld-tokens` (pass sources or `--include-mint`).
- No ConfidentialMintBurn support. The `spl-token` bundled with Agave 3.1 is 5.5.0, which lacks the permissioned-burn flags.

## Migrating from SPL Token

There is no in-place upgrade; a mint belongs to one program. Options:

- **New Token-2022 mint** plus a swap or claim program: full control of the extension set; you own the swap program's security and move liquidity and listings yourself. Claim tooling built on `anchor_spl::token` (for example Jito's merkle distributor) pays classic tokens only.
- **token-upgrade** (`TkupDoNseygccBCjSsrSpMccjwHfTYwcrjpnDSrFDhC`): burns the holder's whole old balance and releases the same amount of the new mint from an escrow; decimals must match. It lives in the archived SPL repo and its mainnet deployment is unconfirmed.
- **token-wrap** (`TwRapQCDhWkZRrDaHfZGuHxkZ91gHDRkyuzNqeU5MgR`, JS `@solana-program/token-wrap`): 1:1 escrowed wrapping, audited, copies decimals and the freeze authority. The wrapped mint only gets ConfidentialTransferMint unless you fork its `MintCustomizer`, and supply splits between wrapped and unwrapped. Mainnet deployment was unconfirmed on 2026-09-28 (`solana account TwRapQCDhWkZRrDaHfZGuHxkZ91gHDRkyuzNqeU5MgR -u mainnet-beta`).

Holders need new token accounts under the Token-2022 program: about 0.0021 SOL each (more with account extensions), so budget rent for every holder.

## Before launch

- Check every target venue's extension policy before fixing the extension set ([integrating-mints.md](token-2022/integrating-mints.md)).
- Authorities (fee config, withdraw, metadata and hook pointers, pause, permanent delegate, permissioned burn) outlive the launch. Put the ones you may still need on a multisig and revoke the rest. TokenMetadata, TokenGroup and confidential-transfer mint updates need a direct signature, so an SPL Token multisig can't hold those authorities; a Squads vault can, because it signs as a PDA.
- Test against the program version mainnet runs; `solana-test-validator` bundles 10.0.0 and Mollusk a mid-2025 dump ([testing.md](token-2022/testing.md)).
