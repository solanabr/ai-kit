# Issuer controls

PermanentDelegate, DefaultAccountState, Pausable, PermissionedBurn, MintCloseAuthority and NonTransferable. All are mint extensions set before `InitializeMint`. Pausable adds PausableAccount to every token account, and NonTransferable adds NonTransferableAccount and ImmutableOwner.

Each authority below is rotated with SetAuthority, signed by the current holder (CLI `spl-token authorize <MINT> <TYPE> <NEW>`, or `--disable` for None). Setting an extension authority to None is permanent: later SetAuthority calls fail with `AuthorityTypeNotSupported`. A freeze authority set to None can't come back either (`MintCannotFreeze`). Orca, for one, needs a TokenBadge for PermanentDelegate, DefaultAccountState, Pausable and MintCloseAuthority, and rejects NonTransferable ([programs.md](programs.md)).

## PermanentDelegate

- A delegate that can `TransferChecked` (or `TransferCheckedWithFee`) and `Burn`/`BurnChecked` from any token account of the mint, with no approval and no amount limit. It co-signs permissioned burns too.
- It can't use plain `Transfer`, approve, revoke, close accounts, change account authorities, or touch confidential balances. It is still stopped by frozen accounts (`AccountFrozen`), a paused mint (`MintPaused`) and NonTransferable (`NonTransferable`, although burning still works there).
- Rotate with SetAuthority `PermanentDelegate` (CLI `permanent-delegate`). The current delegate signs; the mint authority can't replace it.
- CLI: `create-token --enable-permanent-delegate` (the delegate is the mint authority). Kit: `extension('PermanentDelegate', { delegate })`. Anchor: `extensions::permanent_delegate::delegate = ...` on `init`, or `permanent_delegate_initialize(ctx, &delegate)`.
- Every `InitializeAccount` for the mint logs "Warning: Mint has a permanent delegate, so tokens in this account may be seized at any time", which wallets and explorers can surface.

## DefaultAccountState

- Every new token account starts `Frozen` (or `Initialized`), including associated token accounts that other people create. Only the freeze authority can thaw them.
- `Frozen` needs a freeze authority at `InitializeMint` (`MintCannotFreeze`). The freeze authority can change the default with `UpdateDefaultAccountState`; existing accounts keep their state.
- Removing the freeze authority while the default is `Frozen` leaves every future account frozen for good.
- CLI: `create-token --enable-freeze --default-account-state frozen` (the extension needs `--enable-freeze`), then `spl-token update-default-account-state <MINT> <initialized|frozen>` and `spl-token thaw <ACCOUNT>`. Choosing `initialized` still adds the extension, which keeps the option of switching to frozen later.
- Kit: `extension('DefaultAccountState', { state: AccountState.Frozen })`, `getUpdateDefaultAccountStateInstruction({ mint, freezeAuthority, state })`, `getThawAccountInstruction({ account, mint, owner: freezeAuthority })`.
- Anchor: no constraint. `default_account_state_initialize(ctx, &AccountState::Frozen)` before `initialize_mint2`, and `default_account_state_update(ctx, &state)` (`AccountState` from `anchor_spl::token_interface::spl_token_2022::state`).

## Pausable

- The pause authority stops the mint with `Pause` and restarts it with `Resume`. While paused, these fail with `MintPaused`: `TransferChecked` and `TransferCheckedWithFee`, `MintTo`, burns (standard and permissioned) and the confidential deposit, withdraw, transfer, mint and burn.
- Still allowed while paused: approve, revoke, freeze and thaw, SetAuthority, closing accounts, creating accounts, and harvesting or withdrawing withheld fees.
- Plain `Transfer` from any token account of the mint fails with `MintRequiredForTransfer`, paused or not.
- The authority can't be None at initialize. Rotate it with SetAuthority `Pause` (CLI `pause`). Setting it to None while paused leaves the mint paused forever.
- CLI: `create-token --enable-pause` (authority = mint authority), `spl-token pause <MINT>`, `spl-token resume <MINT>`. CLI 5.6.1's pause and resume ignore `--multisig-signer`, so a multisig pause authority needs another client ([tooling gaps](../SKILL.md#combinations)).
- Kit: `extension('PausableConfig', { authority, paused: false })`, `getPauseInstruction({ mint, authority })`, `getResumeInstruction({ mint, authority })`. These two builders take no multisig signers.
- Anchor: `extensions::pausable::authority = ...` on `init`, or `pausable_initialize(ctx, authority)`; then `pausable_pause(ctx)` and `pausable_resume(ctx)`.

