# Token-2022 Extension Fact Base — Research Notes

Compiled 2026-09-28. Confidence labels per fact: High / Medium / Low / Speculative.

## 0. Environment notes

- solana-dev MCP (mcp.solana.com) is blocked by the egress proxy (403 on CONNECT) — confirmed via proxy status log. Could not use it this session.
- solana.com, docs.raydium.io, phantom.com, xroot.dev, dev.to, www.solana-program.com, anchor-lang.com were all EGRESS_BLOCKED for WebFetch. Worked: raw.githubusercontent.com, github.com (HTML), api.github.com via github MCP tools, crates.io (needs a non-empty User-Agent header), npm registry, WebSearch (server-side, not proxy-bound — used for anything on blocked domains, treat as Medium/Low confidence unless corroborated by a primary source).
- Cloned https://github.com/solana-program/token-2022 shallow to /home/user/solana-program/token-2022 (read-only, anonymous git proxy) for direct source inspection — this is the most reliable evidence for extension-combination rules and struct layouts.

## 1. Version matrix

| Component                                               | Latest version                                                                                                                                                                                                     | Release date                                                                           | Source                                                                                                                                                                 |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| spl-token-2022 (Rust program crate)                     | 11.1.0                                                                                                                                                                                                             | 2026-09-23                                                                             | crates.io API https://crates.io/api/v1/crates/spl-token-2022                                                                                                           |
| spl-token-2022-interface                                | 3.1.2                                                                                                                                                                                                              | 2026-09-23                                                                             | crates.io API                                                                                                                                                          |
| spl-token-2022-interface (earlier data pt)              | —                                                                                                                                                                                                                  | max_stable 11.0.0 released 2026-05-08 per docs.rs search snippet, 11.1.0 supersedes it | WebSearch of docs.rs/crates.io                                                                                                                                         |
| spl-transfer-hook-interface                             | 2.1.0                                                                                                                                                                                                              | 2025-11-05                                                                             | crates.io API                                                                                                                                                          |
| spl-tlv-account-resolution                              | 0.11.4                                                                                                                                                                                                             | 2026-09-17                                                                             | crates.io API                                                                                                                                                          |
| spl-token-metadata-interface                            | 1.0.1                                                                                                                                                                                                              | 2026-06-29                                                                             | crates.io API                                                                                                                                                          |
| spl-token-group-interface                               | 0.7.2                                                                                                                                                                                                              | 2026-03-23                                                                             | crates.io API                                                                                                                                                          |
| spl-pod                                                 | 0.7.4                                                                                                                                                                                                              | 2026-08-31                                                                             | crates.io API                                                                                                                                                          |
| spl-token-confidential-transfer-proof-generation (Rust) | 0.6.1                                                                                                                                                                                                              | 2026-06-12                                                                             | crates.io API                                                                                                                                                          |
| spl-token-confidential-transfer-proof-extraction (Rust) | 0.6.1                                                                                                                                                                                                              | 2026-05-21                                                                             | crates.io API                                                                                                                                                          |
| spl-token-client (Rust)                                 | 0.19.1                                                                                                                                                                                                             | 2026-06-12                                                                             | crates.io API                                                                                                                                                          |
| pinocchio-token-2022 (Anza)                             | 0.4.0                                                                                                                                                                                                              | 2026-08-03                                                                             | crates.io API                                                                                                                                                          |
| anchor-spl                                              | max_stable listed as 1.2.0 (Anchor 1.0.0 shipped 2026-04-02; 1.0.1 2026-04-21, 1.0.2 2026-05-02, 1.0.3 2026-06-26); newest published tag on registry is 0.32.2 (pre-1.0 branch still receiving updates) 2026-09-14 | see below                                                                              | crates.io API + WebSearch of docs.rs/GitHub release notes (Medium — crates.io "newest_version" field ambiguous between two release lines, not independently confirmed) |
| @solana-program/token-2022 (Kit JS client)              | 0.19.0                                                                                                                                                                                                             | 2026-09-21                                                                             | npm view (registry.npmjs.org)                                                                                                                                          |
| @solana-program/token (legacy Token Kit client)         | 0.17.0                                                                                                                                                                                                             | not captured                                                                           | npm view                                                                                                                                                               |
| @solana/kit                                             | 8.4.0                                                                                                                                                                                                              | not captured                                                                           | npm view                                                                                                                                                               |
| @solana/spl-token (legacy web3.js client)               | 0.4.15                                                                                                                                                                                                             | 2026-07-09                                                                             | npm view                                                                                                                                                               |
| @solana/spl-token-metadata                              | 0.1.6                                                                                                                                                                                                              | not captured                                                                           | npm view                                                                                                                                                               |
| @metaplex-foundation/mpl-token-metadata                 | 3.4.0                                                                                                                                                                                                              | not captured                                                                           | npm view                                                                                                                                                               |
| codama                                                  | 1.11.0                                                                                                                                                                                                             | not captured                                                                           | npm view                                                                                                                                                               |

