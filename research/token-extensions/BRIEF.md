# Token Extensions skill suite — research brief (issue solanabr/ai-kit#12)

Date: 2026-09-28. Fifteen research agents, three rounds. Facts read from primary source unless marked.
Detailed notes: [notes/](notes/). Runnable checks: [kit-litesvm/](kit-litesvm/) (Kit 0.19 in LiteSVM),
[rust-programs/](rust-programs/) (Anchor 1.2 / Pinocchio programs + LiteSVM tests). How to run: [README.md](README.md).

## 1. Does the Foundation already do this? No.
- solana-dev-skill (bb24c39, 2026-09-21): confidential-transfers.md (753 lines, Rust only, stale),
  kit/programs/token-2022.md (77 lines), security.md Token-2022 checklist (prose). 13/28 extension
  types uncovered (6, 7, 13, 16, 20–28).
- Only roadmap signal: solana-dev-skill issue #11 "support mosaic skill" (open since 2026-02-02, no reply).
- pay-skills = x402 API registry, no token content. eth-to-sol says "Token-2022 has no global pause" (wrong).
- Foundation tooling that works (SDK/CLI/programs, not skills): Mosaic (@solana/mosaic-sdk 0.2.0,
  293 unit tests pass offline), Token ACL `TACLkU6CiCdkQN2MjoyDkVg2yAH9zkxiHDsiztQ52TP` + ABL gate
  `GATEzzqxhJnsWF6vHRsgtixxSB8PaQdcqGEVTEHWiULz` (mainnet+devnet, Accretion audit 2025, sRFC-37 not final).