## PermissionedBurn

- While it has an authority, standard `Burn` and `BurnChecked` fail (`InvalidInstruction`). Burns go through `PermissionedBurn` or `PermissionedBurnChecked`, which need the burn authority's signature and the usual owner, delegate or permanent-delegate signature.
- The burn authority must sign directly (no multisig): the program checks `is_signer` and the key.
- Initialized with a non-null authority. Setting the authority to None (SetAuthority `PermissionedBurn`, CLI `permissioned-burn`) turns standard burns back on permanently.
- CLI (spl-token-cli 5.6.1): `create-token --enable-permissioned-burn` (authority = mint authority) or `--permissioned-burn <AUTHORITY>`; burn with `spl-token burn <ACCOUNT> <AMOUNT> --permissioned-burn-authority <KEYPAIR>`. The CLI doesn't detect the extension on its own.
- Kit: `extension('PermissionedBurn', { authority })`, `getPermissionedBurnInstruction({ account, mint, permissionedBurnAuthority, authority, amount })`, `getPermissionedBurnCheckedInstruction({ ..., decimals })`. web3.js 1.x has `createPermissionedBurnInstruction` and `createPermissionedBurnCheckedInstruction`.
- Anchor 1.2.0: no helper, and anchor-spl's interface 2.x predates the extension. Add the 3.x interface under another name, `spl-token-2022-interface-3 = { package = "spl-token-2022-interface", version = "3.1" }`, which compiles next to anchor-spl 1.2.0. Then `invoke` its builders: `extension::permissioned_burn::instruction::initialize(&token_program, &mint, &authority)` before `initialize_mint2`, and `burn_checked(&token_program, &account, &mint, &burn_authority, &owner, &[], amount, decimals)` with those four accounts.
- It is live on mainnet (program v11.0.0).

## MintCloseAuthority

- Lets the close authority close the mint and reclaim its rent once supply is 0: `CloseAccount` with the mint as the account. Fails with `MintHasSupply` while any supply remains, including withheld transfer fees. Pausing doesn't block it.
- A mint initialized with a None close authority can never be closed. Rotate with SetAuthority `CloseMint` (CLI `close-mint`).
- CLI: `create-token --enable-close`, then `spl-token close-mint <MINT> [--recipient <ADDRESS>]`. Kit: `extension('MintCloseAuthority', { closeAuthority })`, then `getCloseAccountInstruction({ account: mint, destination, owner: closeAuthority })`. Anchor: `extensions::close_authority::authority = ...` on `init`, or `mint_close_authority_initialize(ctx, Some(&authority))`; close with `close_account`.
- A closed mint address can be created again with different extensions while old token accounts still point at it. Integrations that cache mint data should re-check it; see the Token-2022 section of [security.md](../../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).

## NonTransferable (soulbound)

- Every transfer fails with `NonTransferable`, whoever signs, the permanent delegate included. Burning works (owner, delegate or permanent delegate), approve works (the delegate can only burn), and an empty account can close.
- `InitializeAccount` adds NonTransferableAccount and ImmutableOwner to every token account of the mint, so the account must have room for both; a smaller one fails at initialize with `InvalidAccountData`. Associated token accounts and Anchor's `init` are sized for them. web3.js 1.x `getAccountLenForMint` leaves out ImmutableOwner, so an account sized with it fails.
- Adding TransferFeeConfig or TransferHook does nothing, since no transfer ever runs. With ConfidentialTransferMint it also needs ConfidentialMintBurn.
- CLI: `create-token --enable-non-transferable`. Kit: `extension('NonTransferable', {})`. Anchor: no constraint; `non_transferable_mint_initialize(ctx)` before `initialize_mint2`.
