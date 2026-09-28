# Token-2022 Extension Support by Venue — Source-Verified Notes

Method: shallow git clone of each program/SDK repo from GitHub, grep for extension
allow/deny logic, read the file, record commit hash + commit date for the exact
file cited (not repo HEAD, unless noted). All repos cloned to
`/tmp/claude-0/.../scratchpad/venues/repos/`. Today: 2026-09-28.

All commit dates below are the **last commit that touched the cited file**
(`git log -1 --format="%H %ad" -- <path>`), not repo HEAD, unless stated.

---

## 1. Orca Whirlpools — orca-so/whirlpools

Repo HEAD: `408c945fef4c49ab70def4303377cfaf8f0f3c99` (2026-09-03)

File: `programs/whirlpool/src/util/v2/token.rs`
Commit: `058a586975e49eaa69b8581e1b0d56348be46a02` (2026-08-06)
Function: `is_supported_token_mint()` (line 208) and `is_token_badge_initialized()` (line 310)

Logic (lines 208-323):
- Legacy Token Program mints: always allowed.
- Native Token-2022 mint: rejected outright (line 222-224).
- Any mint with a `freeze_authority` set: rejected unless TokenBadge is initialized (line 227).
- Per-extension (iterated via `get_token_extension_types`):
  - **Always allowed, no badge**: `TransferFeeConfig`, `InterestBearingConfig`, `TokenMetadata`, `MetadataPointer`, `ScaledUiAmount` (lines 240-244).
  - **Partially allowed, no badge**: `ConfidentialTransferMint`, `ConfidentialTransferFeeConfig` — allowed but non-confidential-only; vault accounts can't receive confidentially (lines 246-259).
  - **Badge-gated**: `PermanentDelegate` (261), `TransferHook` (266), `MintCloseAuthority` (271), `DefaultAccountState` (276, additionally requires state==Initialized unless a freeze_authority exists), `Pausable` (291).
  - **Rejected outright, no badge escape**: `NonTransferable` (line 297-299).
  - Any unknown/unhandled extension type → rejected (line 301-303, catch-all).
- `TokenBadge` PDA is per-`(whirlpools_config, token_mint)` and is created/deleted via admin-only `initialize_token_badge`/`delete_token_badge` instructions (`programs/whirlpool/src/instructions/v2/*token_badge*.rs`).

SwapV2 hook forwarding: `programs/whirlpool/src/instructions/v2/swap.rs`
(commit `058a586975e49eaa69b8581e1b0d56348be46a02`, 2026-08-06), lines 83-99, 178-179:
`parse_remaining_accounts` decodes `AccountsType::TransferHookA` / `TransferHookB` from
`remaining_accounts_info` and forwards the resolved extra-account-metas into the swap CPI —
i.e. Orca has real, working TransferHook support for badge-approved mints, not just an
allow-flag. **Confidence: High** (direct source, exact file/line).

---

## 2. Raydium CP-Swap — raydium-io/raydium-cp-swap

Repo HEAD: `59fb845a9e5bb569c8b2f3415f13b0c0ebcc6b92` (2026-09-10)

File: `programs/cp-swap/src/utils/token.rs`, function `is_supported_mint()` (lines 335-360).
Commit: repo HEAD 59fb845a... (file not separately dated in this session, treat as HEAD-current).

Logic:
- Legacy Token Program: allowed (line 340-342).
- If `SupportMintAssociated` PDA (Raydium's version of a TokenBadge, admin-created via
  `create_support_mint_associated_owner` allowlist, see
  `programs/cp-swap/src/instructions/admin/create_support_mint_associated.rs`) is
  initialized for the mint → **allowed unconditionally, bypasses ALL further extension
  checks** (line 343-345). This is a coarser badge model than Orca's: it does not
  re-validate per-extension once a badge exists.
- Otherwise, only these extensions pass: `TransferFeeConfig`, `MetadataPointer`,
  `TokenMetadata`, `InterestBearingConfig`, `ScaledUiAmount` (lines 350-357). Anything
  else (PermanentDelegate, TransferHook, NonTransferable, DefaultAccountState,
  MintCloseAuthority, Pausable, ConfidentialTransfer*, …) → **rejected** without a badge.

