# Transfer hooks: TransferHook, TransferHookAccount

The mint names a hook program. Every `TransferChecked` or `TransferCheckedWithFee` moves the balances, then CPIs the hook's `Execute` instruction; if the hook fails, the whole transfer fails.

- **Lives on:** the mint (TransferHook: authority and program id). Every token account of the mint gets TransferHookAccount, whose `transferring` flag is true only while the hook runs.
- **Authority:** the hook authority changes or clears the program id (`UpdateTransferHook`; None disables the hook). Rotate the authority with SetAuthority type `TransferHookProgramId` (CLI `spl-token authorize <MINT> transfer-hook-program-id <NEW>`). Despite the name, that rotates the authority, not the program id.

## When the hook runs

- On `TransferChecked`, `TransferCheckedWithFee` and confidential transfers. A confidential transfer calls it with `amount = u64::MAX`, because the real amount is encrypted. Mint, burn and confidential deposit or withdraw never call it.
- Skipped when the mint has no program id, and for a `TransferChecked` or `TransferCheckedWithFee` to the same account; a confidential transfer to the same account still calls it. Zero-amount transfers call it too.
- Plain `Transfer` fails with `MintRequiredForTransfer`.
- Execute accounts: 0 source, 1 mint, 2 destination, 3 source owner or delegate, 4 the ExtraAccountMetaList PDA, then the extra accounts in list order. All of them arrive read-only and without signer privileges, even the one that signed the transfer, so anything the hook writes must be an extra account marked writable in its list.
- If the transaction doesn't carry the ExtraAccountMetaList PDA, Token-2022 still calls the hook, with only the four base accounts. Whether that fails is up to the hook.

## ExtraAccountMetaList

- A PDA of the hook program with seeds `["extra-account-metas", mint]`: Rust `get_extra_account_metas_address(&mint, &hook_program_id)`, Kit `findExtraAccountMetaListPda({ mint }, { programAddress: hookProgram })`.
- Entries (spl-tlv-account-resolution 0.11): `ExtraAccountMeta::new_with_pubkey` (fixed address), `new_with_seeds` (PDA of the hook program), `new_external_pda_with_seeds(program_index, ...)` (PDA of another program in the list), `new_with_pubkey_data` (address read from account or instruction data).
- Seeds: `Seed::Literal { bytes }`, `Seed::AccountKey { index }`, `Seed::AccountData { account_index, data_index, length }`, `Seed::InstructionData { index, length }`; the amount is `index: 8, length: 8`. Account indexes follow the Execute order above, then earlier extras. Packed seeds must fit in 32 bytes.
- Allocate `ExtraAccountMetaList::size_of(n)` and write it with `ExtraAccountMetaList::init::<ExecuteInstruction>(data, &metas)`. It must exist before the first transfer. The interface's own InitializeExtraAccountMetaList takes `[meta list (writable), mint, mint authority (signer), system program]`; whichever instruction writes the list, the hook program decides who may call it, so check the mint authority.
- Changing the list later (`UpdateExtraAccountMetaList`) breaks clients and programs that pass the old accounts.

## Write the hook (Anchor 1.2.0)

Anchor 1.x has no `#[interface]` attribute. Set the handler's discriminator to the interface's Execute discriminator instead. anchor-spl doesn't bring the interface crates: add `spl-transfer-hook-interface` 2.1, `spl-tlv-account-resolution` 0.11 and `spl-discriminator` 0.5. They use the same Solana 3.x crates as anchor-lang 1.2, so `?` converts their errors.

```rust
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    spl_token_2022::extension::{transfer_hook::TransferHookAccount, BaseStateWithExtensions, StateWithExtensions},
    spl_token_2022::state::Account as TokenAccountState,
    Mint, TokenAccount,
};
use spl_discriminator::SplDiscriminate;
use spl_tlv_account_resolution::{account::ExtraAccountMeta, seeds::Seed, state::ExtraAccountMetaList};
use spl_transfer_hook_interface::instruction::ExecuteInstruction;

#[program]
pub mod allowlist_hook {
    use super::*;

    pub fn initialize_extra_account_meta_list(ctx: Context<InitializeExtraAccountMetaList>) -> Result<()> {
        let metas = [ExtraAccountMeta::new_with_seeds(
            &[Seed::Literal { bytes: b"allow".to_vec() }, Seed::AccountKey { index: 3 }],
            false, // is_signer
            false, // is_writable
        )?];
        ExtraAccountMetaList::init::<ExecuteInstruction>(
            &mut ctx.accounts.extra_account_meta_list.try_borrow_mut_data()?,
            &metas,
        )?;
        Ok(())
    }

    #[instruction(discriminator = ExecuteInstruction::SPL_DISCRIMINATOR_SLICE)]
    pub fn transfer_hook(ctx: Context<TransferHook>, _amount: u64) -> Result<()> {
        // The flag is set only while Token-2022 is mid-transfer, so direct calls fail here
        let info = ctx.accounts.source.to_account_info();
        let data = info.try_borrow_data()?;
        let source = StateWithExtensions::<TokenAccountState>::unpack(&data)?;
        let flag = source.get_extension::<TransferHookAccount>()?;
        require!(bool::from(flag.transferring), HookError::NotTransferring);
        require!(ctx.accounts.allow_entry.data_len() > 0, HookError::NotAllowed);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct InitializeExtraAccountMetaList<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mint::authority = mint_authority)]
    pub mint: InterfaceAccount<'info, Mint>,
    pub mint_authority: Signer<'info>,
    /// CHECK: the ExtraAccountMetaList PDA, written above
    #[account(init, payer = payer, space = ExtraAccountMetaList::size_of(1)?,
        seeds = [b"extra-account-metas", mint.key().as_ref()], bump)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

// Field order is fixed by Execute: source, mint, destination, owner, meta list, extras
#[derive(Accounts)]
pub struct TransferHook<'info> {
    #[account(token::mint = mint)]
    pub source: InterfaceAccount<'info, TokenAccount>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(token::mint = mint)]
    pub destination: InterfaceAccount<'info, TokenAccount>,
    /// CHECK: source owner or delegate, passed without signer privileges
    pub owner: UncheckedAccount<'info>,
    /// CHECK: checked by its seeds
    #[account(seeds = [b"extra-account-metas", mint.key().as_ref()], bump)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    /// CHECK: this program's allowlist PDA for the transfer authority; empty means not allowed
    #[account(seeds = [b"allow", owner.key().as_ref()], bump)]
    pub allow_entry: UncheckedAccount<'info>,
}

#[error_code]
pub enum HookError {
    #[msg("Hook called outside a Token-2022 transfer")]
    NotTransferring,
    #[msg("Transfer authority is not on the allowlist")]
    NotAllowed,
}
```

