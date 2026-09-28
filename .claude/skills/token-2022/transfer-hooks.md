# Transfer hooks (extensions 14, 15)

Writing a hook program and moving hooked mints from clients and programs. Official guides: [transfer-hook](https://solana.com/docs/tokens/extensions/transfer-hook), [transfer-hook-integration](https://solana.com/docs/tokens/extensions/transfer-hook-integration). Verified 2026-09-28 with Anchor 1.2.0, `spl-transfer-hook-interface` 2.1, `spl-tlv-account-resolution` 0.11, Kit `@solana-program/token-2022` 0.19 (`cargo build-sbf` plus LiteSVM runs).

## Execute contract

- Accounts: 0 source, 1 mint, 2 destination, 3 source authority (owner or delegate), 4 ExtraAccountMetaList PDA (seeds `["extra-account-metas", mint]` under the hook program), then the extras in list order. Seeds can reference these by index (`Seed::AccountKey { index }`), plus `Seed::AccountData` and `Seed::InstructionData` (the amount).
- Base accounts arrive read-only without signer privileges. State the hook writes lives in extra accounts marked writable.
- The hook runs after balances move and is skipped on self-transfers.
- Confidential transfers call the hook with `amount = u64::MAX` because the amount is encrypted. Amount limits or `checked_add(amount)` volume counters fail every confidential transfer; treat `u64::MAX` as "unknown".
- Token-2022 forwards the meta-list PDA only if the caller passed it. Initialize an ExtraAccountMetaList for every hooked mint, even an empty one: a passed but uninitialized PDA fails with `InvalidAccountData`, and the Rust offchain resolver errors when it is missing.

## Anchor 1.2 hook

```rust
use spl_discriminator::SplDiscriminate;
use spl_transfer_hook_interface::instruction::{ExecuteInstruction, InitializeExtraAccountMetaListInstruction};

// Anchor 1.0 removed #[interface]; match the interface discriminators directly.
#[instruction(discriminator = InitializeExtraAccountMetaListInstruction::SPL_DISCRIMINATOR_SLICE)]
pub fn initialize_extra_account_meta_list(ctx: Context<InitializeExtraAccountMetaList>) -> Result<()> {
    let metas = extra_metas()?; // fixed on-chain; Anchor ignores the metas vec clients append
    let mut data = ctx.accounts.extra_account_meta_list.try_borrow_mut_data()?;
    ExtraAccountMetaList::init::<ExecuteInstruction>(&mut data, &metas)?;
    Ok(())
}

#[instruction(discriminator = ExecuteInstruction::SPL_DISCRIMINATOR_SLICE)]
pub fn execute(ctx: Context<Execute>, amount: u64) -> Result<()> {
    // Only inside a real transfer: Token-2022 sets `transferring` for the duration of the CPI.
    let src = ctx.accounts.source.to_account_info();
    let data = src.try_borrow_data()?;
    let acct = StateWithExtensions::<T22Account>::unpack(&data)?;
    require!(bool::from(acct.get_extension::<TransferHookAccount>()?.transferring), HookError::NotTransferring);
    // ...also check the mint's TransferHook program_id == crate::ID
    Ok(())
}
```

```rust
#[derive(Accounts)]
pub struct Execute<'info> {
    #[account(token::mint = mint, token::token_program = TOKEN_2022_ID)]
    pub source: InterfaceAccount<'info, TokenAccount>,
    #[account(mint::token_program = TOKEN_2022_ID)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(token::mint = mint, token::token_program = TOKEN_2022_ID)]
    pub destination: InterfaceAccount<'info, TokenAccount>,
    /// CHECK: owner or delegate; can be a PDA or multisig
    pub owner: UncheckedAccount<'info>,
    /// CHECK: validated by seeds
    #[account(seeds = [b"extra-account-metas", mint.key().as_ref()], bump)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    // extras in list order
}
```

- Type the owner as `UncheckedAccount`. Anchor's own hook example uses `SystemAccount`, which rejects transfers from PDA- or multisig-owned accounts.
- Size the meta-list account with `ExtraAccountMetaList::size_of(metas.len())`.
- `Context<'info, T>` takes one lifetime in Anchor 1.x (`Context<'_, '_, 'info, 'info, T>` is E0107).
- Pinocchio (`pinocchio-token-2022` 0.4): import `StateWithExtensions` and the extension types from `pinocchio_token_2022::state` (the `extension` module is private). A `#![no_std]` program needs `program_entrypoint!`, `no_allocator!` (or `default_allocator!`) and `nostd_panic_handler!`.

## Moving a hooked mint

Clients (Kit), which resolve the extras for you:

```ts
import { getTransferCheckedWithTransferHookInstructionAsync } from "@solana-program/token-2022";

const ix = await getTransferCheckedWithTransferHookInstructionAsync(
  { rpc },
  {
    source,
    mint,
    destination,
    authority,
    amount,
    decimals,
  },
);
// resolveExtraAccountMetasForExecute({ rpc, transferHookProgramAddress, source, mint, destination, owner, amount })
// returns [extras..., hook program, meta-list PDA] if you build the instruction yourself.
// Create the list with getDefaultInitializeExtraAccountMetaListInstructionAsync.
```

A plain `getTransferCheckedInstruction` on a hooked mint fails with `MissingAccount`. web3.js 1.x: `createTransferCheckedWithTransferHookInstruction`. Simulate before sending: the hook can reject for its own reasons.

Programs: `anchor_spl::token_interface::transfer_checked` drops `remaining_accounts`, so it fails on hooked mints. Take the hook program, meta-list PDA and extras as `remaining_accounts` and use:

```rust
// Cargo.toml: spl-token-2022 = { version = "11.1", features = ["no-entrypoint"] }
spl_token_2022::onchain::invoke_transfer_checked(
    &ctx.accounts.token_program.key(),
    ctx.accounts.from.to_account_info(),
    ctx.accounts.mint.to_account_info(),
    ctx.accounts.to.to_account_info(),
    ctx.accounts.authority.to_account_info(),
    ctx.remaining_accounts,
    amount,
    ctx.accounts.mint.decimals,
    &[], // signer seeds for a PDA authority
)?;
```

`spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi` does the same when you build the `transfer_checked` instruction yourself.

## Security

- Check the `transferring` flag and that the mint's TransferHook points at your program; otherwise anyone can call Execute directly. More checks: [security.md, Token-2022 section](../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).
- The hook program and the meta-list update authority can change behavior after listing (sell blockers, fees). Integrators check `solana program show <hook>` for an upgrade authority; Meteora requires both revoked.
- Clients that cache resolved extras break when the issuer changes the hook program or the list (`UpdateExtraAccountMetaList`); resolve per transfer.
- Every transfer pays the hook's compute: a hooked `transfer_checked` through a small allowlist hook took about 20k CU in LiteSVM. Keep hooks small.
- Venues differ on hooks: approving a hooked mint is not the same as forwarding its accounts ([integrating-mints.md](integrating-mints.md)).