**Gotcha — TransferHook is not actually wired up at all**: `grep -rn "TransferHook"
programs/` across the whole cp-swap program returns **zero matches**. There is no
extra-account-metas resolution or forwarding anywhere in `swap_base_input.rs` /
`swap_base_output.rs`. Even if an admin creates a `SupportMintAssociated` badge for a
hook-enabled mint (which the code technically permits, since the badge bypasses the
allowlist), the raw `token_2022::transfer_checked` CPI in
`programs/cp-swap/src/utils/token.rs` lines 29-71 has no hook account list appended,
so any transfer of a mint with an *active* transfer hook program would fail at
runtime. **TransferHook = de facto rejected in CP-Swap, badge or not.** Confidence: High
(absence confirmed by full-repo grep).

Fee-on-transfer accounting: `get_transfer_fee` / `get_transfer_inverse_fee`
(lines 254-304) read `TransferFeeConfig` via `StateWithExtensions` and compute the
current-epoch fee both directions (used so pool math nets fee-on-transfer correctly for
both exact-in and exact-out swaps).

---

## 3. Raydium CLMM — raydium-io/raydium-clmm

Repo HEAD: `ed7c84a54ced59c55981780546adb0b4583dcf85` (2026-08-19)

File: `programs/amm/src/util/token.rs`, function `is_supported_mint()` (lines 306-331).
Same allowlist as CP-Swap: `TransferFeeConfig`, `MetadataPointer`, `TokenMetadata`,
`InterestBearingConfig`, `ScaledUiAmount` unconditionally; `SupportMintAssociated` badge
(admin-gated, same `create_support_mint_associated.rs` pattern) bypasses all checks for
any other extension (lines 314-316).

**TransferHook: also absent from the whole repo** (`grep -rn "TransferHook"
programs/` → 0 hits). `SwapSingleV2`'s `remaining_accounts` (see
`programs/amm/src/instructions/swap_v2.rs` lines 74-141) are used **only** for
`TickArrayBitmapExtension` / extra `TickArrayState` accounts (the loop at line 132-141
checks `data_len() == TickArrayState::LEN` / `TickArrayBitmapExtension::LEN`), never for
transfer-hook extra-account-metas. Same conclusion as CP-Swap: TransferHook mints are
effectively unusable in a Raydium CLMM pool even with the admin badge. Confidence: High.

Fee accounting: `get_transfer_fee` / `get_transfer_inverse_fee`
(`programs/amm/src/util/token.rs` lines 219-275), same pattern as CP-Swap, applied in
`exact_internal_v2` (`swap_v2.rs` lines 101-109) to convert between fee-included and
fee-excluded amounts before calling `swap_internal`.

---

## 4. Meteora DAMM v2 — MeteoraAg/cp-amm (formerly "damm-v2"; that name now redirects to cp-amm)

Repo HEAD: `a85c926607433f23f0ea60f4ca7b1ae92f4156cb` (2026-09-08)

File: `programs/cp-amm/src/utils/token.rs`
- `is_permissionless_supported_mint()` (lines ~213-262):
  - Legacy Token Program: allowed.
  - Native Token-2022 mint: **hard error** `UnsupportNativeMintToken2022` (not just false).
  - `TransferFeeConfig`, `MetadataPointer`, `TokenMetadata`: permissionless-allowed.
  - `TransferHook`: permissionless-allowed **only if** both `program_id` and `authority`
    on the extension are `None` (i.e., the extension is present but inert/disabled) —
    an *active* hook is rejected at the permissionless tier (lines ~248-255).
  - Any other extension type → rejected (line 258).
- `validate_mint()` (lines 264-290): if `skip_mint_validation` is set OR the mint passes
  `is_permissionless_supported_mint`, allow. Otherwise requires a `TokenBadge` account
  (`token_badge.token_mint == mint`) — and **once the badge matches, there is no further
  per-extension re-check** (same coarse-badge pattern as Raydium): a badge lets any
  extension combination through, including PermanentDelegate, NonTransferable, active
  TransferHook, DefaultAccountState, Pausable, etc.

