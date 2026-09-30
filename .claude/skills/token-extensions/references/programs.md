# Token-2022 in programs

Checked against anchor-lang and anchor-spl 1.2.0. anchor-spl re-exports spl-token-2022-interface 2.x as `anchor_spl::token_interface::spl_token_2022` (and `anchor_spl::token_2022::spl_token_2022`). Depend on that re-export, or on `spl-token-2022-interface = "2"`, rather than on the `spl-token-2022` program crate, so one version of the types is in play. The 3.x interface is needed only for PermissionedBurn.

## Accept both token programs

```rust
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked};

#[derive(Accounts)]
pub struct Pay<'info> {
    #[account(mut, token::mint = mint, token::authority = authority, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: InterfaceAccount<'info, TokenAccount>,
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    pub authority: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>, // Token or Token-2022
}

pub fn pay(ctx: Context<Pay>, amount: u64) -> Result<u64> {
    let before = ctx.accounts.to.amount;
    let accounts = TransferChecked {
        from: ctx.accounts.from.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.to.to_account_info(),
        authority: ctx.accounts.authority.to_account_info(),
    };
    // Anchor 1.x: CpiContext takes the program id, not an AccountInfo
    let cpi = CpiContext::new(ctx.accounts.token_program.key(), accounts);
    token_interface::transfer_checked(cpi, amount, ctx.accounts.mint.decimals)?;
    ctx.accounts.to.reload()?;
    // With a transfer fee the recipient gets less than `amount`: credit what arrived
    let received = ctx.accounts.to.amount.checked_sub(before).ok_or(ProgramError::ArithmeticOverflow)?;
    Ok(received)
}
```

- `token::token_program`, `mint::token_program` and `associated_token::token_program` bind each account to the token program that was passed in.
- `transfer_checked` passes only the four base accounts, so it can't move a hook mint: see [transfer-hooks.md](transfer-hooks.md#cpi-a-transfer-of-a-hook-mint). A PDA authority uses `CpiContext::new_with_signer(program_id, accounts, signer_seeds)`.

## Allow-list a mint's extensions

Decide which extensions your program supports and reject the rest before accepting a mint:

```rust
use anchor_lang::prelude::*;
use anchor_spl::token_interface::spl_token_2022::{
    extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions},
    state::Mint as MintState,
};

#[error_code]
pub enum PoolError {
    #[msg("Mint has an extension this program does not support")]
    UnsupportedMintExtension,
}

pub fn check_mint_extensions(mint_info: &AccountInfo) -> Result<()> {
    if *mint_info.owner != anchor_spl::token_2022::ID {
        return Ok(()); // classic Token mint: no extensions
    }
    let data = mint_info.try_borrow_data()?;
    let mint = StateWithExtensions::<MintState>::unpack(&data)?;
    for extension in mint.get_extension_types()? {
        match extension {
            ExtensionType::MetadataPointer | ExtensionType::TokenMetadata | ExtensionType::TransferFeeConfig => {}
            _ => return err!(PoolError::UnsupportedMintExtension),
        }
    }
    Ok(())
}
```

For one fixed-size extension's values use `anchor_spl::token_interface::get_mint_extension_data::<T>(&mint_info)`; for TokenMetadata use `get_variable_len_extension::<TokenMetadata>()` on the unpacked state. The attack patterns behind each extension (fee accounting, permanent delegate, mint close and reinit, hook abuse) are in [security.md, Token-2022 section](../../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).

## Create a mint with extensions that have no constraint

Anchor's `init` handles MetadataPointer, GroupPointer, GroupMemberPointer, TransferHook, MintCloseAuthority, PermanentDelegate and Pausable. For any other extension, create the account, run the extension initializers, then `initialize_mint2`, all in one instruction:

```rust
use anchor_lang::prelude::*;
use anchor_lang::system_program::{create_account, CreateAccount};
use anchor_spl::token_interface::{
    initialize_mint2, transfer_fee_initialize, InitializeMint2, Token2022, TransferFeeInitialize,
    spl_token_2022::{extension::ExtensionType, state::Mint as MintState},
};

#[derive(Accounts)]
pub struct CreateFeeMint<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut)]
    pub mint: Signer<'info>,
    pub authority: Signer<'info>,
    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

pub fn create_fee_mint(ctx: Context<CreateFeeMint>, fee_bps: u16, max_fee: u64) -> Result<()> {
    // Exactly the size of the extensions initialized before initialize_mint2
    let space = ExtensionType::try_calculate_account_len::<MintState>(&[ExtensionType::TransferFeeConfig])?;
    let lamports = Rent::get()?.minimum_balance(space);
    let accounts = CreateAccount { from: ctx.accounts.payer.to_account_info(), to: ctx.accounts.mint.to_account_info() };
    create_account(
        CpiContext::new(ctx.accounts.system_program.key(), accounts),
        lamports,
        space as u64,
        &ctx.accounts.token_program.key(),
    )?;

    let authority = ctx.accounts.authority.key();
    let accounts = TransferFeeInitialize {
        token_program_id: ctx.accounts.token_program.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
    };
    transfer_fee_initialize(
        CpiContext::new(ctx.accounts.token_program.key(), accounts),
        Some(&authority), // transfer fee config authority
        Some(&authority), // withdraw withheld authority
        fee_bps,
        max_fee,
    )?;

    let accounts = InitializeMint2 { mint: ctx.accounts.mint.to_account_info() };
    initialize_mint2(CpiContext::new(ctx.accounts.token_program.key(), accounts), 6, &authority, None)
}
```

- The other initializers follow the same pattern: `default_account_state_initialize`, `interest_bearing_mint_initialize`, `non_transferable_mint_initialize`, `permanent_delegate_initialize`, `mint_close_authority_initialize`, `pausable_initialize`, `transfer_hook_initialize`, `metadata_pointer_initialize`, `group_pointer_initialize`, `group_member_pointer_initialize`. `anchor_spl::token_interface::find_mint_account_size(Some(&vec![...]))` computes the same size as above.
- These helpers take the token program from their `token_program_id` account and pass no multisig signers.
- anchor-spl 1.2.0 has no helpers for ScaledUiAmount, PermissionedBurn or the confidential extensions. Build those instructions from the interface crate and `invoke` them.

## Before launch

- Check every target venue's extension policy. Orca Whirlpools, for example, accepts TransferFeeConfig, InterestBearingConfig, MetadataPointer, TokenMetadata and ScaledUiAmount; supports confidential mints for public transfers only; needs an issuer TokenBadge for PermanentDelegate, TransferHook, MintCloseAuthority, DefaultAccountState, Pausable and for any freeze authority; and rejects NonTransferable and every other extension (https://github.com/orca-so/whirlpools/blob/main/programs/whirlpool/src/util/v2/token.rs, `is_supported_token_mint`).
- Authorities (fee, withdraw, hook, pointer, metadata, pause, delegate, close) outlive the launch. Put the ones you may still need on a multisig and revoke the rest; revoking is permanent.
- Test hooks and fee logic with LiteSVM or Mollusk ([testing.md](../../ext/solana-dev/skills/solana-dev/references/testing.md)). On a Surfpool fork, `surfnet_setTokenAccount` takes the token program as an optional last parameter, and `surfnet_timeTravel` with `absoluteEpoch` crosses the two-epoch fee delay ([cheatcodes.md](../../ext/solana-dev/skills/solana-dev/references/surfpool/cheatcodes.md)).
