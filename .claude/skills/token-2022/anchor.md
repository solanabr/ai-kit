# Anchor 1.x with Token-2022

Supporting both token programs, extension constraints, and mints whose extensions have no Anchor constraint. Verified 2026-09-28 with Anchor 1.2.0 (`cargo build-sbf` plus LiteSVM runs). Index: [token-2022.md](../token-2022.md).

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

- `token_interface::transfer_checked` forwards only the four base accounts, so it fails on transfer-hook mints. Programs that may see hooked mints use `spl_token_2022::onchain::invoke_transfer_checked` with `ctx.remaining_accounts` ([transfer-hooks.md](transfer-hooks.md)).
- `token::token_program`, `mint::token_program` and `associated_token::token_program` bind each account to the program that was passed in.
- Credit what arrived, not `amount`: with a transfer fee the destination receives less. `.reload()` after the CPI and use the balance delta; exact-out math needs `calculate_inverse_epoch_fee`.
- Extension constraints on `init`: `extensions::metadata_pointer::{authority, metadata_address}`, `extensions::transfer_hook::{authority, program_id}`, `extensions::group_pointer::{authority, group_address}`, `extensions::group_member_pointer::{authority, member_address}`, `extensions::close_authority::authority`, `extensions::permanent_delegate::delegate`, `extensions::pausable::authority` (1.2).
- Anchor 1.2 with `spl-token-2022` 11.x or interface 3.x shares `solana-program-error` 3.x, so `?` converts their errors. A direct `spl-*` dependency still on `solana-program-error` 2.x needs `.map_err(...)` at the boundary.
- `anchor_spl::token_2022::spl_token_2022` is `spl-token-2022-interface` 2.x under the old crate name, not the program crate: state, extensions and instruction builders, but no `onchain` helpers and no PermissionedBurn. Add `spl-token-2022` 11.x (`no-entrypoint`) for `invoke_transfer_checked`.

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
