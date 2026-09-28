---
name: token-2022
description: "Token-2022 (Token Extensions) index: rules for every extension, invalid combinations, current versions and SDK support, both token programs in Anchor 1.x, migration, and routing to per-extension files."
---

# Token-2022 (Token Extensions)

What goes wrong when creating or integrating Token-2022 mints, current to 2026-09-28. Official per-extension guides (Kit and Rust code) live at `https://solana.com/docs/tokens/extensions/<page>`; the files below carry what those guides and model training get wrong.

| Task                                                                                                                             | Read                                                                   |
| -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Transfer hooks: writing a hook, calling a hooked mint from a program or client                                                   | [token-2022/transfer-hooks.md](token-2022/transfer-hooks.md)           |
| Issuer controls: permissioned burn, pause, permanent delegate, default frozen, mint close, allow/block lists (Token ACL), Mosaic | [token-2022/issuer-controls.md](token-2022/issuer-controls.md)         |
| Confidential transfers and confidential mint/burn                                                                                | [token-2022/confidential.md](token-2022/confidential.md)               |
| Metadata, groups and members, creating mints with the Kit plan                                                                   | [token-2022/metadata-and-groups.md](token-2022/metadata-and-groups.md) |
| Interest-bearing and scaled UI amount display                                                                                    | [token-2022/display-amounts.md](token-2022/display-amounts.md)         |
| Accepting arbitrary mints in a protocol; DEX, lending and wallet support                                                         | [token-2022/integrating-mints.md](token-2022/integrating-mints.md)     |
| Test harnesses, bundled program versions, error codes                                                                            | [token-2022/testing.md](token-2022/testing.md)                         |

Related: Kit client basics in [kit/programs/token-2022.md](ext/solana-dev/skills/solana-dev/references/kit/programs/token-2022.md); security checklist in [security.md, Token-2022 section](ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security); NFTs in [metaplex](ext/metaplex/skills/metaplex/SKILL.md).

## Versions (checked 2026-09-28)

Training data trails these by one to three majors. Re-check with `npm view <pkg> version` or crates.io before pinning.

| Package                            | Version                                            | Note                                                                                                               |
| ---------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Token-2022 program                 | 11.0.0 on mainnet, 11.1.0 latest (devnet, testnet) | 11.0.0 added PermissionedBurn and restored confidential transfers                                                  |
| `spl-token-2022-interface`         | 3.1.2                                              | state, extensions, instruction builders; 3.x replaces `OptionalNonZeroPubkey` with `MaybeNull<Address>` (`.get()`) |
| `spl-token-2022`                   | 11.1.0                                             | only `onchain`/`offchain` helpers and the processor; its other modules are deprecated re-exports                   |
| `@solana-program/token-2022`       | 0.19.0                                             | Kit client, needs `@solana/kit` 8.x                                                                                |
| `@solana/spl-token`                | 0.4.15                                             | web3.js 1.x client; no ConfidentialMintBurn                                                                        |
| `anchor-lang` / `anchor-spl`       | 1.2.0                                              | `anchor-spl` pins interface `^2` (no PermissionedBurn)                                                             |
| `pinocchio-token-2022`             | 0.4.0                                              | pinocchio 0.11                                                                                                     |
| `solana-zk-sdk` / `@solana/zk-sdk` | 8.0.1 / 0.5.3                                      | confidential-transfer proofs                                                                                       |

Support for the newest extensions:

|                                       | Pausable (26/27)         | PermissionedBurn (28)  | ScaledUiAmount (25) | ConfidentialMintBurn (24) |
| ------------------------------------- | ------------------------ | ---------------------- | ------------------- | ------------------------- |
| Kit `@solana-program/token-2022` 0.19 | yes                      | yes                    | yes                 | yes                       |
| `@solana/spl-token` 0.4.15            | yes                      | yes                    | yes                 | no                        |
| `spl-token` CLI                       | yes                      | yes                    | yes                 | create only               |
| `anchor-spl` 1.2                      | constraint + CPI helpers | no (use interface 3.x) | no                  | no                        |
| `pinocchio-token-2022` 0.4            | yes                      | yes                    | yes                 | no                        |

## Rules for every extension

- Mint extensions are fixed at creation. Allocate exactly the fixed-size length (`getMintSize([...])`, `ExtensionType::try_calculate_account_len::<Mint>(&[...])`), run the pre-initialize instructions, then `InitializeMint2`, in one transaction. TokenMetadata and TokenGroup/TokenGroupMember initialize _after_ the mint, need the mint authority's signature, and realloc into lamports you funded up front. A size mismatch fails with `InvalidAccountData`.
- Token accounts carry extensions the mint requires (TransferFeeAmount, TransferHookAccount, PausableAccount, NonTransferableAccount). The ATA program and Anchor `init` with `token::`/`associated_token::` size them; manual creation uses `getAccountLenForMint` or `GetAccountDataSize`. Owner toggles (MemoTransfer, CpiGuard) on an account created without room need `Reallocate` first.
- ATAs derive from the token program. Pass the Token-2022 ID (`TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`) to ATA derivation, fetches and ATA creation, or you get a different address.
- Transfer with `transfer_checked`. Plain `transfer` fails with `MintRequiredForTransfer` when the source carries TransferFeeAmount, TransferHookAccount or PausableAccount.
- Read a mint's extensions up front and allow-list what you support: `unwrapOption(mint.data.extensions)` (Kit), `getExtensionTypes(mint.tlvData)` (web3.js), `get_extension::<T>()` on-chain. Prefer targeted `get_extension::<T>()` over `get_extension_types()`: interface 2.x (what `anchor-spl` 1.2 uses) returns `InvalidAccountData` for the whole list on a mint carrying PermissionedBurn.

