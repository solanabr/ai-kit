# Confidential transfers (extensions 4, 5, 16, 17, 24)

Current state as of 2026-09-28. Official guides: [confidential-transfer](https://solana.com/docs/tokens/extensions/confidential-transfer) and its sub-pages (create-mint, create-token-account, deposit-tokens, apply-pending-balance, transfer-tokens, withdraw-tokens, issuer-guide, integration-guide).

The Rust walkthrough in [confidential-transfers.md](../ext/solana-dev/skills/solana-dev/references/confidential-transfers.md) still shows the flow (configure, deposit, apply pending, transfer, withdraw), but these parts of it are out of date:

- it says the feature runs only on a test cluster (it is live on mainnet, below);
- it derives keys per token account (the standard is now per wallet);
- it counts 7 transactions per transfer (the current flow uses 3);
- its crate pins are behind: use `spl-token-2022` 11.1, the proof crates 0.6.1 and `spl-token-client` 0.19.1, all on `solana-zk-sdk` 7.x (mixing in zk-sdk 8.x fails to compile with two `ElGamalKeypair` types);
- the four "privacy levels" do not exist: `ConfidentialTransferMint` has only `authority`, `auto_approve_new_accounts` and `auditor_elgamal_pubkey`.

## Status

- The ZK ElGamal proof program was disabled on 2025-06-19 (epoch 805) after two proof-verification bugs ([post-mortem](https://solana.com/news/post-mortem-june-25-2025)), and re-enabled at slot 424,224,000 (epoch 982, June 2026) by feature `zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN`. Token-2022 was then redeployed with the confidential instructions enabled.
- Many guides and community skills still call the feature disabled. Check the cluster rather than any date: `solana feature status zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN -u mainnet-beta`.
- Wallet and venue support is thin; plan a withdraw-to-public path for users.

## Keys: one pair per wallet

- Rust: `solana_zk_sdk::encryption::derivation::derive_confidential_keys(&signer)`. JS: `deriveConfidentialKeys({ signer })` from `@solana-program/token-2022/confidential`. Both have the wallet sign the fixed message `solana-conf-bal/v1` and derive the ElGamal keypair and AE key from it.
- The signer must produce deterministic Ed25519 signatures (RFC 8032). Wallets should refuse generic `signMessage` requests that start with `solana-conf-bal/v1`, because that signature is the key.
- The per-account derivation (`ElGamalKeypair::new_from_signer(&signer, &token_account)`, now `new_from_signer_legacy`) and the JS `deriveElGamalKeypairForOwnerMint` / `deriveAeKeyForOwnerMint` are deprecated. Keys made that way don't match standard clients; use them only to migrate old balances.

## Building transfers

- The Kit plans live in the `@solana-program/token-2022/confidential` subpath, not the package root, and take `rpc` and `payer` inputs: `getConfidentialTransferInstructionPlan`, `getConfidentialTransferWithRecordInstructionPlan`, plus fee-transfer, withdraw, mint and burn plans. `@solana/zk-sdk` 0.5.x is the optional peer that generates proofs.
- The plain transfer plan takes about 3 transactions (context accounts plus the validity proof, the range proof, then the equality proof, transfer and cleanup). Its range-proof transaction sits close to the size limit and has no room for a compute-unit-limit instruction. With an executor that sets CU limits (the default one does), use the record-account variant or turn estimation off.
- `getConfigureConfidentialTransferAccountWithRegistryInstruction` is in Kit, but there is no JS client for the ElGamal registry program that creates the registry account.
- Rust: `spl-token-client` 0.19.1 has end-to-end helpers; `spl-token-confidential-transfer-proof-generation` / `-proof-extraction` 0.6 are the low-level crates.
- React Native: `@solana/zk-sdk`'s WASM doesn't load under Metro/Hermes, so generate proofs on a backend or the web.
- Incoming amounts land in the pending balance until the owner runs `ApplyPendingBalance`. The pending-credit counter defaults to 65,536 credits (fixed on the registry path, any value with plain `ConfigureAccount`); past it, transfers in fail with custom error 39 until the owner applies.
- A single deposit or transfer is capped at 2^48−1 base units.
- Proof verification is expensive: a range proof costs roughly 111k to 368k CU depending on bit width (approximate), which is why the plan splits transactions.

## Mint rules

- A fee mint with confidential transfers needs ConfidentialTransferFeeConfig; a non-transferable one needs ConfidentialMintBurn ([invalid combinations](../token-2022.md#invalid-combinations)).
- ConfidentialMintBurn (24) mints to and burns from encrypted balances, with supply kept as ciphertext under a supply ElGamal key. Public `MintTo`/`Burn` then fail with `IllegalMintBurnConversion`, and confidential `Deposit`/`Withdraw` are blocked. `@solana/spl-token` 0.4.15 and the `spl-token` CLI don't support it; use Kit or Rust.
- Transfer hooks still run on confidential transfers, with `amount = u64::MAX` ([transfer-hooks.md](transfer-hooks.md)).
- The permanent delegate can't move or burn encrypted balances ([issuer-controls.md](issuer-controls.md)).
- PermissionedBurn mints have a confidential burn with split proofs (`confidential_burn_with_split_proofs` in interface 3.x).

## Auditor

- The auditor sees amounts, not balances. Confidential transfers, fee transfers and confidential mint/burn carry the amount encrypted to the auditor key as low (16-bit) and high (32-bit) ciphertexts in instruction data; the auditor decrypts each and combines them. Balances are encrypted to the owner alone, so an auditor needs a transaction indexer.
- Decide who holds the auditor key before launch. The confidential transfer authority can change it with `UpdateMint` (a single signer, no multisig); the change applies to later transfers, and proofs built for the old key then fail.

## Confidential fees (16, 17)

- Withdrawing withheld fees needs the transfer-fee withdraw authority's signature plus a `CiphertextCiphertextEquality` proof that re-encrypts the withheld amount for the destination. The destination must be configured for confidential transfers, approved, not frozen, and accepting confidential credits. No Kit plan or CLI command does this; build the proof with `@solana/zk-sdk` and use the withdraw instruction builders.
- Harvest into the mint, then withdraw from the mint: withdrawing directly from accounts fails if any source changes before it lands.
- The fee ElGamal key is set at initialization and can't be rotated; `ConfidentialTransferFeeConfig.authority` only enables or disables harvest (harvest while disabled fails with custom error 56).
- The stock Rust client decrypts withheld fees only below 2^32 base units (its discrete-log search limit). Withdraw often so the withheld amount never reaches that, or the stock client can't recover it.

## Testing

LiteSVM and Surfpool run with the mainnet feature set, so proofs verify. Surfpool's `surfnet_setTokenAccount` can create a funded confidential account, and it also offers `surfnet_deriveConfidentialKeys` and `surfnet_getConfidentialBalance`. On `solana-test-validator` from Agave 3.1, proofs from `@solana/zk-sdk` 0.5.3 fail (that Agave verifies with an older zk-sdk). Details: [testing.md](testing.md).
