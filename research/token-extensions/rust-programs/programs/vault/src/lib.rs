use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_2022::spl_token_2022::{
        extension::{
            pausable::PausableConfig, permanent_delegate::PermanentDelegate,
            transfer_hook::TransferHook, BaseStateWithExtensions, StateWithExtensions,
        },
        state::Mint as MintState,
    },
    token_interface::{
        transfer_checked, Mint, Token2022, TokenAccount, TokenInterface, TransferChecked,
    },
};

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod vault {
    use super::*;

    pub fn deposit(ctx: Context<Deposit>, amount: u64) -> Result<()> {
        check_mint_extensions(&ctx.accounts.mint.to_account_info())?;

        let before = ctx.accounts.vault_ata.amount;
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.key(),
                TransferChecked {
                    from: ctx.accounts.user_ata.to_account_info(),
                    mint: ctx.accounts.mint.to_account_info(),
                    to: ctx.accounts.vault_ata.to_account_info(),
                    authority: ctx.accounts.user.to_account_info(),
                },
            ),
            amount,
            ctx.accounts.mint.decimals,
        )?;
        // TransferFee withholds on the destination; credit what actually arrived.
        ctx.accounts.vault_ata.reload()?;
        let received = ctx
            .accounts
            .vault_ata
            .amount
            .checked_sub(before)
            .ok_or(VaultError::Overflow)?;

        let pos = &mut ctx.accounts.position;
        pos.owner = ctx.accounts.user.key();
        pos.mint = ctx.accounts.mint.key();
        pos.bump = ctx.bumps.position;
        pos.amount = pos
            .amount
            .checked_add(received)
            .ok_or(VaultError::Overflow)?;
        Ok(())
    }

    pub fn create_mint(_ctx: Context<CreateMint>) -> Result<()> {
        Ok(())
    }
}

/// Targeted lookups (get_extension::<T>) instead of get_extension_types():
/// anchor-spl 1.2.0 links spl-token-2022-interface 2.x, which does not know
/// PermissionedBurn (type 28) and fails get_extension_types() on such mints.
fn check_mint_extensions(mint: &AccountInfo) -> Result<()> {
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<MintState>::unpack(&data)?; // works for legacy SPL mints too
    if let Ok(pd) = state.get_extension::<PermanentDelegate>() {
        require!(
            Option::<Pubkey>::from(pd.delegate).is_none(),
            VaultError::PermanentDelegate
        );
    }
    if let Ok(hook) = state.get_extension::<TransferHook>() {
        require!(
            Option::<Pubkey>::from(hook.program_id).is_none(),
            VaultError::TransferHook
        );
    }
    if let Ok(p) = state.get_extension::<PausableConfig>() {
        require!(!bool::from(p.paused), VaultError::Paused);
    }
    Ok(())
}

#[derive(Accounts)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        mut,
        token::mint = mint,
        token::authority = user,
        token::token_program = token_program,
    )]
    pub user_ata: InterfaceAccount<'info, TokenAccount>,
    /// CHECK: PDA that owns the vault ATA; never read.
    #[account(seeds = [b"vault", mint.key().as_ref()], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = user,
        associated_token::mint = mint,
        associated_token::authority = vault_authority,
        associated_token::token_program = token_program,
    )]
    pub vault_ata: InterfaceAccount<'info, TokenAccount>,
    #[account(
        init_if_needed,
        payer = user,
        space = Position::DISCRIMINATOR.len() + Position::INIT_SPACE,
        seeds = [b"pos", mint.key().as_ref(), user.key().as_ref()],
        bump,
    )]
    pub position: Account<'info, Position>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CreateMint<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    pub authority: Signer<'info>,
    #[account(
        init,
        signer,
        payer = payer,
        mint::token_program = token_program,
        mint::decimals = 6,
        mint::authority = authority,
        mint::freeze_authority = authority,
        extensions::metadata_pointer::authority = authority,
        extensions::metadata_pointer::metadata_address = mint,
        extensions::transfer_hook::authority = authority,
        extensions::transfer_hook::program_id = crate::ID,
        extensions::pausable::authority = authority,
    )]
    pub mint: InterfaceAccount<'info, Mint>,
    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

#[account]
#[derive(InitSpace)]
pub struct Position {
    pub owner: Pubkey,
    pub mint: Pubkey,
    pub amount: u64,
    pub bump: u8,
}

#[error_code]
pub enum VaultError {
    #[msg("Mint has a permanent delegate")]
    PermanentDelegate,
    #[msg("Mint has a transfer hook")]
    TransferHook,
    #[msg("Mint is paused")]
    Paused,
    #[msg("Arithmetic overflow")]
    Overflow,
}