### Anchor / anchor-spl extension coverage (Medium confidence, WebSearch-derived, not independently read from anchor-lang.com because that domain is blocked)

- Anchor 0.30.0 introduced `#[interface]` macro + the `extensions::<name>::<constraint>` account-constraint syntax usable with `init` (creating) or without `init` (validating existing mints/accounts). Source: anchor-lang.com/docs/tokens/extensions (via WebSearch synthesis), anchor 0.30.0 release notes, GitHub solana-foundation/anchor v0.30.0 tests directory `tests/spl/token-extensions/...instructions.rs`.
- `anchor_spl::token_interface` + `anchor_spl::token_2022::spl_token_2022::extension` re-export the Token-2022 extension types for CPI/account validation.
- A `token_2022_extensions` module in anchor-spl provides helper functions/instruction builders for some extensions (transfer hook, metadata pointer mentioned explicitly in search results).
- Anchor 1.0.0 (first stable major, 2026-04-02) is a breaking-change release: TS client now fetches IDLs from the on-chain Program Metadata Program instead of a fixed path; anchor-lang-idl's serde_json dependency made optional. Could not verify inside 1.0.x specifically which additional extension constraints (e.g. pausable, permissioned-burn, scaled-ui-amount) were added — **UNVERIFIED**, flag for direct doc read if used in a skill.

## 2. Mainnet Token-2022 program state

- Program ID: `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb` (High — widely and consistently referenced, e.g. solana-gym-env repo trajectory JSON, standard knowledge).
- Program has been upgradeable (not immutable) at least through 2025–2026: the June 2025 post-mortem states "The Token-2022 program is currently an upgradable program" (source: solana-foundation/solana-com repo, `apps/media/content/posts/post-mortem-june-25-2025.mdx`, fetched via GitHub code search — High confidence, primary Solana Foundation post-mortem text).
- **Do not confuse with classic SPL Token**: on 2026-05-13 (start of epoch 971), SIMD-0266 replaced the classic SPL Token program's (`TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`) bytecode in-place with the Pinocchio-based "p-token" reimplementation, moved it to the upgradeable loader, and set upgrade authority to None (immutable). This is the LEGACY Token program, not Token-2022. Source: dev.to/xroot.dev articles surfaced via WebSearch (Medium — could not fetch primary source directly, domain blocked; cross-check with SIMD-0266 text recommended before shipping in docs).
- No verified, directly-fetched confirmation of Token-2022's own current upgrade authority (single key vs multisig vs revoked) — **UNVERIFIED**. Recommend `solana program show TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb -u mainnet-beta` via Helius/RPC before publishing as fact.

## 3. Extension type table (28 types, interface/src/extension/mod.rs)

Source for enum + discriminants: raw.githubusercontent.com/solana-program/token-2022 interface/src/extension/mod.rs (High — primary source, fetched directly).

