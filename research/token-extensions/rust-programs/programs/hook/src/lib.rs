use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::{
        spl_token_2022::{
            extension::{
                transfer_hook::{TransferHook, TransferHookAccount},
                BaseStateWithExtensions, StateWithExtensions,
            },
            state::{Account as T22Account, Mint as T22Mint},
        },
        ID as TOKEN_2022_ID,
    },
    token_interface::{Mint, TokenAccount},
};
use spl_discriminator::SplDiscriminate;
use spl_tlv_account_resolution::{
    account::ExtraAccountMeta, seeds::Seed, state::ExtraAccountMetaList,
};
use spl_transfer_hook_interface::instruction::{
    ExecuteInstruction, InitializeExtraAccountMetaListInstruction,
};

declare_id!("4jz5UgWKXJW6w1jsGJ52KiiUurqigfUk8fTu9GcFrqEV");

#[program]
pub mod hook {
    use super::*;

    /// Data sent by Token-2022 clients: 8-byte discriminator + PodSlice<ExtraAccountMeta>.
    /// Anchor's arg decoder ignores trailing bytes, so taking no args is fine; the metas
    /// are fixed on-chain here instead of trusting caller input.
    #[instruction(discriminator = InitializeExtraAccountMetaListInstruction::SPL_DISCRIMINATOR_SLICE)]
    pub fn initialize_extra_account_meta_list(
        ctx: Context<InitializeExtraAccountMetaList>,
    ) -> Result<()> {
        let metas = extra_metas()?;
        let mut data = ctx.accounts.extra_account_meta_list.try_borrow_mut_data()?;
        ExtraAccountMetaList::init::<ExecuteInstruction>(&mut data, &metas)?;
        Ok(())
    }

    #[instruction(discriminator = ExecuteInstruction::SPL_DISCRIMINATOR_SLICE)]
    pub fn execute(ctx: Context<Execute>, amount: u64) -> Result<()> {
        // 1. Only inside a real Token-2022 transfer: the flag is set on source+dest for
        //    the duration of the hook CPI. Without this anyone can call Execute directly.
        {
            let src = ctx.accounts.source.to_account_info();
            let data = src.try_borrow_data()?;
            let acct = StateWithExtensions::<T22Account>::unpack(&data)?;
            let ext = acct.get_extension::<TransferHookAccount>()?;
            require!(bool::from(ext.transferring), HookError::NotTransferring);
        }
        // 2. The mint must point its TransferHook at this program.
        {
            let mint = ctx.accounts.mint.to_account_info();
            let data = mint.try_borrow_data()?;
            let m = StateWithExtensions::<T22Mint>::unpack(&data)?;
            let hook = m.get_extension::<TransferHook>()?;
            require!(
                Option::<Pubkey>::from(hook.program_id) == Some(crate::ID),
                HookError::WrongMint
            );
        }
        let c = &mut ctx.accounts.counter;
        c.transfers = c.transfers.checked_add(1).ok_or(HookError::Overflow)?;
        c.volume = c.volume.checked_add(amount).ok_or(HookError::Overflow)?;
        Ok(())
    }

    pub fn init_counter(ctx: Context<InitCounter>) -> Result<()> {
        ctx.accounts.counter.bump = ctx.bumps.counter;
        Ok(())
    }
}

/// Extra account #5 (after source, mint, dest, owner, meta-list): counter PDA [b"counter", mint].
fn extra_metas() -> Result<Vec<ExtraAccountMeta>> {
    Ok(vec![ExtraAccountMeta::new_with_seeds(
        &[
            Seed::Literal {
                bytes: b"counter".to_vec(),
            },
            Seed::AccountKey { index: 1 },
        ],
        false, // is_signer
        true,  // is_writable
    )?])
}

#[derive(Accounts)]
pub struct InitializeExtraAccountMetaList<'info> {
    /// CHECK: TLV buffer; address fixed by seeds the interface mandates.
    #[account(
        init,
        payer = payer,
        space = ExtraAccountMetaList::size_of(extra_metas()?.len())?,
        seeds = [b"extra-account-metas", mint.key().as_ref()],
        bump,
    )]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    #[account(mint::token_program = TOKEN_2022_ID)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

// Account order is fixed by the interface: source, mint, destination, owner, meta list, extras.
#[derive(Accounts)]
pub struct Execute<'info> {
    #[account(token::mint = mint, token::token_program = TOKEN_2022_ID)]
    pub source: InterfaceAccount<'info, TokenAccount>,
    #[account(mint::token_program = TOKEN_2022_ID)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(token::mint = mint, token::token_program = TOKEN_2022_ID)]
    pub destination: InterfaceAccount<'info, TokenAccount>,
    /// CHECK: owner or delegate; may be a PDA or multisig, so not SystemAccount.
    pub owner: UncheckedAccount<'info>,
    /// CHECK: validated by seeds.
    #[account(seeds = [b"extra-account-metas", mint.key().as_ref()], bump)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"counter", mint.key().as_ref()], bump = counter.bump)]
    pub counter: Account<'info, Counter>,
}

#[derive(Accounts)]
pub struct InitCounter<'info> {
    #[account(
        init,
        payer = payer,
        space = Counter::DISCRIMINATOR.len() + Counter::INIT_SPACE,
        seeds = [b"counter", mint.key().as_ref()],
        bump,
    )]
    pub counter: Account<'info, Counter>,
    #[account(mint::token_program = TOKEN_2022_ID)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[account]
#[derive(InitSpace)]
pub struct Counter {
    pub transfers: u64,
    pub volume: u64,
    pub bump: u8,
}

#[error_code]
pub enum HookError {
    #[msg("Execute called outside a Token-2022 transfer")]
    NotTransferring,
    #[msg("Mint's transfer hook does not point at this program")]
    WrongMint,
    #[msg("Overflow")]
    Overflow,
}
