use anchor_lang::{prelude::*, solana_program::program::invoke_signed};
use anchor_spl::token_interface::{Mint, Token2022, TokenAccount, TokenInterface};
use t22v3::extension::{
    permissioned_burn::{instruction as pb_ix, PermissionedBurnConfig},
    BaseStateWithExtensions, StateWithExtensions,
};

declare_id!("An9EQ68FhqXDL5bgp3h952Z2xYgH58UWHeJcc8FpUfDQ");

#[program]
pub mod pburn {
    use super::*;

    /// Standard Burn/BurnChecked on a PermissionedBurn mint fails; use the extension's own
    /// Burn/BurnChecked, co-signed by the permissioned burn authority.
    pub fn permissioned_burn(ctx: Context<PermissionedBurn>, amount: u64) -> Result<()> {
        let a = &ctx.accounts;
        {
            let mint_info = a.mint.to_account_info();
            let data = mint_info.try_borrow_data()?;
            let state = StateWithExtensions::<t22v3::state::Mint>::unpack(&data)?;
            let cfg = state.get_extension::<PermissionedBurnConfig>()?;
            // MaybeNull<Address>; Address == anchor Pubkey via the solana-address 1.1 -> 2.x re-export
            require_keys_eq!(
                cfg.authority.get().ok_or(PbError::NoAuthority)?,
                a.burn_authority.key(),
                PbError::WrongAuthority
            );
        }
        let ix = pb_ix::burn_checked(
            &a.token_program.key(),
            &a.token_account.key(),
            &a.mint.key(),
            &a.burn_authority.key(),
            &a.owner.key(),
            &[],
            amount,
            a.mint.decimals,
        )?; // ProgramError -> anchor Error: same solana-program-error 3.x, no mapping needed
        invoke_signed(
            &ix,
            &[
                a.token_account.to_account_info(),
                a.mint.to_account_info(),
                a.burn_authority.to_account_info(),
                a.owner.to_account_info(),
            ],
            &[],
        )?;
        Ok(())
    }

    /// Hook-aware transfer_checked. anchor_spl::token_interface::transfer_checked ignores
    /// ctx.remaining_accounts, so a hooked mint fails there. Pass [hook program,
    /// extra-account-metas PDA, ...extras] as remaining accounts.
    /// Anchor 1.x: Context has ONE lifetime (Context<'info, T>), not the 0.x four.
    pub fn transfer_hooked<'info>(
        ctx: Context<'info, TransferHooked<'info>>,
        amount: u64,
    ) -> Result<()> {
        let a = &ctx.accounts;
        let mut ix = anchor_spl::token_2022::spl_token_2022::instruction::transfer_checked(
            &a.token_program.key(),
            &a.from.key(),
            &a.mint.key(),
            &a.to.key(),
            &a.authority.key(),
            &[],
            amount,
            a.mint.decimals,
        )?;
        let mut infos = vec![
            a.from.to_account_info(),
            a.mint.to_account_info(),
            a.to.to_account_info(),
            a.authority.to_account_info(),
        ];
        let hook_program = {
            let mint_info = a.mint.to_account_info();
            let data = mint_info.try_borrow_data()?;
            anchor_spl::token_2022::spl_token_2022::extension::transfer_hook::get_program_id(
                &anchor_spl::token_2022::spl_token_2022::extension::StateWithExtensions::<
                    anchor_spl::token_2022::spl_token_2022::state::Mint,
                >::unpack(&data)?,
            )
        };
        if let Some(hook_program) = hook_program {
            spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi(
                &mut ix,
                &mut infos,
                &hook_program,
                a.from.to_account_info(),
                a.mint.to_account_info(),
                a.to.to_account_info(),
                a.authority.to_account_info(),
                amount,
                ctx.remaining_accounts,
            )?;
        }
        invoke_signed(&ix, &infos, &[])?;
        Ok(())
    }
}

#[derive(Accounts)]
pub struct PermissionedBurn<'info> {
    pub owner: Signer<'info>,
    pub burn_authority: Signer<'info>,
    #[account(mut, mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, token::mint = mint, token::authority = owner, token::token_program = token_program)]
    pub token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Program<'info, Token2022>,
}

#[derive(Accounts)]
pub struct TransferHooked<'info> {
    pub authority: Signer<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, token::mint = mint, token::authority = authority, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}

#[error_code]
pub enum PbError {
    #[msg("Mint has no permissioned burn authority")]
    NoAuthority,
    #[msg("Wrong permissioned burn authority")]
    WrongAuthority,
}

#[cfg(test)]
mod tests {
    use t22v3::extension::{BaseStateWithExtensionsMut, ExtensionType, StateWithExtensionsMut};

    /// A mint carrying PermissionedBurn, parsed by anchor-spl's interface 2.x.
    #[test]
    fn interface_v2_on_permissioned_burn_mint() {
        let len = ExtensionType::try_calculate_account_len::<t22v3::state::Mint>(&[
            ExtensionType::Pausable,
            ExtensionType::PermissionedBurn,
        ])
        .unwrap();
        let mut buf = vec![0u8; len];
        {
            let mut s =
                StateWithExtensionsMut::<t22v3::state::Mint>::unpack_uninitialized(&mut buf)
                    .unwrap();
            s.init_extension::<t22v3::extension::pausable::PausableConfig>(true)
                .unwrap();
            s.init_extension::<t22v3::extension::permissioned_burn::PermissionedBurnConfig>(true)
                .unwrap();
            s.base.decimals = 6;
            s.base.is_initialized = true;
            s.pack_base();
            s.init_account_type().unwrap();
        }
        use anchor_spl::token_2022::spl_token_2022 as v2;
        use v2::extension::BaseStateWithExtensions;
        let st = v2::extension::StateWithExtensions::<v2::state::Mint>::unpack(&buf)
            .expect("v2 unpack of base + TLV");
        // Targeted lookup of a known extension still works...
        assert!(st
            .get_extension::<v2::extension::pausable::PausableConfig>()
            .is_ok());
        // ...but enumerating hits the unknown type 28 and errors.
        let types = st.get_extension_types();
        println!("v2 get_extension_types on PermissionedBurn mint: {types:?}");
        assert!(types.is_err());
        // InterfaceAccount<Mint> deserialization (same unpack) succeeds.
        let mut slice: &[u8] = &buf;
        use anchor_lang::AccountDeserialize;
        assert!(anchor_spl::token_interface::Mint::try_deserialize_unchecked(&mut slice).is_ok());
    }
}
