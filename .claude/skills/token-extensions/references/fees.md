# Transfer fees: TransferFeeConfig, TransferFeeAmount

A fee withheld from every `TransferChecked`. The sender is debited `amount`, the recipient is credited `amount - fee`, and the fee sits in the recipient's token account until the withdraw authority collects it.

- **Lives on:** the mint (TransferFeeConfig). Every token account of the mint gets TransferFeeAmount, which holds its withheld fees.
- **Authorities:** the transfer fee config authority changes the fee; the withdraw withheld authority collects fees. Rotate them with SetAuthority types `TransferFeeConfig` and `WithheldWithdraw` (CLI `spl-token authorize <MINT> transfer-fee-config|withheld-withdraw <NEW>`, or `--disable`). Either can be None, and setting one to None can't be undone.

## Fee math

- `fee = ceil(amount * basis_points / 10_000)`, capped at `maximum_fee`, and 0 when either is 0. Basis points above 10_000 fail with `TransferFeeExceedsMaximum`.
- The mint stores an older and a newer fee; the newer one applies from its epoch on. `SetTransferFee` in epoch N makes the new fee apply from epoch N+2, and calling it again before then restarts that delay. Read the fee that applies now with `get_epoch_fee(current_epoch)` (Rust) or `getEpochFee(config, epoch)` (web3.js 1.x), not `newer_transfer_fee`.
- Kit has no fee calculator. web3.js 1.x has `calculateEpochFee(config, epoch, amount)`; Rust has `TransferFeeConfig::calculate_epoch_fee(epoch, amount)` and `calculate_inverse_epoch_fee` for the gross amount behind a target net amount.

## Create the mint

CLI (the maximum fee is in UI units; the mint authority becomes both fee authorities):

```sh
spl-token --program-2022 create-token --decimals 6 \
  --transfer-fee-basis-points 50 --transfer-fee-maximum-fee 5000
```

Kit, as one entry in the `extensions` array of `createMint` or `getCreateMintInstructionPlan` (see the SKILL.md creation steps):

```ts
extension('TransferFeeConfig', {
  transferFeeConfigAuthority: authority,
  withdrawWithheldAuthority: authority,
  withheldAmount: 0n,
  olderTransferFee: { epoch: 0n, maximumFee: 5_000_000_000n, transferFeeBasisPoints: 50 },
  newerTransferFee: { epoch: 0n, maximumFee: 5_000_000_000n, transferFeeBasisPoints: 50 },
});
```

Only `newerTransferFee`'s basis points and maximum reach the initialize instruction; the program sets both fees to the current epoch. For a None authority, call `getInitializeTransferFeeConfigInstruction({ mint, transferFeeConfigAuthority, withdrawWithheldAuthority, transferFeeBasisPoints, maximumFee })` yourself, since `extension()` requires both addresses.

Anchor 1.2.0 has no `extensions::` constraint for fees. Create the account, then `transfer_fee_initialize(ctx, Some(&config_authority), Some(&withdraw_authority), basis_points, maximum_fee)`, then `initialize_mint2`: see the example in [programs.md](programs.md).

To keep the option of a fee later, create the mint with 0 basis points and keep the fee config authority. The extension can't be added to an existing mint.

## Transfer

- `TransferChecked` charges the fee. `TransferCheckedWithFee` also asserts the fee you computed and fails with `FeeMismatch` if it differs; use it when a UI has shown the user a fee (Kit `getTransferCheckedWithFeeInstruction({ source, mint, destination, authority, amount, decimals, fee })`, Anchor `transfer_checked_with_fee(ctx, amount, decimals, fee)`, CLI `spl-token transfer <MINT> <AMOUNT> <RECIPIENT> --expected-fee <UI_AMOUNT>`).
- Plain `Transfer` fails with `MintRequiredForTransfer`.
- A program that receives these tokens should reload the destination after the CPI and credit the balance change, not `amount`.
- A transfer to the same account charges no fee.

## Collect withheld fees

1. `HarvestWithheldTokensToMint` moves withheld fees from token accounts into the mint. Anyone can call it; it skips accounts it can't harvest and works on frozen accounts.
2. `WithdrawWithheldTokensFromMint` (withdraw authority signs) sends the mint's withheld total to a token account of the same mint that isn't frozen. `WithdrawWithheldTokensFromAccounts` does the same straight from listed token accounts.

| | Harvest to mint | Withdraw from mint | Withdraw from accounts |
|---|---|---|---|
| Kit | `getHarvestWithheldTokensToMintInstruction({ mint, sources })` | `getWithdrawWithheldTokensFromMintInstruction({ mint, feeReceiver, withdrawWithheldAuthority })` | `getWithdrawWithheldTokensFromAccountsInstruction({ mint, feeReceiver, withdrawWithheldAuthority, numTokenAccounts, sources })`; `numTokenAccounts` must equal `sources.length` |
| Anchor 1.2.0 | `harvest_withheld_tokens_to_mint(ctx, sources)` | `withdraw_withheld_tokens_from_mint(ctx)` | `withdraw_withheld_tokens_from_accounts(ctx, sources)` |
| CLI | `spl-token close` harvests first | `spl-token withdraw-withheld-tokens <RECIPIENT_ACCOUNT> --include-mint` | `spl-token withdraw-withheld-tokens <RECIPIENT_ACCOUNT> <SOURCE_ACCOUNT>...` |

The Anchor wrappers take their program id from the `token_program_id` account and pass no multisig signers, so a multisig authority needs a hand-built instruction.

## Gotchas

- A token account holding withheld fees can't be closed (`AccountHasWithheldTransferFees`). Harvest it to the mint first.
- Withheld fees still count in the supply. Closing a mint (MintCloseAuthority) needs a supply of 0, so withdraw and burn them first.
- TransferFeeConfig together with ConfidentialTransferMint also needs ConfidentialTransferFeeConfig ([confidential.md](confidential.md)); the CLI adds it when you enable both.
- Test the two-epoch delay by warping epochs: Surfpool's `surfnet_timeTravel` takes `{"absoluteEpoch": n}` ([cheatcodes.md](../../ext/solana-dev/skills/solana-dev/references/surfpool/cheatcodes.md)).
- Venues differ: some accept fee mints and some don't. Check each target before launch ([programs.md](programs.md)).