- Official docs (solana-com repo) now have a page per extension incl. pausable, permissioned-burn,
  scaled-ui-amount, plus /docs/tokenization/* (Token ACL, DvP, NAV). Weak spots: transfer-hook page
  has no Kit code; scaled-ui-amount/issuer-guide still says "not live yet". developer-content is superseded.

## 2. Stale claims in the Foundation skill (upstream-fix candidates)
1. CT "only on a TXTX cluster" — re-enabled on mainnet (gate `zkexuy…tMN`, slot 424,224,000, epoch 982;
   token-2022 program v11.0.0 "available on all networks"; v11.1.0 notes say devnet/testnet only, so mainnet likely runs 11.0.0).
2. CT key derivation per token account — now wallet-only `derive_confidential_keys(&signer)` /
   `deriveConfidentialKeys({signer})` ("solana-conf-bal/v1"); old `new_from_signer` → `new_from_signer_legacy`, deprecated.
3. "7 transactions" per CT transfer — official example uses 3.
4. CT crate pins 1–3 majors behind (spl-token-2022 10→11.1, solana-zk-sdk 5→8.0.1, …).
5. Four "privacy levels" that don't exist in the program.
6. No TS path — Kit 0.19 ships CT instruction plans.
7. `getMintSize([{extension:…}])` wrong shape — use `extension('Name', {...})`.
8. "All extension instructions before InitializeMint" — metadata/group are post-init.
9. security.md "`transfer` fails silently" — it's explicit `MintRequiredForTransfer` (also PausableAccount).
10. eth-to-sol pause claim.

## 3. Ground truth the skill must carry (baseline model got these wrong)
Closed-book strong model, graded against source: correct on fees, CPI Guard, memo, groups, hook account
order, init ordering, pausable semantics, UI-amount math, MintRequiredForTransfer, ConfidentialMintBurn errors.
Wrong/missing, ranked:
1. Versions (all 1–3 majors stale): spl-token-2022 11.1.0, -interface 3.1.2, @solana-program/token-2022 0.19.0,
   @solana/spl-token 0.4.15, @solana/kit 8.4.0, anchor 1.2.0, pinocchio-token-2022 0.4.0,
   solana-zk-sdk 8.0.1 / @solana/zk-sdk 0.5.3.
2. CT wallet-only key derivation (above).
3. Kit high-level helpers exist: `getCreateMintInstructionPlan`, CT instruction plans,
   `getTransferCheckedWithTransferHookInstructionAsync`, `resolveExtraAccountMetasForExecute`,
   `findExtraAccountMetaListPda`, `getPre/PostInitializeInstructionsForMintExtensions`.
4. PermissionedBurn: standard Burn/BurnChecked → `InvalidInstruction`; use dedicated
   PermissionedBurn Burn/BurnChecked with the burn-authority co-signer; interface ≥3.0.0 only.
5. Anchor 1.2.0: `extensions::pausable::authority` + pausable CPI helpers exist; nothing for
   PermissionedBurn / ScaledUiAmount / ConfidentialMintBurn; anchor-spl pins interface "2" (no PermissionedBurn).
6. CT live again since mid-2026 — tell agents to check the gate on-chain rather than trust dates.
7. Invalid mint combos (interface/src/extension/mod.rs check_for_invalid_mint_extension_combinations):
   CTFeeConfig needs TransferFee AND CTMint; TransferFee+CTMint needs CTFeeConfig; ConfidentialMintBurn needs CTMint;
   ScaledUi ⟂ InterestBearing; NonTransferable+CTMint needs ConfidentialMintBurn. NonTransferable+fee/hook IS allowed.
   DefaultAccountState(Frozen) without freeze authority → `MintCannotFreeze`.
8. Kit gotchas: TokenMetadata post-init silently skipped when updateAuthority is None and never writes
   additionalMetadata; getInitializeMintInstruction (v1) vs getInitializeMint2Instruction.
9. Token ACL program ID; Orca badge/reject lists.

## 4. SDK support for newest extensions (read from package source)
| Package | Pausable | PermissionedBurn | ScaledUi | ConfidentialMintBurn |
|---|---|---|---|---|
| @solana-program/token-2022 0.19.0 | ✅ | ✅ | ✅ | ✅ |
| @solana/spl-token 0.4.15 | ✅ | ✅ | ✅ | ❌ |
| spl-token CLI | ✅ | ✅ | ✅ | partial |
| anchor-spl 1.2.0 | partial (constraint + CPI) | ❌ | ❌ | ❌ |
| pinocchio-token-2022 0.4.0 | ✅ | ✅ | ✅ | ❌ |

## 5. Venue support (source-verified, file:line in venues notes)
- Orca Whirlpools: fees/metadata/scaled/interest allowed; hook, permanent delegate, default frozen,
  pausable, mint close → TokenBadge; NonTransferable and unlisted (PermissionedBurn, CMB, groups) rejected.
  Hooks functional (SwapV2 forwards extra accounts).
- Raydium CPMM + CLMM, Meteora DAMM v2: badge can "allow" hooks but swaps do NOT forward hook accounts → non-functional.
- Meteora DLMM: hooks functional per SDK/IDL (program closed; medium).
- Kamino klend: PermanentDelegate allowed unconditionally; InterestBearing rejected, ScaledUi allowed;
  fee/hook only while dormant; pausable only if not paused.
- marginfi: no extension filter (admin-trust); hooks functional via invoke_transfer_checked.
- Jupiter: Token-2022 fee-taking needs `instructionVersion=V2` (since Oct 2025); otherwise inherits venue.
- Explorer parses all extensions. Phantom/Solflare/Backpack/PumpSwap: UNVERIFIED (closed or stale source).
- Rule for integrators: check the venue forwards hook accounts, not just whether it badges the mint.

## 6. Developer pain (token-2022 / SPL GitHub issues by volume; StackExchange blocked)
1 ATA derivation with wrong owner/program; 2 hook extra-account resolution mismatches (off- vs on-chain);
3 CT outage confusion; 4 CLI/client footguns; 5 metadata rent/size underfunding; 6 JS lagging Rust.

## 7. Community skills
- Andy00L/solana-token-extensions-skill (PR #28): accurate (10/10 spot checks), `make verify` passes once
  build-sbf installed; one LiteSVM test crashes and passes via 40× retry; 7 broken links; nested
  solana-dev submodule; 4 agents + 6 commands overlap token-engineer; inspector read-only but unvalidated
  `rpcUrl`; 22 npm audit findings; inactive since 2026-06-28. Verdict: borrow ideas (MIT, credit), don't submodule.
- Others (SanctifiedOps, bounty repos #20/#45, sendai, QuickNode, Helius): thin or stale.

## 8. Kit constraints (from validate.sh, tests, CLAUDE.md)
- A `<name>/SKILL.md` folder is auto-listed every session → use plain reference files, no SKILL.md.
- Keep `token-2022.md` path (update.sh never deletes; agents link it).
- validate.sh link-checks only the hub SKILL.md and fails on #anchors → add a local-skill link check.
- Plugin can't carry ext/ links → keep token files full-install only.
- Minor bump 2.2.0 (+ plugin.json, marketplace.json, README badge, CHANGELOG; covers unreleased Sept 24–25 refactors).
- token-engineer: fix stale "migration" claim, trim duplicated gotchas, route to new files.
- Style: only what a strong model gets wrong (section 3), link official docs, no NEVER/ALWAYS.

## 10. Round 3 (verified by running code)
Kit 0.19 in LiteSVM 1.5 (41 checks × 10 runs, token-2022 11.0.0 and 11.1.0; scripts in kit-litesvm/):
- PASS: getCreateMintInstructionPlan; Pausable (MintPaused = 67); PermissionedBurn (plain burn = 12 InvalidInstruction,
  getPermissionedBurnCheckedInstruction works); combos (ScaledUi+Interest = 51, NonTransferable+Fee ok, Frozen w/o freeze auth = 16);
  getTransferCheckedWithTransferHookInstructionAsync + resolveExtraAccountMetasForExecute (plain transferChecked → MissingAccount).
- Gotchas: create-mint plan never writes additionalMetadata (rent is paid, update field later), silently skips TokenGroupMember
  and TokenMetadata when updateAuthority is None, uses InitializeMint v1; Kit ScaledUi/amountToUiAmount helpers ROUND while the
  program TRUNCATES (simulate AmountToUiAmount for exact values); Kit error enum only names codes 0–19 (not 51, 67);
  litesvm errors: use err.err().code; LiteSVM clock starts at 0.
Test harnesses:
- LiteSVM (0.17 Rust / 1.5 npm) bundles token-2022 11.0.0, mainnet feature set → ZK proof program enabled.
- solana-test-validator (Agave 3.1.14 and 4.3.0) bundles token-2022 10.0.0 → no PermissionedBurn; load newer via --bpf-program.
  zk-sdk 0.5.3 proofs fail on Agave 3.1 (zk-sdk 4.0), pass on LiteSVM.
- Mollusk programs-token-2022 0.15.1 = mid-2025 dump, no PermissionedBurn.
- Surfpool 1.6 = litesvm internals (11.0.0), CT cheatcodes (setTokenAccount confidential, deriveConfidentialKeys, getConfidentialBalance).
- anchor test (1.2) defaults to Surfpool; anchor init test template = litesvm.
Rust (all cargo check + build-sbf + LiteSVM runtime pass; rust-programs/):
- Crate split: spl-token-2022 11.1 keeps only onchain/offchain helpers + processor (rest deprecated re-exports);
  spl-token-2022-interface 3.x holds state/extensions/instructions; 3.x uses MaybeNull<Address> (.get()) instead of OptionalNonZeroPubkey.
- anchor-spl 1.2 pins interface ^2; adding `t22v3 = { package = "spl-token-2022-interface", version = "3.1" }` side by side
  compiles and runs with no error mapping (both on solana-program-error 3.0.1). Needed for PermissionedBurn CPI.
- anchor-spl transfer_checked DROPS remaining_accounts → hooked mints fail. Use spl_token_2022::onchain::invoke_transfer_checked
  or add_extra_accounts_for_execute_cpi. (Kit hub line "SPL transfers through token_interface::transfer_checked" needs this caveat.)
- interface 2.x get_extension_types() returns InvalidAccountData on a PermissionedBurn mint (unknown type 28);
  targeted get_extension::<T>() still works.
- Hook: meta-list PDA only forwarded if the caller passes it; uninitialized → InvalidAccountData; always create an ExtraAccountMetaList
  (even empty). Anchor's hook example types owner as SystemAccount (rejects PDA/multisig owners) → UncheckedAccount.
- Anchor 1.x Context<'info, T> (single lifetime); #[interface] removed in 1.0.0 (#4156).
- Pinocchio 0.4: import from pinocchio_token_2022::state; no_std needs program_entrypoint! + no_allocator! + nostd_panic_handler!.
- anchor 2.0.0-rc.1 (2026-08-12) is Pinocchio-based, pins pinocchio-token-2022 ^0.3 (not compiled).
Other facts:
- CT + TransferHook ARE combinable: hook is invoked with amount u64::MAX (confidential_transfer/processor.rs ~825-836).
- token-wrap (TwRapQCDhWkZRrDaHfZGuHxkZ91gHDRkyuzNqeU5MgR): 3 audits, JS 2.7.1; mainnet deployment unconfirmed (token-wrap#684 open).
  Wrapped mint only gets ConfidentialTransferMint. No in-place SPL→T22 migration. p-token (SIMD-0266, epoch 971) is unrelated.
- DAS (digital-asset-rpc-infrastructure) parses both TokenMetadata extension and Metaplex PDA; Explorer shows both.
  Metaplex skill has ~no Token-2022 content. No Foundation stance on token groups vs Metaplex Core.
- Security: real incidents = 2025 ZK proof bugs (no loss, ~1-year CT shutdown), permanent-delegate burn-after-buy (2024-09),
  BONKKILLER freeze honeypot (2024-04, ~$1.62M). No named hook-sell-blocker / mint-reinit / pause-abuse incident found.
  Trail of Bits token-integration-analyzer is EVM-only. Phantom warns on permanent delegate and shows fee %. RugCheck flags hooks.
  CU (approx, low-med): hook adds ~15k; CT range proof 111k–368k.
- PR token-2022#1508 "SlotReferenceFee" (would be ext 29) opened 2026-09-28, community, unreviewed — ignore for now.

## 9. Still unverified
- Token-2022 mainnet upgrade authority and deployed bytecode version (RPC/explorers blocked; Helius needs a key).
- Wallet extension support (Phantom, Solflare, Backpack), PumpSwap.
- StackExchange top questions.
- Open PR #1508 "SlotReferenceFee" (would be extension 29) — web-search only.
- mcp.solana.com token coverage (solana-dev MCP connection fails here).