**Gotcha**: even with a badge, `transfer_from_user` / `transfer_from_pool`
(same file, lines ~163-215) call raw `spl_token_2022::instruction::transfer_checked`
via `invoke_signed` with **no extra accounts appended** — there is no
`add_extra_account_metas_for_execute` / on-chain ExtraAccountMetaList resolution
anywhere in `programs/cp-amm/src/instructions/` outside of unrelated
`remaining_accounts` uses (reward init/refresh vesting, `ix_p_swap.rs` sysvar lookup —
grep confirms no hook-account forwarding). So functionally, **DAMM v2 also cannot swap
against a mint with an active transfer hook**, matching Raydium, even though the badge
mechanism nominally "allows" it. Confidence: High (source-verified, full-repo grep for
hook-account forwarding returned none).

DLMM (Meteora's concentrated-liquidity/bin AMM, program name `lb_clmm`) — **on-chain
program source is not public.** Cloned `MeteoraAg/dlmm-sdk` instead
(commit `576919e3e4368e542c402f000b4264724f7f23ec`, 2026-09-03) — this is a client
SDK/CLI repo only (`cli/`, `commons/`, `ts-client/`, `python-client/`; no `programs/`
directory). Evidence gathered indirectly:
- `commons/src/token_2022.rs` (commit `3af605049f08134784fd6a510021a94b1063e3fe`,
  2025-08-02) actively computes and forwards `TransferHookX` / `TransferHookY` /
  `TransferHookReward` extra-account-metas for liquidity actions using the official
  `spl_transfer_hook_interface::offchain::add_extra_account_metas_for_execute` helper —
  i.e. DLMM's client is built to submit *working* transfer-hook transactions, unlike
  Raydium/DAMM v2's clients.
- IDL `idls/dlmm.json` (`metadata.version` = `0.12.0`) defines `AccountsType` enum with
  `TransferHookX`, `TransferHookY`, `TransferHookReward`, `TransferHookMultiReward(u8)`,
  `TransferHookReferral`, and a `TokenBadge` account type (mint + padding) — confirming
  the on-chain program has a badge-gated TransferHook path with proper remaining-account
  slots, distinct per token side. Error codes in the IDL corroborate this:
  `6077 MissingRemainingAccountForTransferHook`, `6078 NoTransferHookProgram`,
  `6090 InvalidTokenBadgeType`, `6091 InvalidTransferHookAuthority`.
  **Confidence: Medium** (inferred from IDL + SDK code, not the raw program source,
  since the program itself is closed-source).

---

## 5. Pump.fun / PumpSwap — pump-fun/pump-public-docs

Program source is **not public** (task instruction: skip if closed — only IDL +
docs/examples are public via `pump-fun/pump-public-docs`,
commit `81091419e4457566469d4e2a27f64ed84d42419c`, 2026-09-14).

- `docs/instructions/BUY.md` / `SELL.md` (commit `91db6800e55bf341696564bd30a08ed4e3fc7491`,
  2026-05-07), lines ~80/132: example code explicitly passes
  `tokenProgram: TOKEN_2022_PROGRAM_ID` — confirms PumpSwap's buy/sell instructions
  accept Token-2022 mints (both base/meme and quote side) at the account-schema level.
- `idl/pump_amm.json` instruction list includes `buy`, `sell`, `create_pool`,
  `create_config`, `collect_coin_creator_fee`, etc. — no per-extension allow/deny logic
  is visible because **only the IDL is public, not the program source**, so we cannot
  verify from code which specific extensions (fee, hook, non-transferable, etc.) are
  accepted vs. rejected on-chain. **Extension-level behavior: UNVERIFIED** (source
  closed). Token-2022-at-the-program-ID level: **Confirmed, Medium confidence** (IDL/docs
  are official but not the deployed bytecode).

---

## 6. Jupiter — jup-ag/space-station (docs.jup.ag source, public repo)

Repo HEAD: `956fe0536bc43d40f96757deb01edbe7381a2f4c` (2026-09-28, same day — actively
maintained).

- `trigger/v1/best-practices.mdx` line 16 (older Trigger v1 API): *"Token2022 tokens
  with transfer tax extension are disabled. Our frontend informs the user if the token
  has transfer tax."* — i.e. Jupiter's Trigger (limit order) v1 API explicitly disables
  TransferFeeConfig mints.
- `trigger/best-practices.mdx` (current v2 API) line 4 front-matter says it covers
  "Token-2022 restrictions" generally but the body text wasn't more specific than the
  llmsDescription in what was grepped — treat the specific per-extension list as
  **Medium confidence / partially unverified** beyond the transfer-tax restriction
  (only the frontmatter summary was matched; full instruction-level allow/deny wasn't
  found as code, this is docs not program source since Jupiter's routing program/Metis
  aggregator on-chain source is closed).
- `recurring/best-practices.mdx` line 16 (marked "UNMAINTAINED" in its own
  llmsDescription): *"The Recurring API does not currently support Token-2022 mints."*
- `swap/v1/add-fees-to-swap.mdx` lines 38-41, 64: Metis Swap API v1 **does** support
  taking integrator fees in Token2022 tokens as of the documented "October 2025"
  changelog, requiring `instructionVersion=V2` in the swap-instructions call.
- `ultra/fees.mdx` line 20, `ultra/add-fees-to-ultra.mdx` line 77: Jupiter Ultra
  explicitly states **"SPL and Token2022 tokens"** are supported for both swap and fee
  collection.
- `swap/v1/common-errors.mdx` line 35: error 6014 `IncorrectTokenProgramID` — "Likely
  attempted to take platform fees on a Token2022 token" (an older failure mode, now
  addressed by `instructionVersion=V2`).

