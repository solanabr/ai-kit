# Display amounts (extensions 10, 25)

Interest-bearing and scaled UI amount mints change only what users see; raw balances and supply never move. Official guides: [interest-bearing-tokens](https://solana.com/docs/tokens/extensions/interest-bearing-tokens), [scaled-ui-amount](https://solana.com/docs/tokens/extensions/scaled-ui-amount). Verified 2026-09-28 with `@solana-program/token-2022` 0.19 in LiteSVM.

- InterestBearingConfig compounds a rate continuously over time; ScaledUiAmount applies a multiplier and can schedule `new_multiplier` at `new_multiplier_effective_timestamp` (splits, dividends, rebasing). They cannot share a mint (`InvalidExtensionCombination`).
- Show balances through the extension-aware conversion, never `amount / 10^decimals`. Store and send raw amounts, and convert user input back with the inverse.
- The scaled UI amount issuer guide on solana.com still says the extension is "not live yet"; it is supported by the deployed program and the SDKs listed in [the index](../token-2022.md#versions-checked-2026-09-28).

## Kit rounds, the program truncates

`amountToUiAmountForMintWithoutSimulation(rpc, mint, raw)` and `amountToUiAmountForScaledUiAmountMintWithoutSimulation(raw, decimals, multiplier)` round to the nearest unit; the on-chain `AmountToUiAmount` truncates:

| Multiplier | Raw                  | Kit helper | On-chain |
| ---------- | -------------------- | ---------- | -------- |
| 1.5        | 1234567 (6 decimals) | 1.851851   | 1.85185  |
| 0.99       | 101                  | 0.0001     | 0.000099 |
| 0.99       | 1                    | 0.000001   | 0        |

When the exact value matters (settlement, tax reports, matching an explorer), simulate `getAmountToUiAmountInstruction({ mint, amount })` and read the return data, or use the RPC's `uiAmountString`. The helpers do switch to the scheduled multiplier once the cluster clock passes its timestamp, so read time from the cluster, not the local clock.

## Integrations

- Oracles and pricing that read raw amounts misprice these tokens; decide whether a price is per raw unit or per UI unit.
- Kamino accepts ScaledUiAmount mints but rejects InterestBearingConfig ones; Orca needs no badge for either ([integrating-mints.md](integrating-mints.md)).
