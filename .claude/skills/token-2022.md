---
name: token-2022
description: "Token-2022 (Token Extensions) gotchas: extension init order and sizing, transfer hooks and extra account metas, fees, metadata, venue compatibility, and supporting both token programs in Anchor 1.x."
---

# Token-2022 (Token Extensions)

What goes wrong when creating or integrating Token-2022 mints. Related references:
- Kit client API (sizes, ATA derivation, fetching): [kit/programs/token-2022.md](ext/solana-dev/skills/solana-dev/references/kit/programs/token-2022.md)
- Security review of extension mints (fee accounting, permanent delegate, mint close and reinit, `.closable()`, metadata spoofing): [security.md, Token-2022 section](ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security)
- Confidential transfers: [confidential-transfers.md](ext/solana-dev/skills/solana-dev/references/confidential-transfers.md)
- NFTs and collections usually fit Metaplex Core better than Token-2022 groups: [metaplex](ext/metaplex/skills/metaplex/SKILL.md) (install first: `bash .claude/bin/skills.sh add metaplex`)

## Rules for every extension

- Mint extensions are fixed at creation. Allocate exactly `getMintLen([...])` / `ExtensionType::try_calculate_account_len::<Mint>(&[...])`, run every extension initializer, then `InitializeMint2`, in one transaction. A size mismatch fails with `InvalidAccountData`; a bad combination fails with `InvalidExtensionCombination`.
- Variable-length TokenMetadata is not part of that allocation: fund lamports for the final size and let the metadata instruction realloc.
- Token accounts carry extensions the mint requires (TransferFeeAmount, TransferHookAccount, PausableAccount, ...). The ATA program and Anchor `init` with `token::`/`associated_token::` size them; manual creation must use `getAccountLenForMint` or the `GetAccountDataSize` instruction. Owner toggles (MemoTransfer, CpiGuard) on an account created without room for them need `Reallocate` first.
- ATAs are derived with the token program as a seed. Pass the Token-2022 ID (`TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`) to ATA derivation, `getMint`/`getAccount`, and ATA creation, or you get a different address.
- Transfer with `transfer_checked`; plain `transfer` fails with `MintRequiredForTransfer` on fee and hook mints. `transfer_checked_with_fee` asserts the expected fee.
- Integrations read the mint's extensions up front and allow-list what they support: `getExtensionTypes(mint.tlvData)` (web3.js), `mint.data.extensions` (Kit), `anchor_spl::token_interface::get_mint_extension_data::<T>(&mint_info)` on-chain.

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

- `token::token_program`, `mint::token_program` and `associated_token::token_program` bind each account to the program that was passed in.
- Credit what arrived, not `amount`: with a transfer fee the destination receives less. `.reload()` after the CPI and use the balance delta.
- Extension constraints on `init`: `extensions::metadata_pointer::{authority, metadata_address}`, `extensions::transfer_hook::{authority, program_id}`, `extensions::group_pointer::{authority, group_address}`, `extensions::group_member_pointer::{authority, member_address}`, `extensions::close_authority::authority`, `extensions::permanent_delegate::delegate`. Extensions without a constraint (e.g. TransferFeeConfig, NonTransferable): create the account with `try_calculate_account_len::<PodMint>`, call the matching `anchor_spl::token_interface::*_initialize` CPIs, then `initialize_mint2`.
- The `spl-token-2022` and `spl-tlv-account-resolution` versions that pair with anchor-lang 1.x still return `solana-program-error` 2.x errors (Anchor uses 3.x), so convert with `.map_err(...)` at the boundary. For direct `spl-*` dependencies see [migrating-v0.32-to-v1.md](ext/solana-dev/skills/solana-dev/references/anchor/migrating-v0.32-to-v1.md), section 17.

## Transfer hooks

```rust
use spl_discriminator::SplDiscriminate;
use spl_tlv_account_resolution::{account::ExtraAccountMeta, seeds::Seed, state::ExtraAccountMetaList};
use spl_transfer_hook_interface::instruction::ExecuteInstruction;

// Anchor 1.x removed #[interface]; InitializeExtraAccountMetaListInstruction works the same way
#[instruction(discriminator = ExecuteInstruction::SPL_DISCRIMINATOR_SLICE)]
pub fn transfer_hook(ctx: Context<TransferHook>, amount: u64) -> Result<()> { /* ... */ }

// Per-owner PDA: seeds reference Execute accounts by index (3 = source authority)
let metas = vec![ExtraAccountMeta::new_with_seeds(
    &[Seed::Literal { bytes: b"allow".to_vec() }, Seed::AccountKey { index: 3 }],
    false, // is_signer
    true,  // is_writable
).map_err(|_| ProgramError::InvalidArgument)?];
ExtraAccountMetaList::init::<ExecuteInstruction>(&mut meta_list.try_borrow_mut_data()?, &metas)
    .map_err(|_| ProgramError::InvalidAccountData)?;
```