| #   | ExtensionType                 | Level   | Purpose (short)                                                             |
| --- | ----------------------------- | ------- | --------------------------------------------------------------------------- |
| 1   | TransferFeeConfig             | Mint    | Configurable transfer fee (bps + max), withheld fees                        |
| 2   | TransferFeeAmount             | Account | Tracks withheld fee amount per account                                      |
| 3   | MintCloseAuthority            | Mint    | Authority allowed to close mint once supply = 0                             |
| 4   | ConfidentialTransferMint      | Mint    | Enables Confidential Balances at mint level                                 |
| 5   | ConfidentialTransferAccount   | Account | Per-account encrypted balance state                                         |
| 6   | DefaultAccountState           | Mint    | New accounts default to Frozen/Initialized                                  |
| 7   | ImmutableOwner                | Account | Owner can never be reassigned (ATAs use this)                               |
| 8   | MemoTransfer                  | Account | Requires a memo preceding incoming transfers                                |
| 9   | NonTransferable               | Mint    | Tokens are soul-bound (no P2P transfer)                                     |
| 10  | InterestBearingConfig         | Mint    | UI-amount accrues interest over time                                        |
| 11  | CpiGuard                      | Account | Restricts certain actions when invoked via CPI                              |
| 12  | PermanentDelegate             | Mint    | A permanent delegate authority over all accounts                            |
| 13  | NonTransferableAccount        | Account | Marker for accounts of a non-transferable mint                              |
| 14  | TransferHook                  | Mint    | Arbitrary CPI program invoked on every transfer                             |
| 15  | TransferHookAccount           | Account | Marker + transferring flag for hook accounts                                |
| 16  | ConfidentialTransferFeeConfig | Mint    | Confidential version of transfer-fee withholding                            |
| 17  | ConfidentialTransferFeeAmount | Account | Encrypted withheld-fee amount                                               |
| 18  | MetadataPointer               | Mint    | Points to the account holding TokenMetadata                                 |
| 19  | TokenMetadata                 | Mint    | On-mint name/symbol/uri/additional metadata (Metaplex-style)                |
| 20  | GroupPointer                  | Mint    | Points to the account holding TokenGroup                                    |
| 21  | TokenGroup                    | Mint    | Collection/group definition + max size + current size                       |
| 22  | GroupMemberPointer            | Mint    | Points to the account holding TokenGroupMember                              |
| 23  | TokenGroupMember              | Mint    | Membership record linking a mint to a TokenGroup                            |
| 24  | ConfidentialMintBurn          | Mint    | Confidential (encrypted) minting/burning, requires ConfidentialTransferMint |
| 25  | ScaledUiAmount                | Mint    | Updatable multiplier applied to displayed UI amount (rebasing/dividends)    |
| 26  | Pausable                      | Mint    | Pause authority can halt all mint/transfer/burn                             |
| 27  | PausableAccount               | Account | Marker for accounts of a pausable mint                                      |
| 28  | PermissionedBurn              | Mint    | Requires a designated authority's approval to burn                          |

### Authority field per newer extension (read directly from interface crate source, High confidence)

- `PausableConfig { authority: MaybeNull<Address>, paused: Bool }` — authority can pause/resume; when `paused`, transfers/mints/burns on that mint are rejected. (interface/src/extension/pausable/mod.rs)
- `PermissionedBurnConfig { authority: MaybeNull<Address> }` — a designated authority's signature/approval is required to burn from the mint. (interface/src/extension/permissioned_burn/mod.rs — file inspected directly, no burn-approval instruction details captured beyond the config struct; recommend deeper read of `permissioned_burn/instruction.rs` before writing exact instruction semantics — **partial**.)
- `ScaledUiAmountConfig { authority: MaybeNull<Address>, multiplier: PodF64, new_multiplier_effective_timestamp: UnixTimestamp, ... }` — authority can schedule a new multiplier effective at a future timestamp (struct truncated in read, has more fields for old/new multiplier pair). (interface/src/extension/scaled_ui_amount/mod.rs)

## 4. Invalid mint-extension combinations (ground truth from source)

Function: `ExtensionType::check_for_invalid_mint_extension_combinations()`
File: `interface/src/extension/mod.rs` in solana-program/token-2022 (fetched at commit 28a131de9e25e292f7a5f6c164498d90d4b38359 via raw.githubusercontent.com — High confidence, primary source, full function body captured verbatim).
Called from `program/src/processor.rs` inside mint initialization processing (confirmed via `mcp__github__search_code`, High confidence).