Account 3 is whoever signed the transfer (owner, delegate or permanent delegate), so this allowlist checks that signer. If the hook also has to accept confidential transfers, handle `amount == u64::MAX`.

## Create the mint

- CLI: `spl-token --program-2022 create-token --transfer-hook <HOOK_PROGRAM_ID>` (the mint authority becomes the hook authority), or `--enable-transfer-hook` to add the extension with no program yet. Later: `spl-token set-transfer-hook <MINT> <NEW_PROGRAM_ID>`, or `--disable`.
- Kit: `extension('TransferHook', { authority, programId })`; later `getUpdateTransferHookInstruction({ mint, authority, programId })`.
- Anchor 1.2.0: `extensions::transfer_hook::authority = ...` and `extensions::transfer_hook::program_id = ...` on `init`; otherwise `transfer_hook_initialize(ctx, authority, program_id)` (both `Option<Pubkey>`) and `transfer_hook_update(ctx, program_id)`.
- Creating the mint with a hook authority but no program keeps the option of adding a hook later without a new mint.

## Send a transfer

- Kit: `getTransferCheckedWithTransferHookInstructionAsync(client, { source, mint, destination, authority, amount, decimals })` reads the mint and appends the extras, the hook program and the meta list PDA; for a mint without a hook it returns a plain `transferChecked`. The plugin exposes it as `client.token2022.instructions.transferCheckedWithTransferHook(...)`. The plugin's `transferToATA` does not add hook accounts.
- web3.js 1.x: `createTransferCheckedWithTransferHookInstruction(connection, source, mint, destination, owner, amount, decimals, multiSigners, commitment, TOKEN_2022_PROGRAM_ID)`. Its program id defaults to the classic Token program, so pass the Token-2022 id.
- Rust clients: `offchain::create_transfer_checked_instruction_with_extra_metas` from the full `spl-token-2022` crate (anchor-spl's interface re-export has no `offchain` module), or `spl_transfer_hook_interface::offchain::add_extra_account_metas_for_execute`.
- CLI: `spl-token transfer` resolves the extra accounts when online; `--transfer-hook-account <PUBKEY>:<ROLE>` adds one by hand (roles `readonly`, `writable`, `readonly-signer`, `writable-signer`).

## CPI a transfer of a hook mint

`anchor_spl::token_interface::transfer_checked` builds the instruction from the four base accounts only and ignores `remaining_accounts`, so it can't move a hook mint. Build the instruction yourself and add the hook's accounts, which the caller passes as remaining accounts (hook program, meta list PDA, extras):

```rust
use anchor_lang::solana_program::program::invoke_signed;
use anchor_spl::token_interface::{get_mint_extension_data, spl_token_2022::{self, extension::transfer_hook::TransferHook}};
use spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi;

pub fn send<'info>(ctx: Context<'info, Send<'info>>, amount: u64) -> Result<()> {
    let a = &ctx.accounts;
    let mint_info = a.mint.to_account_info();
    let mut ix = spl_token_2022::instruction::transfer_checked(
        &a.token_program.key(), &a.from.key(), &a.mint.key(), &a.to.key(),
        &a.authority.key(), &[], amount, a.mint.decimals,
    )?;
    let mut infos = vec![a.from.to_account_info(), mint_info.clone(), a.to.to_account_info(), a.authority.to_account_info()];
    if let Ok(hook) = get_mint_extension_data::<TransferHook>(&mint_info) {
        if let Some(hook_program_id) = Option::<Pubkey>::from(hook.program_id) {
            add_extra_accounts_for_execute_cpi(
                &mut ix, &mut infos, &hook_program_id,
                a.from.to_account_info(), mint_info.clone(), a.to.to_account_info(), a.authority.to_account_info(),
                amount, ctx.remaining_accounts,
            )?;
        }
    }
    invoke_signed(&ix, &infos, &[]) // add signer seeds when a PDA is the authority
        .map_err(Into::into)
}
```

- Name the `'info` lifetime on `Context` as above; with the elided form, borrowing `ctx.remaining_accounts` next to the account infos doesn't compile.
- `add_extra_accounts_for_execute_cpi` fails with `IncorrectAccount` if the hook program isn't among the remaining accounts.
- With the full `spl-token-2022` crate (feature `no-entrypoint`), `spl_token_2022::onchain::invoke_transfer_checked` does the same in one call.