Jupiter's own routing program source is closed; this is docs-repo evidence (official,
current), not on-chain code — **Confidence: Medium** for the specifics above (source:
public docs repo maintained by Jupiter, not verifiable against deployed bytecode).
Since Jupiter routes through Orca/Raydium/Meteora/PumpSwap etc., its *effective*
Token-2022 extension support for a given route is bounded by whichever underlying venue
the router selects (see rows 1-5 above) — a hook-bearing mint that Raydium/DAMM v2 can't
swap will simply not route through those venues, but could route through Orca or DLMM if
liquidity exists there.

---

## 7. Kamino klend — Kamino-Finance/klend

Repo HEAD: `a08760976f51a3a58c4a0c6ea27b4a0e565bca79` (2026-08-18)
File: `programs/klend/src/utils/constraints.rs`, `mod token_2022` (lines 28-213)
Commit for this file: `4fb7a098d5b36213163a32cd677bb104a2975399` (2026-02-26)

`SUPPORTED_LIQUIDITY_MINT_TOKEN_EXTENSIONS` (lines 42-54) — reserve liquidity mint
(deposited assets) allowlist:
`ConfidentialTransferFeeConfig`, `ConfidentialTransferMint`, `MintCloseAuthority`,
`MetadataPointer`, `PermanentDelegate`, `TransferFeeConfig`, `TokenMetadata`,
`TransferHook`, `DefaultAccountState`, `ScaledUiAmount`, `Pausable`.
Anything not in this list (notably **`InterestBearingConfig` and `NonTransferable` are
absent** — neither appears anywhere in the file) → rejected with
`LendingError::UnsupportedTokenExtension` (line 100).

Extra per-extension runtime constraints (`check_only_supported_extensions_on_liquidity_mint`,
lines 83-162):
- `TransferFeeConfig`: **must currently be 0 bps** (both `older_transfer_fee` and
  `newer_transfer_fee`), lines 103-115 — i.e. the extension may exist but an active
  nonzero fee is rejected at the point of the check (fee could theoretically be raised
  later without re-check, since this is validated only at reserve-interacting
  instructions, not continuously).
- `TransferHook`: **must have no active `program_id`** (line 116-127) — same
  "present-but-inert-only" pattern as Meteora DAMM v2; an active hook program on a
  reserve's liquidity mint is rejected.
- `PermanentDelegate`: **allowed unconditionally**, no extra check (falls through the
  `match` to `_ => {}` at line 158) — notable since PermanentDelegate lets an authority
  seize/burn any holder's tokens; Kamino accepts this extension type on reserve
  liquidity mints without further gating.
