# Transfer hooks (extensions 14, 15)

Writing a hook program and moving hooked mints from clients and programs. Official guides: [transfer-hook](https://solana.com/docs/tokens/extensions/transfer-hook), [transfer-hook-integration](https://solana.com/docs/tokens/extensions/transfer-hook-integration). Verified 2026-09-28 with Anchor 1.2.0, `spl-transfer-hook-interface` 2.1, `spl-tlv-account-resolution` 0.11, pinocchio 0.11 / `pinocchio-token-2022` 0.4 and Kit `@solana-program/token-2022` 0.19 (`cargo build-sbf` plus LiteSVM runs).

## Execute contract

- Accounts: 0 source, 1 mint, 2 destination, 3 source authority (owner or delegate), 4 ExtraAccountMetaList PDA (seeds `["extra-account-metas", mint]` under the hook program), then the extras in list order. Seeds can reference these by index (`Seed::AccountKey { index }`), plus `Seed::AccountData` and `Seed::InstructionData` (the amount).
- Base accounts arrive read-only without signer privileges; a PDA authority arrives as a non-signer too. State the hook writes lives in extra accounts marked writable.
- The hook runs after balances move and is skipped on self-transfers.
- `amount` is the gross amount sent. On a transfer-fee mint the destination got `amount` minus the fee, so net it with the epoch fee if a limit or counter should track what arrived.
- Confidential transfers call the hook with `amount = u64::MAX` because the amount is encrypted. Amount limits or `checked_add(amount)` volume counters fail every confidential transfer; treat `u64::MAX` as "unknown".
- Token-2022 forwards the meta-list PDA only if the caller passed it. Initialize an ExtraAccountMetaList for every hooked mint, even an empty one: a passed but uninitialized PDA fails with `InvalidAccountData`, and a hook called without it fails for lack of accounts.
- The hook can't call back into the program that started the transfer: A → Token-2022 → hook → A fails with "Cross-program invocation reentrancy not allowed". Only direct self-recursion is allowed.

## Anchor 1.2 hook

```rust
use anchor_spl::token_2022::spl_token_2022::{
    extension::{transfer_hook::{TransferHook, TransferHookAccount}, BaseStateWithExtensions, StateWithExtensions},
    state::{Account as T22Account, Mint as T22Mint},
};
use spl_discriminator::SplDiscriminate;
use spl_tlv_account_resolution::state::ExtraAccountMetaList;
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
- Updating the list: a handler with `#[instruction(discriminator = UpdateExtraAccountMetaListInstruction::SPL_DISCRIMINATOR_SLICE)]` calls `ExtraAccountMetaList::update::<ExecuteInstruction>(&mut data, &metas)`. It rewrites the list inside the existing data, so first resize the account to `size_of(new_len)` and top up its rent, and require the mint's hook authority.
- `Context<'info, T>` takes one lifetime in Anchor 1.x (`Context<'_, '_, 'info, 'info, T>` is E0107).

## Pinocchio hook

- Use `pinocchio-token-2022` 0.4: 0.3 has no extension state, so it can't read `TransferHookAccount.transferring`. Import `StateWithExtensions` and the extension types from `pinocchio_token_2022::state` (the `extension` module is private).
- Dispatch on the interface discriminators: Execute `[105, 37, 101, 197, 75, 251, 102, 26]` (then a u64 amount), InitializeExtraAccountMetaList `[43, 34, 13, 49, 167, 88, 235, 235]`.
- The meta list can be written without `spl-tlv-account-resolution`: a fixed byte array of `[execute discriminator (8)][u32 length][u32 count][35 bytes per meta]`, 16 + 35·n bytes. Compare it once against `ExtraAccountMetaList::init` output in a host test.
- A `#![no_std]` program needs `program_entrypoint!`, `no_allocator!` (or `default_allocator!`) and `nostd_panic_handler!`. `pinocchio::cpi` needs pinocchio's `cpi` feature.
- Gate meta-list init on the mint's TransferHook authority. Only that authority should initialize or update the list.
- Anyone can send lamports to the meta-list PDA before you create it, which makes a plain `create_account` fail. Top up the rent deficit, then `allocate` and `assign`. The interface marks the authority as signer only, so pass it writable too if it pays the rent.
- Host `cargo test` runs that call `Address::find_program_address` need `solana-address`'s `curve25519` feature (add it under `cfg(not(target_os = "solana"))`).

## Moving a hooked mint

Clients (Kit):
- `getTransferCheckedWithTransferHookInstructionAsync({ rpc }, { source, mint, destination, authority, amount, decimals })` resolves the extras. The `token2022Program()` client plugin has the same as `transferCheckedWithTransferHook`.
- The convenience helpers `getTransferToATAInstructionPlan(Async)` and the plugin's `transferToATA` send a plain `transferChecked`, so they fail on hooked mints with `MissingAccount`. For a new recipient, put `getCreateAssociatedTokenIdempotentInstructionAsync` and the hooked transfer in one transaction.
- Fee plus hook: the hooked helper works as is (the program computes the fee). To pin the fee the UI showed, use `getTransferCheckedWithFeeInstruction({ ..., fee })` and append `resolveExtraAccountMetasForExecute(...)` to its accounts; a changed fee then fails with `FeeMismatch` (32). The destination account must exist.
- `resolveExtraAccountMetasForExecute({ rpc, transferHookProgramAddress, source, mint, destination, owner, amount })` returns `[extras..., hook program, meta-list PDA]`. Create the list with `getDefaultInitializeExtraAccountMetaListInstructionAsync`.
- web3.js 1.x: `createTransferCheckedWithTransferHookInstruction`. Simulate before sending: the hook can reject for its own reasons.

Anchor programs: `anchor_spl::token_interface::transfer_checked` drops `remaining_accounts`, so it fails on hooked mints. Take the hook program, meta-list PDA and extras as `remaining_accounts` and use:

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

Pinocchio programs: `pinocchio_token_2022::instructions::TransferChecked` has a fixed account list with no room for extras. Build the instruction by hand; with `token_program` as the first account, `accounts[1..]` is already `[from, mint, to, authority, ...remaining]`:

```rust
let mut metas = [const { MaybeUninit::<InstructionAccount>::uninit() }; MAX]; // check cpi.len() <= MAX first
metas[0].write(InstructionAccount::writable(from.address()));
metas[1].write(InstructionAccount::readonly(mint.address()));
metas[2].write(InstructionAccount::writable(to.address()));
metas[3].write(InstructionAccount::readonly_signer(authority.address()));
for (m, a) in metas[4..].iter_mut().zip(remaining) {
    m.write(InstructionAccount::new(a.address(), a.is_writable(), false)); // keep writable flags, never forward signer
}
let mut data = [0u8; 10];
data[0] = 12; // TransferChecked
data[1..9].copy_from_slice(&amount.to_le_bytes());
data[9] = decimals;
let ix = InstructionView {
    program_id: token_program.address(),
    // SAFETY: metas[..cpi.len()] were all written above
    accounts: unsafe { core::slice::from_raw_parts(metas.as_ptr() as *const InstructionAccount, cpi.len()) },
    data: &data,
};
invoke_signed_with_bounds::<MAX, _>(&ix, cpi, signers)?;
```

Token-2022 finds the hook program and meta list by address, so their order among the extras doesn't matter. Passing a writable extra as read-only fails with `PrivilegeEscalation`. This path adds about 1.6k CU over a direct client transfer, against 16–28k for the Anchor `invoke_transfer_checked` path, which resolves the extras a second time.

## Security

security.md's [transfer hook section](../ext/solana-dev/skills/solana-dev/references/security.md#transfer-hook-security-surface) covers the `transferring` flag, the mint check and account ownership. Also check that the meta-list PDA matches its seeds and every extra matches what the list derives, and handle `u64::MAX`.

For integrators:
- The hook program and the meta-list update authority can change behavior after listing (sell blockers, fees). Check `solana program show <hook>` for an upgrade authority and who can update the list.
- Clients that cache resolved extras break when the issuer changes the hook program or the list (`UpdateExtraAccountMetaList`); resolve per transfer.
- Every transfer pays the hook's compute: a hooked `transfer_checked` through a small allowlist hook took about 20k CU in LiteSVM. Keep hooks small.
- Venues differ on hooks: approving a hooked mint is not the same as forwarding its accounts ([integrating-mints.md](integrating-mints.md)).