## Invalid combinations

`InitializeMint2` rejects these with `InvalidExtensionCombination` (custom error 51), per `check_for_invalid_mint_extension_combinations` in the token-2022 interface crate:

| Rule                                            |                                                           |
| ----------------------------------------------- | --------------------------------------------------------- |
| ScaledUiAmount with InterestBearingConfig       | pick one                                                  |
| TransferFeeConfig with ConfidentialTransferMint | also needs ConfidentialTransferFeeConfig                  |
| ConfidentialTransferFeeConfig                   | needs both TransferFeeConfig and ConfidentialTransferMint |
| ConfidentialMintBurn                            | needs ConfidentialTransferMint                            |
| NonTransferable with ConfidentialTransferMint   | also needs ConfidentialMintBurn                           |

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
- Credit what arrived, not `amount`: with a transfer fee the destination receives less. `.reload()` after the CPI and use the balance delta.
- Extension constraints on `init`: `extensions::metadata_pointer::{authority, metadata_address}`, `extensions::transfer_hook::{authority, program_id}`, `extensions::group_pointer::{authority, group_address}`, `extensions::group_member_pointer::{authority, member_address}`, `extensions::close_authority::authority`, `extensions::permanent_delegate::delegate`, `extensions::pausable::authority` (1.2). Extensions without a constraint (TransferFeeConfig, NonTransferable, ScaledUiAmount, PermissionedBurn): create the account with `try_calculate_account_len::<PodMint>`, call the initialize CPIs (`anchor_spl::token_interface::*_initialize`, or interface 3.x builders for PermissionedBurn), then `initialize_mint2`.
- Anchor 1.2 with `spl-token-2022` 11.x or interface 3.x shares `solana-program-error` 3.x, so `?` converts their errors. An older direct `spl-*` dependency on `solana-program-error` 2.x needs `.map_err(...)`; see [migrating-v0.32-to-v1.md](ext/solana-dev/skills/solana-dev/references/anchor/migrating-v0.32-to-v1.md), section 17.

## Extensions the model already handles

Short reminders; the linked docs have the code.

- **Transfer fee** ([transfer-fees](https://solana.com/docs/tokens/extensions/transfer-fees)): withheld in the destination account. The active fee is `get_epoch_fee(current_epoch)` because `SetTransferFee` applies two epochs later. Harvest with `harvest_withheld_tokens_to_mint` (permissionless), withdraw with the withdraw authority. Accounts holding withheld fees cannot close (`AccountHasWithheldTransferFees`).
- **Non-transferable**: holders can still burn and close. Minting to an account requires ImmutableOwner on it (`NonTransferableNeedsImmutableOwnership`); ATAs have it.
- **CPI Guard** (set by the owner): inside a CPI, owner-signed transfers and burns fail, approve is blocked, and close must pay the owner. Pull tokens with a top-level approve plus a delegate transfer.
- **Required memo** (set by the owner): an incoming transfer needs a memo immediately before it at the same level (`NoMemo` otherwise).
- **Immutable owner**: Token-2022 ATAs always have it; manually created accounts initialize it before `InitializeAccount3`.

## Migrating from SPL Token

There is no in-place upgrade; a mint belongs to one program. Options:

- **New Token-2022 mint** plus a swap or claim program: full control of the extension set; you own the swap program's security and move liquidity and listings yourself.
- **token-wrap** (`TwRapQCDhWkZRrDaHfZGuHxkZ91gHDRkyuzNqeU5MgR`, JS `@solana-program/token-wrap`): 1:1 escrowed wrapping, audited. The wrapped mint only gets ConfidentialTransferMint unless you fork its `MintCustomizer`, and supply splits between wrapped and unwrapped. Mainnet deployment was unconfirmed on 2026-09-28 (`solana account TwRapQCDhWkZRrDaHfZGuHxkZ91gHDRkyuzNqeU5MgR -u mainnet-beta`).

p-token (SIMD-0266) replaced the classic Token program's code in place at epoch 971. It adds no extensions and is unrelated to migrating.

## Before launch

- Check every target venue's extension policy before fixing the extension set ([integrating-mints.md](token-2022/integrating-mints.md)).
- Authorities (fee config, withdraw, metadata and hook pointers, pause, permanent delegate, permissioned burn) outlive the launch. Put the ones you may still need on a multisig and revoke the rest.
- Test against the program version mainnet runs; `solana-test-validator` and Mollusk still bundle 10.0.0 ([testing.md](token-2022/testing.md)).