- `ConfidentialTransferMint`: allowed only if `auto_approve_new_accounts == false`
  (lines 129-138).
- `DefaultAccountState`: allowed only if state is `Initialized` or `Frozen`
  (lines 139-149).
- `Pausable`: allowed only if not currently paused (lines 150-157).

Token-account-side allowlist `SUPPORTED_LIQUIDITY_ACCOUNT_TOKEN_EXTENSIONS`
(lines 59-66): `ConfidentialTransferFeeAmount`, `ConfidentialTransferAccount`,
`TransferFeeAmount`, `TransferHookAccount`, `PausableAccount`, `ImmutableOwner`.

Called from `handler_init_reserve.rs` line 65 at reserve creation — this is an
admin/permissioned action (Kamino reserves are created by market admins, not
permissionless users), so this allowlist gates what Kamino's own team can onboard as
collateral/liquidity, not an open permissionless filter. **Confidence: High**
(direct source, exact lines).

---

## 8. marginfi v2 — mrgnlabs/marginfi-v2

Repo HEAD: `35b5c66aa6897c43e7199bd6c598134041e89f99` (2026-09-16)

**No extension allowlist exists in the program.** Grepped the whole
`programs/marginfi/src` tree for `SUPPORTED`/`UnsupportedMint`/`banned` patterns tied to
Token-2022 — none found. Bank creation
(`programs/marginfi/src/instructions/marginfi_group/add_pool.rs`, commit
`1dc4ccb7e85a0e1cbbe832ce6f773d0f8a67cdb4`, 2026-07-09) is **admin-only**
(`has_one = admin`, line 107) and simply sets an `IS_T22` flag if the mint is owned by
the Token-2022 program (lines 75-77) — no per-extension check. `add_pool_permissionless.rs`
(same pattern, line 114) is likewise unguarded for extensions (it's scoped to
spl-single-pool LST mints specifically, which structurally can't carry arbitrary
extensions).

What marginfi *does* handle at the transfer layer
(`programs/marginfi/src/utils/general.rs`, commit `25a6c4c29cc4fc87daadab9f574962fb0b0327c3`,
2026-08-18):
- `calculate_pre_fee_spl_deposit_amount` / `calculate_post_fee_spl_deposit_amount` /
  `nonzero_fee` (lines 54-120): read `TransferFeeConfig` and net the current-epoch fee
  for deposit/withdraw accounting — fee-bearing mints work as banks (fee is accounted
  for, not blocked).
- `has_transfer_hook()` (lines 122-138): detects an *active* transfer hook program on a
  mint.
- Deposit/withdraw CPI (`programs/marginfi/src/state/bank.rs`, same commit as
  `general.rs`, lines 1279 and 1359): uses
  **`spl_token_2022::onchain::invoke_transfer_checked`**, the canonical SPL helper that
  auto-resolves and forwards `ExtraAccountMetaList` accounts for an active transfer hook
  from the accounts already present in `remaining_accounts` — this is genuine functional
  TransferHook support at the CPI layer (contrast with Raydium/DAMM v2 above, which use
  raw `transfer_checked` with no hook resolution).

**Conclusion**: marginfi has no extension allowlist — it is a fully admin-trust model
(bank creation is gated by group admin, not a program-level extension filter), but its
transfer plumbing is more hook-capable than Raydium's/Meteora's because it uses the
official on-chain hook-resolving helper rather than a bare `transfer_checked`.
**Confidence: High** (direct source, exact lines) for what's implemented;
**Medium** for "no allowlist exists" (an absence claim — grep-based, could theoretically
be enforced off-chain by the marginfi UI/backend, which is closed-source and not
checked here).

---

## Wallets

### Backpack — coral-xyz/backpack

