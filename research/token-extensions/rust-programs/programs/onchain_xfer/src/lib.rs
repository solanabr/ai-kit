use anchor_lang::prelude::*;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

declare_id!("AahxDfqU1SxCh4qqFqxafysRs57Z3xZ8Zp9W9JFvcjo");

#[program]
pub mod onchain_xfer {
    use super::*;

    /// Program crate helper: resolves hook extra accounts from remaining_accounts and CPIs.
    /// remaining_accounts: [hook program, extra-account-metas PDA, ...extras]
    pub fn xfer<'info>(ctx: Context<'info, Xfer<'info>>, amount: u64) -> Result<()> {
        let a = &ctx.accounts;
        spl_token_2022::onchain::invoke_transfer_checked(
            &a.token_program.key(),
            a.from.to_account_info(),
            a.mint.to_account_info(),
            a.to.to_account_info(),
            a.authority.to_account_info(),
            ctx.remaining_accounts,
            amount,
            a.mint.decimals,
            &[],
        )?;
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Xfer<'info> {
    pub authority: Signer<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}
