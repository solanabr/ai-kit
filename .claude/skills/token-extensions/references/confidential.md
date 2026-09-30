# Confidential transfers: prerequisites and decisions

Balances and transfer amounts encrypted with ElGamal, with zero-knowledge proofs checked on-chain. This page covers what to decide and set up. The step-by-step flow (keys, deposit, apply, transfer, withdraw) is in the solana-dev reference [confidential-transfers.md](../../ext/solana-dev/skills/solana-dev/references/confidential-transfers.md) and in the solana.com guides: https://solana.com/docs/tokens/extensions/confidential-transfer

## Network

- Proofs are verified by the ZK ElGamal Proof program (`ZkE1Gama1Proof11111111111111111111111111111`). It was switched off on mainnet after the June 2025 proof-verification bug and switched back on at epoch 982 by feature `zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN`; that feature is active on devnet too. Check any cluster, local validators included, with `solana feature status zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN -u <mainnet-beta|devnet|URL>`. A fresh Agave 4.0 `solana-test-validator` starts with it active, although the solana.com guides say a stock local validator lacks the program.

## Mint extensions

All three are initialized before `InitializeMint` and can't be added later.

- **ConfidentialTransferMint** `{ authority, auto_approve_new_accounts, auditor_elgamal_pubkey }`.
  - With `auto_approve_new_accounts` true, an account can use confidential transfers as soon as it is configured. With false, the confidential transfer authority must send `ApproveAccount` for each account (compliance or KYC gating). Changing the policy later doesn't touch configured accounts, and an approval can't be revoked.
  - The optional auditor key receives every transfer amount, encrypted to it, but not the balances. Rotating it only affects later transfers.
  - The authority approves accounts and changes the policy and auditor (`UpdateMint`). A multisig can't hold it. Rotate it with SetAuthority `ConfidentialTransferMint` (CLI `confidential-transfer-mint`).
- **ConfidentialTransferFeeConfig**: required once the mint has both TransferFeeConfig and ConfidentialTransferMint, and not allowed without them. It holds the ElGamal key that withheld confidential fees are encrypted to. Withdrawing them is signed by the TransferFeeConfig withdraw authority; this extension's own authority only turns harvest-to-mint on or off.
- **ConfidentialMintBurn**: the supply is encrypted as well, and the mint authority mints and burns confidentially. Such a mint rejects public `MintTo`, `Burn`, deposit and withdraw (`IllegalMintBurnConversion`). NonTransferable together with ConfidentialTransferMint requires it.

## Account setup

- Opt-in per token account. `Reallocate` to add ConfidentialTransferAccount (plus ConfidentialTransferFeeAmount on a fee mint), then `ConfigureAccount` with a public-key validity proof, signed by the owner. `ConfigureAccountWithRegistry` replaces the proof and the owner's signature with an ElGamal registry account.
- Incoming confidential credits land in a pending balance. The owner moves them to the available balance with `ApplyPendingBalance`. After the maximum number of pending credits (65,536 by default, set when configuring) further credits fail until the owner applies.
- Each deposit or transfer amount must be below 2^48. Closing an account needs `EmptyAccount` (a zero-balance proof) first.
- Derive the ElGamal and AES keys the standard way: one signature from the wallet over a fixed message, the same keys for all of its accounts (Kit `deriveConfidentialKeys({ signer })`, the CLI, `solana-zk-sdk`). It needs a signer that produces deterministic Ed25519 signatures. Seed-scoped derivations produce different keys, and balances encrypted under one set can't be read with the other.

## How other extensions interact

- Transfer hooks run on confidential transfers, with `amount = u64::MAX`.
- Pausable blocks deposit, withdraw, transfer and confidential mint and burn.
- Frozen accounts (for example under DefaultAccountState `Frozen`) can be configured but can't deposit, withdraw, send or receive until thawed.
- The permanent delegate has no power over encrypted balances, only over the public balance.
- A public transfer into a configured account needs the account's non-confidential credits enabled. A fee mint needs the confidential transfer-with-fee instruction and its extra proofs.
- CpiGuard blocks owner-signed confidential transfers and burns inside a CPI. MemoTransfer applies to confidential transfers too.

## Tooling

- CLI 5.6.1: `spl-token --program-2022 create-token --enable-confidential-transfers auto|manual` (with a transfer fee it also adds ConfidentialTransferFeeConfig), `configure-confidential-transfer-account`, `deposit-confidential-tokens`, `apply-pending-balance`, `transfer --confidential`, `withdraw-confidential-tokens`, `update-confidential-transfer-settings`, `enable-confidential-credits` / `disable-confidential-credits` and the non-confidential pair. It has no commands for approving or emptying accounts or for confidential mint and burn, and `transfer --confidential` on a fee mint isn't supported.
- Kit 0.19.0: create the mint with `extension('ConfidentialTransferMint', { authority, autoApproveNewAccounts, auditorElgamalPubkey })` in `createMint` (`auditorElgamalPubkey: null` for no auditor). The account and transfer helpers live under `@solana-program/token-2022/confidential` and need the peer dependency `@solana/zk-sdk` ^0.5.1: `deriveConfidentialKeys`, `getCreateConfidentialTransferAccountInstructionPlan`, `fetchConfidentialTransferBalance`, `getApplyConfidentialPendingBalanceInstructionFromToken`, `getConfidentialTransferInstructionPlan`, `getConfidentialTransferWithFeeInstructionPlan`, `getConfidentialWithdrawInstructionPlan`, `getConfidentialMintInstructionPlan`, `getConfidentialBurnInstructionPlan`, `getEmptyConfidentialTransferAccountInstructionPlan`. Single instructions such as `getApproveConfidentialTransferAccountInstruction` come from the package root.
- Anchor 1.2.0: anchor-spl has no confidential helpers; its confidential modules are empty placeholders.

## Reading the solana-dev reference

Its Rust walkthrough of configure, deposit, apply, transfer and withdraw is the useful part. Four things in it predate the current releases:

- Its "Current Network Availability" section says confidential transfers run only on a ZK-Edge test cluster. The mainnet feature above is active.
- Its "Privacy Levels" (Disabled, Whitelisted, OptIn, Required) aren't program settings. The mint has only the authority, the auto-approve flag and the auditor, and each account has its credit flags.
- It pins spl-token-2022 10.0.0 and imports paths that moved in 11.0.0 (`spl_token_2022::solana_zk_sdk`, `confidential_transfer::account_info`); the CLI 5.6.1 source imports those account-info types from `spl_token_client::zk_proofs`.
- It derives keys per token account (`new_from_signer(authority, token_account)`), which won't match keys from the standard derivation above.