Repo HEAD: `5a538a41d060d2c48507007f96c766483115aecc`, dated **2024-02-14** — i.e. the
public monorepo has not been pushed to in ~2.5 years relative to "today" (2026-09-28).
This predates almost all mainnet Token-2022 extension adoption (transfer hook,
permanent delegate, scaled UI amount, pausable, etc. mostly rolled out through
2024-2025). The only Token-2022 reference found repo-wide is the bare program-ID
constant `TOKEN_2022_PROGRAM_ID`
(`packages/secure-clients/src/SolanaClient/solanaLegacy/programs/token.ts` line 27) —
**no extension-specific parsing, display, or warning logic exists in this snapshot.**

**Conclusion: the live Backpack app's Token-2022 extension handling (transfer-fee
display, hook warnings, non-transferable badges, scaled-UI/interest display, metadata
extension rendering) is UNVERIFIED from source** — either the public repo is stale
relative to what ships in production (most likely, given a Feb-2024 last-commit date on
an actively-marketed wallet) or that logic lives in a closed component not in this
monorepo. Do not cite this repo as evidence of current Backpack behavior; only that as
of Feb 2024 the OSS snapshot had bare Token-2022 program support and no visible
extension-aware UI code. **Confidence: Low / UNVERIFIED** for actual current behavior.

### Solflare, Phantom

No public source. Not checked further per task scope (closed, blocked doc sites).
**UNVERIFIED.**

---

## Explorers / Indexers

### Solana Explorer — solana-foundation/explorer

Repo HEAD: `0a81d139e3aaa5316d6a19a138d96c383ca132fe` (2026-09-28, same day — actively
maintained).

File: `app/validators/accounts/token-extension.ts`
Commit: `e1e5850c7c57968da264fe68949692c6619bae53` (2026-09-15)

`ExtensionType` enum (lines 5-32) enumerates and type-validates essentially every known
Token-2022 mint/account extension for display: `transferFeeConfig`, `transferFeeAmount`,
`mintCloseAuthority`, `confidentialTransferMint`, `confidentialTransferAccount`,
`defaultAccountState`, `immutableOwner`, `memoTransfer`, `nonTransferable`,
`interestBearingConfig`, `cpiGuard`, `pausableAccount`, `permanentDelegate`,
`nonTransferableAccount`, `confidentialTransferFeeConfig`,
`confidentialTransferFeeAmount`, `transferHook`, `transferHookAccount`,
`metadataPointer`, `tokenMetadata`, `groupPointer`, `groupMemberPointer`, `tokenGroup`,
`tokenGroupMember`, `scaledUiAmountConfig`, `pausableConfig`, `permissionedBurnConfig`,
plus a catch-all `unparseableExtension` for anything not yet modeled (line 31) — so an
extension the Explorer doesn't recognize still renders (as "unparseable"), it doesn't
crash the page. Full per-extension typed schemas (`TransferFeeConfig`,
`PermanentDelegate`, `TransferHook`, `ConfidentialTransferMint`, `GroupPointer`, etc.)
follow in the same file (lines 44-168+). UI rendering of specific extensions (e.g.
`permanentDelegate` case) lives in
`app/components/account/TokenAccountSection.tsx` lines 539, 894-895.
**Confidence: High** (direct source, exact lines, same-day commit).

### Helius DAS API

Helius's DAS implementation itself is not open source, but DAS is a
Metaplex-coordinated multi-provider spec: `metaplex-foundation/digital-asset-standard-api`
(commit `977d6bc7771891a28d891c5e12a4b1e5a6c94dc8`, 2026-08-26).
`specification/metaplex-das-api.json`, `getTokenAccounts` method,
`token_accounts[].extensions` field (line ~6031): schema is `{"default": null}` —
i.e. the DAS spec **exposes a generic/untyped `extensions` passthrough field** on token
accounts rather than per-extension typed schemas the way solana-foundation/explorer
does. This means DAS-conformant providers (including Helius) can surface raw
Token-2022 extension state, but the spec itself does not standardize field names per
extension type (no dedicated `transferFeeConfig`/`transferHook`/etc. schema entries were
found — grepped the whole spec file). **Confidence: Medium** (spec-level evidence;
Helius's actual DAS response shape wasn't independently verified against a live call in
this pass — would require a follow-up `heliusAsset`/`heliusChain` call against a known
Token-2022 mint).

---

## Summary Gotchas (cross-venue)

