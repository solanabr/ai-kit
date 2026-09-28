# Confidential transfers (extensions 4, 5, 16, 17, 24)

Current state as of 2026-09-28. Official guides: [confidential-transfer](https://solana.com/docs/tokens/extensions/confidential-transfer) and its sub-pages (create-mint, create-token-account, deposit-tokens, apply-pending-balance, transfer-tokens, withdraw-tokens, issuer-guide, integration-guide).

The Rust walkthrough in [confidential-transfers.md](../ext/solana-dev/skills/solana-dev/references/confidential-transfers.md) still shows the flow (configure, deposit, apply pending, transfer, withdraw), but these parts of it are out of date:

- it says the feature runs only on a test cluster (it is live on mainnet, below);
- it derives keys per token account (the standard is now per wallet);
- it counts 7 transactions per transfer (the current flow uses 3);
- its crate pins are behind (`spl-token-2022` 10 → 11.1, `solana-zk-sdk` 5 → 8.0.1, proof crates 0.5 → 0.6);
- the four "privacy levels" do not exist: `ConfidentialTransferMint` has only `authority`, `auto_approve_new_accounts` and `auditor_elgamal_pubkey`.

## Status

- The ZK ElGamal proof program was disabled on 2025-06-19 (epoch 805) after two proof-verification bugs (no funds lost), and re-enabled at slot 424,224,000 (epoch 982, June 2026) by feature `zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN`. Token-2022 was then redeployed with the confidential instructions enabled (around 2026-06-18).
- Many guides and community skills still call the feature disabled. Check the cluster rather than any date: `solana feature status zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN -u mainnet-beta`.
- Wallet and venue support is thin; plan a withdraw-to-public path for users.

## Keys: one pair per wallet

- Rust: `solana_zk_sdk::encryption::derivation::derive_confidential_keys(&signer)`. JS: `deriveConfidentialKeys({ signer })` from `@solana-program/token-2022/confidential`. Both have the wallet sign the fixed message `solana-conf-bal/v1` and derive the ElGamal keypair and AE key from it.
- The signer must produce deterministic Ed25519 signatures (RFC 8032). Wallets should refuse generic `signMessage` requests that start with `solana-conf-bal/v1`, because that signature is the key.
- The per-account derivation (`ElGamalKeypair::new_from_signer(&signer, &token_account)`, now `new_from_signer_legacy`) and the JS `deriveElGamalKeypairForOwnerMint` / `deriveAeKeyForOwnerMint` are deprecated. Keys made that way don't match standard clients; use them only to migrate old balances.

## Building transfers

- Kit 0.19 ships instruction plans: `getConfidentialTransferInstructionPlan` (about 3 transactions: context accounts plus the validity proof, the range proof, then the equality proof, transfer and cleanup), a record-account variant, and plans for fee transfers, withdraw, mint and burn. `@solana/zk-sdk` (0.5.x) is the optional peer dependency that generates proofs.
- Rust: `spl-token-client` 0.19 has end-to-end helpers; `spl-token-confidential-transfer-proof-generation` / `-proof-extraction` 0.6 are the low-level crates.
- `ConfigureAccountWithRegistry` (ElGamal registry setup) exists in the Rust client but not yet in the JS Kit client.
- Incoming amounts land in the pending balance until the owner runs `ApplyPendingBalance`.
- Proof verification is expensive: a range proof costs roughly 111k to 368k CU depending on bit width (approximate), which is why the plan splits transactions.

## Mint rules

- A fee mint with confidential transfers needs ConfidentialTransferFeeConfig; a non-transferable one needs ConfidentialMintBurn ([invalid combinations](../token-2022.md#invalid-combinations)).
- ConfidentialMintBurn (24) mints to and burns from encrypted balances, with supply kept as ciphertext under a supply ElGamal key. Public `MintTo`/`Burn` then fail with `IllegalMintBurnConversion`, and confidential `Deposit`/`Withdraw` are blocked. `@solana/spl-token` 0.4.15 does not support it; use Kit or Rust.
- Transfer hooks still run on confidential transfers, with `amount = u64::MAX` ([transfer-hooks.md](transfer-hooks.md)).
- PermissionedBurn mints have a confidential burn with split proofs (`confidential_burn_with_split_proofs` in interface 3.x).
- The auditor key can decrypt transfer amounts; decide who holds it before launch.

## Testing

LiteSVM and Surfpool run with the mainnet feature set, so proofs verify. Surfpool's `surfnet_setTokenAccount` can create a funded confidential account, and it also offers `surfnet_deriveConfidentialKeys` and `surfnet_getConfidentialBalance`. On `solana-test-validator` from Agave 3.1, proofs from `@solana/zk-sdk` 0.5.3 fail (that Agave verifies with an older zk-sdk). Details: [testing.md](testing.md).