- Execute account order: 0 source, 1 mint, 2 destination, 3 source authority, 4 the ExtraAccountMetaList PDA (seeds `["extra-account-metas", mint]` under the hook program), then the extras in list order. Seeds can also use `Seed::AccountData` and `Seed::InstructionData` (the amount).
- The base accounts arrive read-only with signer privileges dropped. Anything the hook writes must be an extra account marked writable in the list.
- Create and initialize the meta-list PDA before the first transfer. Changing it later (`UpdateExtraAccountMetaList`) breaks clients and programs that cached the old list.
- The hook runs after balances move (it sees post-transfer state) and is skipped on self-transfers. Check the `transferring` flag on the source/destination `TransferHookAccount`, plus the mint and ownership checks in security.md.
- Clients resolve extras with Kit `getTransferCheckedWithTransferHookInstructionAsync` (`@solana-program/token-2022`) or web3.js `createTransferCheckedWithTransferHookInstruction`. Simulate before sending: the hook can reject for its own reasons.
- A program that CPIs a transfer of a hook mint needs the hook program, the meta-list PDA and the extras (take them as `remaining_accounts`). `token_interface::transfer_checked` passes only the four base accounts, so use the token-2022 crate's `onchain::invoke_transfer_checked` or add them with `spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi`.
- Every transfer pays the hook's compute; keep it small.

## Extension notes

- **Transfer fee**: withheld in the destination account. The active fee is `get_epoch_fee(current_epoch)`, because `SetTransferFee` takes effect two epochs later; do not read `newer_transfer_fee` blindly. Collect with `harvest_withheld_tokens_to_mint` (permissionless), then `withdraw_withheld_tokens_from_mint` (withdraw authority). Accounts holding withheld fees cannot close.
- **Metadata pointer + TokenMetadata**: initialize the pointer before `InitializeMint2`. TokenMetadata can only live in the mint itself and needs the mint authority's signature. Initialize and `update_field` realloc and assume the rent is already there: web3.js `tokenMetadataInitializeWithRentTransfer` / `tokenMetadataUpdateFieldWithRentTransfer`; in Anchor, top up to `Rent::minimum_balance(new_len)` before `token_metadata_initialize` / `token_metadata_update_field`. Readers check that pointer and `metadata.mint` reference each other.
- **Default account state (Frozen)**: every new account, including ATAs other people create, starts frozen and only the freeze authority can thaw it. Build the thaw (KYC) path before launch.
- **Permanent delegate**: can transfer or burn from any holder. Many venues and users treat such mints as custodial.
- **Non-transferable**: holders can still burn and close. Pointless with fees, hooks or confidential transfers.
- **Interest-bearing, scaled UI amount**: display-only; raw balances and supply never change (scaled UI can schedule a new multiplier at a timestamp). Show amounts through the extension-aware conversion (`amountToUiAmount`), not `amount / 10^decimals`.
- **CPI Guard** (set by the owner): inside a CPI, transfers and burns need a delegate instead of the owner's signature, approve is blocked, and close must pay the owner. Protocols that pull tokens by CPI with the user's signature fail for these users; use a top-level approve plus a delegate transfer.
- **Required memo** (set by the owner): an incoming transfer needs a memo immediately before it at the same level: a top-level memo for a top-level transfer, a memo CPI right before a CPI transfer.
- **Immutable owner**: Token-2022 ATAs always have it; manually created accounts initialize it before `InitializeAccount`.
- **Mint close authority**: closing needs zero supply; see the close-and-reinitialize risk in security.md.
- **Pausable**: the pause authority halts transfers, mints and burns. Vaults holding the token must tolerate failed withdrawals while paused.
- **Group / member**: `max_size` is enforced and adding a member needs the group update authority. Wallet and venue support is thin.
- **Confidential transfers**: check which cluster has the ZK ElGamal proof program enabled before building (the reference tracks it). A transfer spans several transactions with proof context accounts, incoming amounts land in a pending balance until `ApplyPendingBalance`, a fee mint also needs ConfidentialTransferFeeConfig, and a transfer hook cannot see amounts.

## Before launch

- Check every target venue's extension policy. Example: Orca Whirlpools requires an issuer TokenBadge for PermanentDelegate, TransferHook, MintCloseAuthority, DefaultAccountState and Pausable, and does not support NonTransferable or group/member mints.
- Authorities (fee config, withdraw, metadata and hook pointers, pause) outlive the launch. Put the ones you may still need on a multisig and revoke the rest.
- Tests: LiteSVM or Mollusk for hook and fee logic ([testing.md](ext/solana-dev/skills/solana-dev/references/testing.md)). On a Surfpool fork, `surfnet_setTokenAccount` takes the Token-2022 program ID as its last param, and `surfnet_timeTravel` with `absoluteEpoch` crosses the two-epoch fee delay ([cheatcodes.md](ext/solana-dev/skills/solana-dev/references/surfpool/cheatcodes.md)).
