# Closed-book baseline grading: Token-2022 (graded 2026-09-28)

Sources used (primary only):
- token-2022 @ 28a131de (program 11.1.0): `/home/user/solana-program/token-2022`
- `@solana-program/token-2022@0.19.0` (npm pack): `scratchpad/npm/package` (src/ + dist/types)
- `@solana/spl-token@0.4.15` (npm pack): `scratchpad/oldkit/splt/package`
- `solana-zk-sdk` 8.0.1 and 7.0.1 crates: `scratchpad/crates/`
- `spl-token-2022-interface` 2.1.0 / 3.0.0 / 3.1.0 crate tarballs; crates.io + npm registry version API
- Anchor master bce16223 (VERSION 1.2.0) + tag v1.2.0 via raw.githubusercontent
- token-acl @ 87c5f9a; whirlpools @ 408c945; solana-com @ 4d59f49 (docs + post-mortems via `git show`)
- Not verifiable: on-chain feature-gate activation (all RPC endpoints blocked by proxy; Helius MCP has no key)

Grades: C = correct, P = partly wrong, W = wrong, O = outdated, M = missed important.

---

## Q1 Kit mint (TransferFee + MetadataPointer + TokenMetadata): P + M
Correct:
- `extension('TransferFeeConfig', {...})`, `getMintSize([...])` exist (dist/types/generated/types/extension.d.ts:455+, getMintSize.d.ts).
- Space must EXCLUDE TokenMetadata; lamports must cover the full size. Confirmed: `createMint.ts:23` `POST_INITIALIZE_EXTENSIONS = ['TokenMetadata','TokenGroup','TokenGroupMember']`, space = getMintSize(filtered), rent = getMintSize(all). Reason: `_process_initialize_mint` requires `try_calculate_account_len == data_len` else `InvalidAccountData` (program/src/processor.rs:125-128).
- Order createAccount -> initTransferFeeConfig -> initMetadataPointer -> initMint -> initTokenMetadata; `getPre/PostInitializeInstructionsForMintExtensions` exist (getInitializeInstructionsForExtensions.d.ts).
Wrong:
- Conflated names: `getInitializeMintInstruction` = InitializeMint (v1, rent sysvar account); `getInitializeMint2Instruction` = InitializeMint2 (generated/instructions/initializeMint2.d.ts:44). Kit's own plan uses `getInitializeMintInstruction` (createMint.ts).
Missed:
- `getCreateMintInstructionPlan(client, {payer,newMint,decimals,mintAuthority,freezeAuthority,extensions})` does the whole thing incl. the space/rent split (createMint.d.ts). Also `getCreateTokenInstructionPlan`, `getMintToATAInstructionPlan`, `getTransferToATAInstructionPlan`, `token2022Program()` client plugin.
- Post-init TokenMetadata writes only name/symbol/uri (additionalMetadata ignored; needs `getUpdateTokenMetadataFieldInstruction`), and is SILENTLY SKIPPED when `updateAuthority` is None (getInitializeInstructionsForExtensions.ts:179-186).
- TransferFeeConfig pre-init reads `newerTransferFee.{transferFeeBasisPoints,maximumFee}` from the extension object (…ts:62-70).
- Kit post-init has no TokenGroupMember case (only TokenMetadata, TokenGroup).