1. **Badge coarseness differs by venue.** Orca re-validates per-extension even with a
   TokenBadge (only specific extensions get the badge escape hatch; NonTransferable is
   never allowed). Raydium (`SupportMintAssociated`) and Meteora DAMM v2 (`TokenBadge`)
   both let a badge bypass *all* further extension checks once created — so an admin
   badge on either of those two venues nominally "allows" any extension combination,
   even ones the program can't actually execute (see #2).
2. **"Allowed by badge" ≠ "functionally works."** Raydium CP-Swap, Raydium CLMM, and
   Meteora DAMM v2 all lack any on-chain extra-account-metas resolution/forwarding for
   TransferHook (confirmed by full-repo grep returning zero `TransferHook` hits or hook
   forwarding code in each swap path). A hook-enabled mint would fail at the
   `transfer_checked` CPI regardless of badge status. Only **Orca** (via `AccountsType::
   TransferHookA/B` in SwapV2) and **marginfi** (via `spl_token_2022::onchain::
   invoke_transfer_checked`, which auto-resolves hook accounts) have source-confirmed
   *functioning* hook support. DLMM (lb_clmm) shows strong SDK/IDL evidence of the same
   (Medium confidence, source closed).
3. **Fee-on-transfer accounting is pervasive and consistent**: every AMM checked
   (Orca, Raydium CP-Swap/CLMM, Meteora DAMM v2) independently reimplements the same
   pattern — read `TransferFeeConfig.get_epoch_fee`/`calculate_epoch_fee`/
   `calculate_inverse_epoch_fee` to convert between pre-fee and post-fee amounts for
   both exact-in and exact-out swap math. None of them fetch the fee from a cached/stale
   source; all read the live mint account each time.
4. **Lending is stricter about *active* extensions than AMMs are about their presence.**
   Kamino requires TransferFeeConfig to currently be 0 bps and TransferHook to have no
   active program — i.e. these extensions may exist on the mint but must be dormant.
   Kamino explicitly allows `PermanentDelegate` unconditionally on reserve liquidity
   mints, which is a meaningfully different risk posture than most AMMs (which either
   reject it outright without a badge, or don't check it at all like marginfi).
5. **Jupiter's Token-2022 fee-taking is a relatively recent (per its own changelog,
   "October 2025") addition** requiring `instructionVersion=V2`; older integrations
   using the default instruction version would hit `IncorrectTokenProgramID` (error
   6014) when trying to take a platform fee in a Token2022 mint.
6. **Backpack's OSS repo is stale (last commit 2024-02-14)** and should not be cited as
   evidence of the current production wallet's Token-2022 extension UI — that logic is
   either undocumented in the public repo or lives elsewhere closed-source.

---

## Repos cloned (paths under this scratch dir's `repos/`)

| Repo | Local dir | HEAD commit | HEAD date |
|---|---|---|---|
| orca-so/whirlpools | whirlpools | 408c945f | 2026-09-03 |
| raydium-io/raydium-cp-swap | raydium-cp-swap | 59fb845a | 2026-09-10 |
| raydium-io/raydium-clmm | raydium-clmm | ed7c84a5 | 2026-08-19 |
| MeteoraAg/cp-amm (= damm-v2) | cp-amm, damm-v2 | a85c9266 | 2026-09-08 |
| MeteoraAg/dlmm-sdk | dlmm-sdk | 576919e3 | 2026-09-03 |
| Kamino-Finance/klend | klend | a0876097 | 2026-08-18 |
| mrgnlabs/marginfi-v2 | marginfi-v2 | 35b5c66a | 2026-09-16 |
| coral-xyz/backpack | backpack | 5a538a41 | 2024-02-14 |
| solana-foundation/explorer | explorer | 0a81d139 | 2026-09-28 |
| jup-ag/token-list | jup-token-list | 9e0ce971 | 2025-04-21 (unused, no relevant content) |
| jup-ag/space-station | jup-space-station | 956fe053 | 2026-09-28 |
| pump-fun/pump-public-docs | pump-public-docs | 81091419 | 2026-09-14 |
| metaplex-foundation/digital-asset-standard-api | das-api | 977d6bc7 | 2026-08-26 |
