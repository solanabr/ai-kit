#![no_std]
use pinocchio::{error::ProgramError, AccountView, Address, ProgramResult};
use pinocchio_token_2022::{
    instructions::TransferChecked,
    // `state::extension` is a private module; everything is flattened into `state`.
    state::{
        is_extension_not_found_error, Account, Mint, PausableExtension, StateWithExtensions,
        TransferHookAccountExtension, TransferHookExtension,
    },
};

// With #![no_std], `entrypoint!` fails on SBF ("#[panic_handler] function required"):
// it installs default_panic_handler (std-style custom_panic hook). Compose the pieces instead.
#[cfg(not(feature = "no-entrypoint"))]
mod entry {
    pinocchio::program_entrypoint!(crate::process_instruction);
    pinocchio::no_allocator!();
    pinocchio::nostd_panic_handler!();
}

/// sha256("spl-transfer-hook-interface:execute")[..8]
pub const EXECUTE_DISC: [u8; 8] = [105, 37, 101, 197, 75, 251, 102, 26];
pub const DEPOSIT_DISC: u8 = 0;

pub fn process_instruction(
    program_id: &Address,
    accounts: &mut [AccountView],
    data: &[u8],
) -> ProgramResult {
    if data.len() >= 16 && data[..8] == EXECUTE_DISC {
        let amount = u64::from_le_bytes(data[8..16].try_into().unwrap());
        return execute(program_id, accounts, amount);
    }
    match data.split_first() {
        Some((&DEPOSIT_DISC, rest)) if rest.len() == 8 => {
            deposit(accounts, u64::from_le_bytes(rest.try_into().unwrap()))
        }
        _ => Err(ProgramError::InvalidInstructionData),
    }
}

/// Accounts: source, mint, destination, owner, [extra-account-metas PDA, ...extras]
fn execute(program_id: &Address, accounts: &[AccountView], _amount: u64) -> ProgramResult {
    // Token-2022 forwards the meta-list PDA (5th) only if the caller passed it; require 4.
    let [source, mint, destination, _owner, ..] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };
    // from_account_view checks owner == Token-2022, so a spoofed account fails here.
    for acct in [source, destination] {
        let state = StateWithExtensions::<Account>::from_account_view(acct)?;
        if state.base.mint() != mint.address() {
            return Err(ProgramError::InvalidAccountData);
        }
        let ext = state.get_extension::<TransferHookAccountExtension>()?;
        if !bool::from(ext.transferring) {
            return Err(ProgramError::InvalidAccountData);
        }
    }
    let m = StateWithExtensions::<Mint>::from_account_view(mint)?;
    let hook = m.get_extension::<TransferHookExtension>()?;
    if hook.program_id.as_ref() != Some(program_id) {
        return Err(ProgramError::IncorrectProgramId);
    }
    Ok(())
}

/// Accounts: from, mint, to, authority(signer), token-2022 program
fn deposit(accounts: &[AccountView], amount: u64) -> ProgramResult {
    let [from, mint, to, authority, token_program, ..] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };
    let decimals = {
        let m = StateWithExtensions::<Mint>::from_account_view(mint)?;
        // Pinocchio's TransferChecked forwards exactly 4 accounts: a hooked mint would
        // fail inside Token-2022 for missing extra accounts, so reject it up front.
        match m.get_extension::<TransferHookExtension>() {
            Ok(h) if h.program_id.as_ref().is_some() => return Err(ProgramError::InvalidArgument),
            Ok(_) => {}
            Err(e) if is_extension_not_found_error(&e) => {}
            Err(e) => return Err(e),
        }
        if let Ok(p) = m.get_extension::<PausableExtension>() {
            if bool::from(p.paused) {
                return Err(ProgramError::InvalidArgument);
            }
        }
        m.base.decimals()
    };
    let before = StateWithExtensions::<Account>::from_account_view(to)?
        .base
        .amount();
    TransferChecked::new(from, mint, to, authority, amount, decimals)
        .invoke_with_program(token_program.address())?; // verifies it is Token-2022
    let after = StateWithExtensions::<Account>::from_account_view(to)?
        .base
        .amount();
    let _received = after
        .checked_sub(before)
        .ok_or(ProgramError::ArithmeticOverflow)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use spl_discriminator::SplDiscriminate;
    #[test]
    fn execute_disc_matches_interface() {
        assert_eq!(
            super::EXECUTE_DISC,
            spl_transfer_hook_interface::instruction::ExecuteInstruction::SPL_DISCRIMINATOR_SLICE
        );
    }
}