## Q2 Anchor extensions:: constraints: W (pausable) + M
- Constraints at v1.2.0 (lang/syn/src/parser/accounts/constraints.rs at tag v1.2.0: permanent_delegate L217, transfer_hook L238, pausable L265): group_pointer{authority,group_address}, group_member_pointer{authority,member_address}, metadata_pointer{authority,metadata_address}, close_authority{authority}, permanent_delegate{delegate}, transfer_hook{authority,program_id}, **pausable{authority}**. Model said none for pausable: WRONG for Anchor 1.2.0 (released 2026-09-04; CHANGELOG.md:39 "spl: Add pausable mint extension support (#4092)"; spl/src/token_2022_extensions/pausable.rs has pausable_initialize/pause/resume).
- anchor-spl 1.2.0 still depends on `spl-token-2022-interface = "2"` (spl/Cargo.toml:48) — no PermissionedBurn, no permissioned-burn/scaled-ui constraints.
- Unreleased on master: `init_if_needed` now validates extension constraints on existing mints (CHANGELOG Unreleased, #4845).
- Types: mint is `InterfaceAccount<'info, Mint>`, token program `Program<'info, Token2022>` (tests/spl/token-extensions/.../instructions.rs:65,85). Model's "Mint type Program<'info, Token2022>" is at best ambiguous.

## Q3 rejected combos at InitializeMint: P + M
Ground truth `check_for_invalid_mint_extension_combinations` (interface/src/extension/mod.rs:1352-1370), called at program/src/processor.rs:129:
1. ConfidentialTransferFeeConfig without BOTH TransferFeeConfig and ConfidentialTransferMint
2. TransferFeeConfig + ConfidentialTransferMint without ConfidentialTransferFeeConfig (model had this)
3. ConfidentialMintBurn without ConfidentialTransferMint (had)
4. ScaledUiAmount + InterestBearingConfig (had)
5. NonTransferable + ConfidentialTransferMint without ConfidentialMintBurn (MISSED)
All -> `TokenError::InvalidExtensionCombination`.
- WRONG: NonTransferable + TransferFee / TransferHook are NOT rejected.
- Also at InitializeMint: DefaultAccountState=Frozen with no freeze authority -> `MintCannotFreeze` (processor.rs:131-136); exact-size check -> `InvalidAccountData`.
- Related (not InitializeMint): InitializeMember requires GroupMemberPointer on the member mint -> InvalidExtensionCombination (token_group/processor.rs ~174-180).

## Q4 CT status Sept 2026: P (history C, current status hedged)
- History correct: 2025-04-16 report, two patches 04-17/18 (post-mortem-may-2-2025.mdx L17-19); 2025-06-10 report, Token-2022 upgraded to disable CT 2025-06-11 via multisig, ZK ElGamal proof program disabled at epoch 805 on 2025-06-19 (post-mortem-june-25-2025.mdx L18-20, L34).
- Current: feature gates `disable_zk_elgamal_proof_program` (zkdoVw…) and `reenable_zk_elgamal_proof_program` (zkexuy…) both exist in agave feature set; token-2022 11.1.0 source has no CT kill switch; official docs (solana-com tokens/extensions/confidential-transfer/*) present CT as live with no disabled warning; Kit 0.10-0.19 (Jun-Sep 2026) ship full CT instruction plans. Secondary: re-enable gate activated epoch 982 (~2026-06-04) and Token-2022 redeployed ~2026-06-18 (web search, Medium). On-chain activation NOT verified here (RPC blocked). Skill should state "re-enabled mid-2026; verify feature zkexuy… on-chain" and warn that many guides still say disabled.

## Q5 key derivation / proofs: O + M
- OUTDATED: `ElGamalKeypair::new_from_signer(&signer, &token_account)` per-account seed. In solana-zk-sdk 7.0.1+/8.0.1 it is renamed `new_from_signer_legacy` and `#[deprecated]` ("Non-standard SHA3-512 KDF … use derivation::derive_confidential_keys", elgamal.rs:204-210; auth_encryption.rs:110).
- CURRENT standard: wallet-level, no seed. Rust `solana_zk_sdk::encryption::derivation::derive_confidential_keys(&signer)` (derivation.rs:157) signs constant `solana-conf-bal/v1` (HKDF salt, derivation.rs:71). JS `deriveConfidentialKeys({ signer })` from `@solana-program/token-2022/confidential` (confidentialTransferKeys.d.ts:35). Owner-mint helpers `deriveElGamalKeypairForOwnerMint`/`deriveAeKeyForOwnerMint` are @deprecated (migration only). Requires deterministic RFC 8032 signer; wallets should refuse generic signMessage starting with `solana-conf-bal/v1`. Also `ConfidentialKeys.fromIkm/fromPrf` in @solana/zk-sdk (docs integration-guide.mdx ~L118-122).
- JS proofs: `@solana/zk-sdk` correct (latest 0.5.3; optional peer ^0.5.1 of Kit client).
- Tx count: Kit `getConfidentialTransferInstructionPlan` = inline range proof, ~3 txs (docs transfer-tokens.mdx: tx1 create context accounts + validity, tx2 range proof, tx3 equality + transfer + close); `…WithRecordInstructionPlan` adds record-account txs. Model's 3-5 ok. MISSED that the Kit plans exist (transfer, withFee, withdraw, mint, burn, permissionedConfidentialBurn, empty/create account, decrypt/fetch balance).

## Q6 PermissionedBurn: P + W
- Code 28: C (ExtensionType enum order, mod.rs ~1141). Instruction discriminator 46 = PermissionedBurnExtension (interface/src/instruction.rs:1147); AuthorityType::PermissionedBurn = 17 (instruction.rs:1300).
- Co-signature (authority + owner/delegate): C.
- MISSED: standard Burn/BurnChecked FAIL with `TokenError::InvalidInstruction` while the authority is set (processor.rs:1158-1161); must use PermissionedBurn Burn/BurnChecked (Kit `getPermissionedBurnInstruction`/`…CheckedInstruction`). Permanent delegate also needs co-sign. Setting authority to None re-enables standard burns (docs permissioned-burn.mdx).
- WRONG: "in spl-token-2022-interface 2.x". 2.1.0 has no permissioned_burn module; added in 3.0.0 (2026-05-08) (crate tarballs). Latest 3.1.2.
- anchor-spl: no helper; anchor-spl 1.2.0 pins interface 2.x, so you must add interface 3.x separately (type-incompatible with anchor-spl's re-export) or hand-build the ix.

## Q7 Pausable: C (minor gaps)
- Blocks transfer (incl. permanent delegate; check is unconditional, processor.rs:400-404), mint_to (:1078), burn (:1210), and CT deposit/withdraw/transfer + confidential mint/burn (confidential_transfer/processor.rs:423,552,650; confidential_mint_burn/processor.rs:177,323). Error `MintPaused`.
- PausableAccount auto-added for accounts (mod.rs:1304 required account extension). Plain Transfer without mint fails MintRequiredForTransfer when PausableAccount present (processor.rs:434-437).
- Missed: Anchor 1.2.0 now has `extensions::pausable::authority` constraint + CPI helpers (see Q2).

## Q8 ScaledUi vs InterestBearing: C
- Continuous compounding via exp, SECONDS_PER_YEAR 365.24 days (interest_bearing_mint/mod.rs:27,62-66). ScaledUiAmountConfig {authority, multiplier, new_multiplier_effective_timestamp, new_multiplier} (scaled_ui_amount/mod.rs:56-62), UI amount truncated. Mutually exclusive (Q3).
- Kit equivalents exist: `amountToUiAmountForMintWithoutSimulation(rpc, mint, amount)`, `…ForInterestBearingMint…`, `…ForScaledUiAmountMint…` and inverses (dist/types/amountToUiAmount.d.ts). spl-token 0.4.15 also has it.

## Q9 transfer hook: P (Kit part wrong)
- Execute order src, mint, dst, owner/delegate, validation PDA, extras: C (spl-transfer-hook-interface 2.1.0 instruction.rs:23-29). Seeds `["extra-account-metas", mint]` under hook program: C (lib.rs:27).
- spl-token 0.4.15 `createTransferCheckedWithTransferHookInstruction`, `addExtraAccountMetasForExecute`, `createTransferCheckedWithFeeAndTransferHookInstruction`, `getExtraAccountMetaAddress`: C.
- WRONG "Kit: resolve manually": Kit 0.19 (since <=0.17) exports `getTransferCheckedWithTransferHookInstructionAsync(client, input)`, `resolveExtraAccountMetasForExecute`, `findExtraAccountMetaListPda`, ExtraAccountMeta codecs, `getDefaultInitializeExtraAccountMetaListInstructionAsync`, `deEscalateAccountMeta` (dist/types/transferHookExtraAccountMetas.d.ts; exported from index.d.ts:13).
- Transferring flag set/unset around CPI: C (processor.rs:596-598).

## Q10 Token ACL: P
- Program ID `TACLkU6CiCdkQN2MjoyDkVg2yAH9zkxiHDsiztQ52TP` (token-acl program/src/lib.rs:16, README:5, mainnet). Model only had prefix.
- Mechanism: DefaultAccountState=Frozen + freeze authority handed to Token ACL MintConfig; permissionless thaw/freeze gated by a gating program (README Overview/CLI `create-config`, `set-gating-program`, `set-instructions --enable-thaw`).

## Q11 Orca TokenBadge: C (list incomplete)
- Seeds `["token_badge", whirlpools_config, mint]`: C (initialize_pool_with_adaptive_fee.rs:21).
- `is_supported_token_mint` (programs/whirlpool/src/util/v2/token.rs:~208-305): no badge needed for TransferFeeConfig, InterestBearing, TokenMetadata, MetadataPointer, ScaledUiAmount, ConfidentialTransferMint/FeeConfig (non-confidential only). Badge required: freeze authority, PermanentDelegate, TransferHook, MintCloseAuthority, DefaultAccountState (and non-Initialized default needs freeze authority), Pausable. Always rejected: NonTransferable and ANY other/unknown extension (e.g. PermissionedBurn, ConfidentialMintBurn, GroupPointer/Group/Member).

## Q12 transfer fees: C
- ceil_div(amount*bps, 10000) capped at maximum_fee (transfer_fee/mod.rs:58-70). SetTransferFee new fee epoch = current+2 (program/src/extension/transfer_fee/processor.rs:105-106). Close blocked `AccountHasWithheldTransferFees` (interface transfer_fee/mod.rs:188 via processor.rs:1361). `TransferCheckedWithFee` + `FeeMismatch`.

## Q13 CPI Guard / MemoTransfer: C
- Error names all exist (interface/src/error.rs:174-198); `NoMemo` (error.rs:146); memo must be the previous processed sibling instruction (memo_transfer/mod.rs:18-29).

## Q14 token groups: C
- InitializeMember: member mint authority signer + group update authority (token_group/processor.rs:145-195); `SizeExceedsMaxSize` past max (spl-token-group-interface 0.7.2 state.rs:51-57); group/member data live in the mint itself (MintMismatch check); member mint must have GroupMemberPointer.

## Q15 versions: W (almost all stale)
| Package | Model | Actual (2026-09-28) |
|---|---|---|
| spl-token-2022 | ~10.x | 11.1.0 (2026-09-23) |
| spl-token-2022-interface | ~2.x | 3.1.2 (2026-09-23); 3.0.0 2026-05-08 |
| @solana-program/token-2022 | 0.6-0.8 | 0.19.0 (2026-09-21) |
| @solana/spl-token | 0.4.14 | 0.4.15 (2026-07-09) |
| @solana/kit | 5-6.x | 8.4.0 (Kit client peer ^8.3.0) |
| anchor | 1.0.x | 1.2.0 (2026-09-04); 2.0.0-rc.1 exists |
| pinocchio-token-2022 | 0.1-0.2 | 0.4.0 (2026-08-03) |
| (extra) solana-zk-sdk / @solana/zk-sdk | - | 8.0.1 / 0.5.3 |

## Q16 before/after InitializeMint2: C
- Matches Kit pre/post split (getInitializeInstructionsForExtensions.ts: pre cases L40-156 incl. ConfidentialMintBurn, ScaledUi, Pausable, PermissionedBurn; post L179-209 TokenMetadata, TokenGroup; account post: MemoTransfer L229, CpiGuard L239). ImmutableOwner before InitializeAccount3; ConfigureAccount (CT) after. Model correct.

## Q17 plain Transfer: C
- MintRequiredForTransfer for TransferHookAccount, TransferFeeAmount, PausableAccount (processor.rs:416-437). NonTransferableAccount -> `NonTransferable` (processor.rs:370-374). Also frozen/insufficient funds precede.

## Q18 ConfidentialMintBurn: C
- Instructions InitializeMint, RotateSupplyElGamalPubkey, UpdateDecryptableSupply, Mint, Burn, ApplyPendingBurn (interface/src/extension/confidential_mint_burn/instruction.rs:63-209). Public MintTo/Burn -> `IllegalMintBurnConversion` (processor.rs:1083-1084, 1215-1216); also CT Deposit/Withdraw blocked (confidential_transfer/processor.rs:433,548). Mint close requires `closable()` (processor.rs:1379-1380).

---

## Ranked: what a strong model gets wrong -> must be in the skill
1. Versions (Q15): every Token-2022 package version is 1-3 majors stale; interface is 3.x, Kit 8.x, Kit client 0.19, anchor 1.2, pinocchio-token-2022 0.4.
2. CT key derivation (Q5): wallet-level `deriveConfidentialKeys` / `derive_confidential_keys` (`solana-conf-bal/v1`); per-account `new_from_signer` is deprecated legacy.
3. Kit high-level helpers (Q1, Q5, Q9): `getCreateMintInstructionPlan`, CT instruction plans, `getTransferCheckedWithTransferHookInstructionAsync` / `resolveExtraAccountMetasForExecute`. Model thinks Kit has none.
4. PermissionedBurn (Q6): standard Burn is rejected (InvalidInstruction); dedicated ix; interface 3.x only; anchor-spl (pins interface 2) has no support.
5. Anchor 1.2 extension coverage (Q2): `extensions::pausable::authority` + pausable CPI helpers exist; no permissioned-burn/scaled-ui.
6. CT status (Q4): re-enabled mid-2026 (verify gate zkexuy… on-chain); model guesses.
7. Invalid combos (Q3): NonTransferable+CT needs ConfidentialMintBurn; NonTransferable+Fee/Hook is allowed; CTFeeConfig needs both.
8. Kit gotchas (Q1): TokenMetadata post-init skipped if updateAuthority None, additionalMetadata not written; getInitializeMintInstruction vs getInitializeMint2Instruction.
9. Token ACL program ID (Q10) and Orca's full badge/reject list (Q11: MintCloseAuthority, Pausable need badge; any unknown ext rejected).

## What it already knows -> omit or just link
- Transfer-fee math, epoch+2 rule, withheld-fee close error, TransferCheckedWithFee (Q12)
- CPI Guard / MemoTransfer errors and memo placement (Q13)
- Token group signers and max_size (Q14)
- Pre/post InitializeMint ordering, ImmutableOwner before InitializeAccount3 (Q16)
- MintRequiredForTransfer / NonTransferable behavior (Q17)
- ConfidentialMintBurn instruction set and IllegalMintBurnConversion (Q18)
- Pausable semantics (Q7), InterestBearing vs ScaledUi math (Q8)
- Transfer-hook Execute account order, PDA seeds, spl-token hook helpers, transferring flag (Q9 minus Kit)
- 2025 CT incident history (Q4 history)