```rust
pub fn check_for_invalid_mint_extension_combinations(
    mint_extension_types: &[Self],
) -> Result<(), TokenError> {
    // tracks: transfer_fee_config, confidential_transfer_mint,
    // confidential_transfer_fee_config, confidential_mint_burn,
    // interest_bearing, scaled_ui_amount, non_transferable

    if confidential_transfer_fee_config && !(transfer_fee_config && confidential_transfer_mint) {
        return Err(TokenError::InvalidExtensionCombination);
    }
    if transfer_fee_config && confidential_transfer_mint && !confidential_transfer_fee_config {
        return Err(TokenError::InvalidExtensionCombination);
    }
    if confidential_mint_burn && !confidential_transfer_mint {
        return Err(TokenError::InvalidExtensionCombination);
    }
    if scaled_ui_amount && interest_bearing {
        return Err(TokenError::InvalidExtensionCombination);
    }
    if non_transferable && confidential_transfer_mint && !confidential_mint_burn {
        return Err(TokenError::InvalidExtensionCombination);
    }
    Ok(())
}
```

Rules in plain English:

1. ConfidentialTransferFeeConfig requires BOTH TransferFeeConfig AND ConfidentialTransferMint present.
2. If a mint has both TransferFeeConfig and ConfidentialTransferMint, it MUST also add ConfidentialTransferFeeConfig (can't have public fees + confidential transfers without the confidential fee extension).
3. ConfidentialMintBurn requires ConfidentialTransferMint.
4. ScaledUiAmount and InterestBearingConfig are mutually exclusive (can't combine two "amount is not what's stored" mechanisms).
5. NonTransferable + ConfidentialTransferMint is only allowed if ConfidentialMintBurn is also present (i.e. plain confidential transfer of a non-transferable/soulbound token is disallowed — only confidential mint/burn accounting makes sense on such a token).

No source-code comments explain rationale; the "why" above is inferred (Medium confidence on the rationale, High confidence on the rule itself).

Note: an earlier (2024) Solana Foundation blog post (`token-extensions-developer-guide.mdx`) also states two older/independent facts still true in spirit: "Non-transferable + {transfer hooks, transfer fees, confidential transfer}" was called out as a restricted combination historically, and "Confidential transfer + fees (available in 1.18)" — i.e. ConfidentialTransferFeeConfig shipped in program version tied to Agave 1.18. (Medium — older doc, cross-check against current source above, which is authoritative.)

This function only checks MINT-level combinations; it does not surface every possible account-level conflict — a full audit should also grep `program/src/processor.rs` for per-instruction extension checks (not completed this session — recommend follow-up).

## 5. Confidential Transfers — verified mainnet timeline

Primary sources: solana-foundation/solana-com repo `apps/media/content/posts/post-mortem-june-25-2025.mdx` and `post-mortem-may-2-2025.mdx` (fetched via GitHub code search, High confidence — this is the Solana Foundation's own post-mortem text), corroborated by WebSearch synthesis citing the same issue thread and independent blog analysis (Medium corroboration).

- **2025-06-10**: A flaw in the ZK ElGamal proof program verifier's Fiat–Shamir transcript was discovered.
- **2025-06-11**: Token-2022 program itself was updated (program upgrade) to disable confidential-transfer instructions as a short-term mitigation. Direct quote: "the Token-2022 program was updated to disable confidential transfers on 2025-06-11." (post-mortem-june-25-2025.mdx — High)
- **2025-06-19, start of epoch 805 (slot 347,760,000 per WebSearch synthesis — Medium, not independently confirmed against a primary numeric source this session)**: A validator feature gate (`disable_zk_elgamal_proof_program`) was activated network-wide, removing the ZK ElGamal Proof program from the runtime entirely, "out of an abundance of caution," while audits proceed. (post-mortem text — High for the fact of the gate + reason; Medium for exact slot number.)
- **2026-06-04, start of epoch 982 (slot 424,224,000 per WebSearch synthesis — Medium)**: `reenable_zk_elgamal_proof_program` feature gate activated, restoring the ZK ElGamal Proof program on mainnet after completed audits.
- **~2026-06-18 (slot ~427,147,035 per WebSearch synthesis — Medium/Low, single-source, not independently verified)**: Token-2022 program redeployed with confidential-transfer instructions restored.
- **As of 2026-09-17 (per WebSearch synthesis of a blog post)**: the disable gate has not been re-triggered since re-enablement; usage of confidential transfers is described as "close to zero" and many third-party guides still incorrectly describe the 2025 shutdown as current — **flag this explicitly in any skill we write**, since stale docs are a known trap.

**Action item**: the exact slot numbers (347,760,000 / 424,224,000 / 427,147,035) came from a WebSearch-synthesized answer, not from directly reading a feature-gate explorer or Agave feature-set source. Before publishing these numbers in a skill, verify against `agave feature status` output or a block explorer (e.g. via Helius `heliusChain` RPC — not done this session because solana-dev MCP was down and time was spent elsewhere). Mark as Medium confidence until cross-checked.

## 6. Confidential Transfer proof-generation tooling (current, from primary docs source)

Source: solana-foundation/solana-com repo `apps/docs/content/docs/en/tokens/extensions/confidential-transfer/integration-guide.mdx`, fetched via raw.githubusercontent.com (High — primary docs source, current as of main branch today).

- **JS/WASM**: `@solana/zk-sdk` is the primary WASM SDK for proof generation — generates `CiphertextCommitmentEqualityProofData`, `BatchedGroupedCiphertext3HandlesValidityProofData`, `BatchedRangeProofU128Data`.
- `@solana-program/token-2022` (Kit JS client, v0.19.0 as of 2026-09-21) ships higher-level helpers including `getConfidentialTransferInstructionPlan`, which returns a full instruction plan (proof setup + transfer + cleanup).
- `@solana-program/zk-elgamal-proof` JS client provides the proof-verification instructions.
- **Rust**: `spl-token-client` (0.19.1, 2026-06-12) provides high-level end-to-end helpers, e.g. `confidential_transfer_transfer`. `spl-token-confidential-transfer-proof-generation` (0.6.1, 2026-06-12) and `spl-token-confidential-transfer-proof-extraction` (0.6.1, 2026-05-21) are the lower-level proof crates.
- **Gap called out explicitly in the docs**: "Registry configuration is available in the Rust spl-token-client today. Equivalent helpers in the @solana-program/token-2022 JS client are not available yet, so JS integrations that need the registry path should track that client's releases." — i.e. `ConfigureAccountWithRegistry` (the `ElGamalRegistry`-based account setup, an alternative to `VerifyPubkeyValidity` proof) is Rust-only as of today. **High confidence, direct quote from current docs.**

## 7. Ecosystem support (wallets / DEXes) — mostly Medium/Low confidence, WebSearch-derived; domains largely blocked for direct fetch

- **Real-world issuers using Token-2022 extensions** (Medium-High, corroborated across Solana Foundation media posts + PayPal developer blog, both surfaced via GitHub code search of solana-foundation/solana-com):
  - **PYUSD** (PayPal USD): confidential transfer amounts enabled, aimed at merchant privacy with regulator visibility. Source: `apps/media/content/posts/rwas-libre-on-solana.mdx` (Solana Foundation) + PayPal developer blog (WebSearch).
  - **USDG** (Paxos Global Dollar, issued by Paxos Digital Singapore): Permanent Delegate, Confidential Transfers, Metadata, Transfer Hook, MintCloseAuthority (per Paxos docs, via WebSearch — Medium, not independently fetched).
  - **Libre** (RWA tokenization): Permanent Delegate, Non-Transferable, Token Metadata, Metadata Pointer. Source: same Solana Foundation post (High for the claim as reported by Solana Foundation).
  - **Etherfuse**: Interest-Bearing extension for tokenized Mexican government bonds. Same source.
- **Orca (Whirlpools)**: not all Token Extensions are supported for pools; a **TokenBadge** PDA whitelist mechanism gates certain extensions/tokens, notably Token-2022 mints with FreezeAuthority set are rejected unless Orca has issued a TokenBadge (or freeze authority is disabled). Badge review is manual/case-by-case via Orca Discord/Telegram. Source: docs.orca.so/create/pools/extensions and dev.orca.so architecture docs (via WebSearch synthesis — Medium, domain not independently fetched this session, but description is consistent with the well-known TokenBadge design).
- **Raydium**: CPMM supports Token-2022 including TransferFeeConfig mints (swap instruction forwards transfer-fee-aware accounting); CLMM `SwapV2` supports TransferHook (forwards hook remaining-accounts). Source: docs.raydium.io/algorithms/token-2022-transfer-fees (title/URL only, page content blocked — Low-Medium, corroborate before publishing).
- **Jupiter, Meteora DAMM v2**: general aggregator/AMM support for Token-2022 mints is asserted by multiple 2026 "best DEX" roundup articles, but no extension-by-extension breakdown was retrievable this session (domains largely blocked or thin content). **Treat as Low confidence / unverified for extension-level granularity** — flag for a follow-up pass that reads docs.jup.ag and Meteora's GitHub docs directly.
- **Wallets (Phantom, Solflare, Backpack)**: could not fetch phantom.com or wallet-specific docs directly (blocked). WebSearch snippets indicate Phantom has published consumer-facing educational content on Token Extensions and states an intent to support "all extensions," and Solflare's own comparison copy claims general "SPL and Token-2022" support. **No extension-by-extension wallet support matrix could be verified this session — mark UNVERIFIED and recommend a dedicated follow-up reading each wallet's own docs/changelog directly (not through this proxy).**

## 8. sRFC-37 "Token ACL" (freeze-authority-based permissioned tokens) — new standard, live on mainnet

Source: WebSearch synthesis of github.com/solana-foundation/token-acl, github.com/solana-foundation/SRFCs discussion #2, forum.solana.com thread (forum.solana.com not independently fetched — Medium confidence overall, but multiple independent search snippets agree).

- sRFC 37 defines a **Token Access Control List (ACL)** standard for permissioned tokens without needing a custom Transfer Hook program for every gate.
- Mechanism: issuer sets `DefaultAccountState = Frozen` on a Token-2022 mint (extension #6) and delegates the mint's **freeze authority** to a `MintConfig` PDA owned by the Token ACL program. Accounts can then be permissionlessly thawed/frozen by proving eligibility against an issuer-chosen external "Gate Program."
- Described as "live on mainnet since March 2026, with real institutional money already using it" (WebSearch synthesis — Medium, unverified date).
- Authority-management discussion: Token ACL intentionally remains a single delegated freeze authority; multi-authority/multisig management is expected to live outside it (e.g., via Squads), per forum discussion (Medium).
- Relevant repo: github.com/solana-foundation/token-acl — not cloned/read directly this session; recommend doing so before writing a skill section on it, since it is a fast-moving 2026 standard.
- No new _ExtensionType_ is introduced by sRFC-37 — it composes existing extensions (DefaultAccountState + delegated freeze authority), so it does not add a 29th discriminant to the enum. **This composition point is Medium confidence (inferred from the mechanism description); verify against the token-acl repo directly.**
- No other new extension PRs against solana-program/token-2022 were identified this session beyond the 28 already in `mod.rs` — a dedicated GitHub PR/issue sweep (open PRs adding new `ExtensionType` variants) was not completed and should be a follow-up (**gap**).

## 9. Pinocchio / native-program ecosystem

- `pinocchio-token-2022` (Anza-maintained, crates.io 0.4.0, 2026-08-03) provides **core Token-2022 instructions only, without extension-specific CPI builders**, per WebSearch synthesis of its docs.rs/GitHub description (Medium).
- Community crates attempting fuller extension coverage exist but are described as fragmented/incomplete/draft: `pinocchio-tkn` (zero-dependency CPI helpers for SPL Token + Token-2022, claims "zero-allocation builders for all 22 Token-2022 extension instructions" — note this count of "22" predates/undercounts the current 28 ExtensionType variants, so treat the completeness claim skeptically), and `pina_token_2022_extensions` (explicitly labeled "draft"). **Low confidence on completeness claims — verify against actual crate source before recommending in a skill.**

## 10. Open gaps / follow-ups for whoever writes the skill suite

1. Verify Token-2022 program's current upgrade authority (single key / multisig / none) via `solana program show TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb -u mainnet-beta` or Helius `heliusChain` RPC (solana-dev MCP and direct RPC were not available/used this session).

- Note: the CLAUDE.md-mandated workflow for building on a program (upgrade authority / verified build / audit history check) could NOT be completed for Token-2022 itself this session due to the proxy outage on mcp.solana.com — flag this explicitly to whoever picks up the skill work.

2. Confirm exact slot numbers for the ZK ElGamal disable/re-enable feature gates and the Token-2022 redeploy slot against a primary source (Agave feature-gate list or explorer), not just WebSearch synthesis.
3. Read `permissioned_burn/instruction.rs` and `pausable/instruction.rs` / `processor.rs` directly (only mod.rs structs were read this session) to document exact instruction names and CPI signatures for the 4 newest extensions (24–28).
4. Do a GitHub PR/issue sweep on solana-program/token-2022 for 2026 activity proposing new extensions beyond the current 28.
5. Directly read docs.jup.ag, Meteora's GitHub docs, and each wallet's own docs (Phantom/Solflare/Backpack) for an extension-by-extension support matrix — all were blocked by the egress proxy this session and only characterized via secondary WebSearch snippets.
6. Confirm anchor-spl 1.0.x's exact extension constraint coverage (which of the 28 extensions have `extensions::` init constraints in Anchor 1.0 vs only CPI helpers) by reading anchor-lang.com/docs/tokens/extensions directly (blocked this session) or the anchor GitHub repo's `tests/spl/token-extensions` test fixtures at the 1.0.x tag.

## Sources list (deduplicated)

- https://raw.githubusercontent.com/solana-program/token-2022/28a131de9e25e292f7a5f6c164498d90d4b38359/interface/src/extension/mod.rs (ExtensionType enum + check_for_invalid_mint_extension_combinations, fetched 2026-09-28)
- https://github.com/solana-program/token-2022 (cloned shallow locally, interface/src/extension/{pausable,permissioned_burn,scaled_ui_amount}/mod.rs read directly, 2026-09-28)
- https://crates.io/api/v1/crates/{spl-token-2022,spl-token-2022-interface,spl-transfer-hook-interface,spl-tlv-account-resolution,spl-token-metadata-interface,spl-token-group-interface,spl-pod,anchor-spl,pinocchio-token-2022,spl-token-confidential-transfer-proof-generation,spl-token-confidential-transfer-proof-extraction,spl-token-client} (fetched 2026-09-28)
- npm registry: @solana/spl-token, @solana-program/token-2022, @solana-program/token, @solana/kit, @solana/spl-token-metadata, codama, @metaplex-foundation/mpl-token-metadata (fetched 2026-09-28)
- https://raw.githubusercontent.com/solana-foundation/solana-com/main/apps/docs/content/docs/en/tokens/extensions/confidential-transfer/index.mdx (full page, fetched 2026-09-28)
- https://raw.githubusercontent.com/solana-foundation/solana-com/main/apps/docs/content/docs/en/tokens/extensions/confidential-transfer/integration-guide.mdx (proof-tooling section, fetched 2026-09-28)
- https://raw.githubusercontent.com/solana-foundation/solana-com/main/apps/docs/content/docs/en/tokens/extensions/meta.json (extension doc-page list, fetched 2026-09-28)
- solana-foundation/solana-com repo, `apps/media/content/posts/post-mortem-june-25-2025.mdx` and `post-mortem-may-2-2025.mdx` (official Solana Foundation post-mortems, retrieved via GitHub code search 2026-09-28)
- solana-foundation/solana-com repo, `apps/media/content/posts/rwas-libre-on-solana.mdx` (PYUSD/Libre/Etherfuse extension usage, retrieved via GitHub code search 2026-09-28)
- https://github.com/solana-program/token-2022/issues/657 (re-enablement tracking issue, partial read 2026-09-28)
- WebSearch snippets (Medium/Low corroboration only, domains blocked for direct fetch): docs.orca.so/create/pools/extensions, dev.orca.so, docs.raydium.io/algorithms/token-2022-transfer-fees, phantom.com/learn/crypto-101/solana-token-extensions, xroot.dev/blog/{token-2022-pausable-permissioned-burn, solana-confidential-transfers-native-vs-rings}, dev.to/sulimanmukhtar/_ (3 posts), github.com/solana-foundation/token-acl, github.com/solana-foundation/SRFCs/discussions/2, forum.solana.com/t/srfc-37-_, docs.rs/crate/anchor-spl, anchor-lang.com/docs/updates/release-notes/\*, github.com/solana-foundation/anchor v0.30.0 test fixtures.
