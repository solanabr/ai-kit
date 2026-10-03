# Display amounts: InterestBearingConfig, ScaledUiAmount

Both change only how a raw amount converts to a UI amount. Balances, supply, transfers, mints and burns stay in raw units; nothing on-chain rescales them. A mint can have one of the two, not both (`InvalidExtensionCombination`). Both live on the mint and add nothing to token accounts.

## InterestBearingConfig

- Rate in basis points as an `i16`, so negative rates are allowed. Interest compounds continuously on the cluster clock, so the effective APY is higher than the stated rate.
- The rate authority changes the rate with `UpdateRate`. The history collapses into one time-weighted average rate, stored as whole basis points, so UI amounts after several rate changes are approximate. Rotate the authority with SetAuthority `InterestRate` (CLI `interest-rate`).
- CLI: `spl-token --program-2022 create-token --interest-rate <RATE_BPS>` (the rate authority is the mint authority), then `spl-token set-interest-rate <MINT> <RATE> [--rate-authority <SIGNER>]` (no multisig authority; see the CLI multisig note in [SKILL.md](../SKILL.md)).
- Kit: `extension('InterestBearingConfig', { rateAuthority, initializationTimestamp: 0n, preUpdateAverageRate: rate, lastUpdateTimestamp: 0n, currentRate: rate })`; only `rateAuthority` and `currentRate` reach the initialize instruction. Later: `getUpdateRateInterestBearingMintInstruction({ mint, rateAuthority, rate })`.
- Anchor 1.2.0: `interest_bearing_mint_initialize(ctx, rate_authority: Option<Pubkey>, rate: i16)` before `initialize_mint2`, and `interest_bearing_mint_update_rate(ctx, rate)`.

## ScaledUiAmount

- UI amount = raw × multiplier (an `f64`), truncated to the mint's decimals. For stock splits, dividends paid as more units, and rebasing tokens.
- The multiplier authority calls `UpdateMultiplier { multiplier, effective_timestamp }`. A timestamp at or before now applies immediately; a future one waits in a single pending slot, so a second update before it takes effect replaces the pending one. The multiplier must be a positive, finite, normal float, or the update fails with `InvalidScale`. Rotate the authority with SetAuthority `ScaledUiAmount` (CLI `scaled-ui-amount`).
- CLI: `spl-token --program-2022 create-token --ui-amount-multiplier <MULTIPLIER>`, then `spl-token update-ui-amount-multiplier <MINT> <MULTIPLIER> [<UNIX_TIMESTAMP>]`. Without a timestamp the CLI uses the local clock. It ignores `--multisig-signer`.
- Kit: `extension('ScaledUiAmountConfig', { authority, multiplier, newMultiplierEffectiveTimestamp: 0n, newMultiplier: multiplier })`. The Kit name is `ScaledUiAmountConfig`; in Rust the ExtensionType variant is `ScaledUiAmount` and the state struct is `ScaledUiAmountConfig`. Later: `getUpdateMultiplierScaledUiMintInstruction({ mint, authority, multiplier, effectiveTimestamp })`.
- Anchor 1.2.0 has no helper for it. Build the instruction with `anchor_spl::token_interface::spl_token_2022::extension::scaled_ui_amount::instruction::initialize` or `update_multiplier`, then invoke it yourself.

## Showing amounts

- Kit, no simulation: `amountToUiAmountForMintWithoutSimulation(rpc, mint, amount)` and `uiAmountToAmountForMintWithoutSimulation(rpc, mint, uiAmount)`. They read the mint and the Clock sysvar, so they use cluster time and pick the active multiplier. Pure variants take the parameters directly: `amountToUiAmountForInterestBearingMintWithoutSimulation(...)`, `amountToUiAmountForScaledUiAmountMintWithoutSimulation(amount, decimals, multiplier)`.
- Kit 0.19.0's scaled raw-to-UI helper rounds at the last decimal where the program truncates, so it can show one unit more at the last decimal. For exact parity, use the on-chain `AmountToUiAmount` instruction (Kit `getAmountToUiAmountInstruction`, simulated), which returns the UI string as return data. `UiAmountToAmount` goes the other way.
- web3.js 1.x has `...WithoutSimulation` helpers with the same names, but they truncate in both directions, so on interest-bearing mints their UI-to-raw result can be one unit below the program's rounded one. Its simulated `amountToUiAmount` and `uiAmountToAmount` default to the classic Token program, so pass `TOKEN_2022_PROGRAM_ID`.
- Users type UI amounts. Going from UI to raw, the scaled conversions (Kit and on-chain) truncate, while the interest-bearing ones round to nearest; floor the result yourself where the raw amount must not exceed what was typed. A "max" button should send the full raw balance.
- The CLI's `transfer`, `mint` and `burn` read amounts as `ui × 10^decimals` and ignore both extensions.
- Scaled UI integration, from the solana.com guide: show the scaled price as well as the scaled balance, refresh the multiplier (it can change at a scheduled time), and keep raw amounts internally for accounting and history. https://solana.com/docs/tokens/extensions/scaled-ui-amount/integration-guide
