# Token-account extensions and sizing

ImmutableOwner, MemoTransfer and CpiGuard live on token accounts and protect the holder. The other account extensions (TransferFeeAmount, TransferHookAccount, NonTransferableAccount, PausableAccount) come from the mint, and the program initializes them itself when the account is created, provided the account has room.

## Sizing a token account

- Required account extensions per mint extension: TransferFeeConfig → TransferFeeAmount; TransferHook → TransferHookAccount; NonTransferable → NonTransferableAccount and ImmutableOwner; Pausable → PausableAccount. Confidential accounts opt in later.
- `InitializeAccount` fails with `InvalidAccountData` if the account is too small for those.
- Associated token accounts: the associated token account program sizes them and adds ImmutableOwner, so Token-2022 associated token accounts always have it. Kit `getCreateAssociatedTokenIdempotentInstructionAsync({ payer, owner, mint, tokenProgram })`; `tokenProgram` defaults to Token-2022 there, while web3.js 1.x helpers default to the classic Token program.
- Anchor 1.2.0: `init` with `associated_token::` constraints goes through that program. `init` with `token::` constraints allocates exactly the mint's required extensions, which leaves no room for MemoTransfer or CpiGuard and no ImmutableOwner unless the mint is NonTransferable.
- Manual accounts: Rust `ExtensionType::try_calculate_account_len::<Account>(&types)`, or in interface 3.x `extension::account_len::try_calculate_account_len_from_mint_data(&mint_data, &extra_types)`. Kit `getTokenSize(extensions)` counts only the extensions you pass, so include the mint's required ones (for example `extension('TransferFeeAmount', { withheldAmount: 0n })`). Kit's `getCreateTokenInstructionPlan` never sends `InitializeImmutableOwner`, even when you list it. web3.js 1.x `getAccountLenForMint` misses ImmutableOwner for NonTransferable mints.
- The on-chain `GetAccountDataSize` instruction returns the size for the mint's required extensions plus the ones you list (Rust builder `get_account_data_size(program, mint, &types)`, Anchor `anchor_spl::token_2022::get_account_data_size`); Kit's builder takes no extension list.

## ImmutableOwner

- The account's owner can never change: SetAuthority `AccountOwner` fails with `ImmutableOwner`.
- On a manual account, `InitializeImmutableOwner` has to run before `InitializeAccount`; afterwards it fails with `AlreadyInUse`, so it can't be added later.
- CLI: `spl-token create-account <MINT> <ACCOUNT_KEYPAIR> --immutable` (without a keypair it creates the associated token account, which already has it). Kit: `getInitializeImmutableOwnerInstruction({ account })`. Anchor: `immutable_owner_initialize(ctx)`.

## MemoTransfer (required memos)

- When enabled, every incoming transfer to the account (including confidential transfers, and self-transfers from it) needs a memo instruction immediately before the transfer, from the SPL Memo program (v1 or v3), or it fails with `NoMemo`. Only the program id is checked, not the memo text. Outgoing transfers need no memo.
- For a transfer made by CPI, the calling program must invoke the memo program right before its transfer CPI, at the same level; a memo at the top of the transaction doesn't count.
- The owner enables and disables it. On an account created without room, `Reallocate` first.
- CLI: `spl-token enable-required-transfer-memos <ACCOUNT>` / `disable-required-transfer-memos` (they reallocate if needed); send with `spl-token transfer ... --with-memo <TEXT>`. Kit: `getEnableMemoTransfersInstruction({ token, owner })` / `getDisableMemoTransfersInstruction(...)`. Anchor: `memo_transfer_initialize(ctx)` enables it, despite the name; `memo_transfer_disable(ctx)`.

## CpiGuard

- The owner turns it on and off only at the top level of a transaction; inside a CPI both fail with `CpiGuardSettingsLocked`.
- While on, inside a CPI:
  - transfers and burns signed by the owner fail (`CpiGuardTransferBlocked`, `CpiGuardBurnBlocked`); a delegate, including the permanent delegate, still can;
  - approve fails (`CpiGuardApproveBlocked`);
  - closing the account to anyone but the owner fails (`CpiGuardCloseAccountBlocked`);
  - setting a close authority fails (`CpiGuardSetAuthorityBlocked`);
  - unwrapping lamports fails for any signer.
- Changing the account owner fails even outside a CPI (`CpiGuardOwnerChangeBlocked`).
- Consequence for protocols: a program that moves a user's tokens with the user's own signature in a CPI fails for these users. Have the user approve the program's PDA as delegate in a top-level instruction, then transfer as that delegate.
- CLI: `spl-token enable-cpi-guard <ACCOUNT>` / `disable-cpi-guard` (they reallocate if needed). Kit: `getEnableCpiGuardInstruction({ token, owner })` / `getDisableCpiGuardInstruction(...)`. anchor-spl 1.2.0's `cpi_guard_enable` and `cpi_guard_disable` are deprecated, because a program can't toggle the guard through a CPI.

## Adding extensions to an existing account

`Reallocate` grows the account for the listed account extension types, with the owner signing and a payer covering the extra rent; it doesn't enable anything, so send the enable instruction after it. Kit `getReallocateInstruction({ token, payer, owner, newExtensionTypes: [ExtensionType.MemoTransfer] })`, Anchor `anchor_spl::token_2022::reallocate(ctx, &types)`. For a new account, `getPostInitializeInstructionsForTokenExtensions(token, owner, [extension('MemoTransfer', { requireIncomingTransferMemos: true })])` returns the enable instructions to send after `InitializeAccount`.
