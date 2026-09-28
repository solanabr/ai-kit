# Closed-book baseline questions (answered with no tools, no skill)
1. Kit: create Token-2022 mint with TransferFeeConfig + MetadataPointer + TokenMetadata in one tx; size + lamports.
2. Anchor 1.x #[derive(Accounts)] for mint init with transfer hook + metadata pointer via extensions:: constraints; which extensions have constraints.
3. Which mint extension combos are rejected at InitializeMint.
4. Confidential Transfers mainnet status Sept 2026 + 2025 history.
5. ElGamal/AE key derivation today (Rust, JS); JS proof package; tx count for a CT transfer.
6. PermissionedBurn: code, behavior, interface crate version, anchor-spl support.
7. Pausable: what it blocks, account ext, Anchor detection, vault handling.
8. ScaledUiAmount vs InterestBearing; combinable?; frontend display.
9. Transfer hook: Execute account order, ExtraAccountMetaList seeds, client resolution (Kit + spl-token), 5 security checks.
10. sRFC-37/Token ACL; program ID; relation to DefaultAccountState; Mosaic.
11. DEX/lending integration of arbitrary T22 mints; dangerous extensions; Orca TokenBadge.
12. Transfer fees: fee calc, SetTransferFee timing, harvest/withdraw, close blocked.
13. CPI Guard + MemoTransfer: what breaks, design.
14. Token groups: init order, signers for member add, vs Metaplex Core.
15. Latest versions Sept 2026 of spl-token-2022, -interface, @solana-program/token-2022, @solana/spl-token, @solana/kit, anchor, pinocchio-token-2022.
16. Which ixs before/after InitializeMint2; same for accounts/InitializeAccount3.
17. Plain transfer on T22: when it fails, which error.
18. ConfidentialMintBurn: purpose, requirements.
