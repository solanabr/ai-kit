# Token-2022 Gap-Closure Notes — 2026-09-28 (session 2)

Builds on `/tmp/.../ext-state/token2022-notes.md` (read first, not duplicated here).
Network: solana.com, mcp.solana.com, all public Solana RPCs (publicnode, ankr,
drpc), solscan.io, explorer.solana.com, public-api.solscan.io — ALL blocked
(403 CONNECT tunnel refused, confirmed via proxy status log). github.com HTML/API
now ALSO blocked for any repo other than solanabr/ai-kit ("GitHub access to this
repository is not enabled for this session"). raw.githubusercontent.com,
static.crates.io, npm registry, WebSearch continued to work.

## 1. Token-2022 mainnet upgrade authority / deployed version — STILL UNVERIFIED

- Could not reach any RPC (public or Helius-proxied) or any block explorer this
  session. `mcp__github__get_release_by_tag` / `issue_read` / `list_releases`
  all refused with "repository not configured for this session" (session-level
  allowlist limited to solanabr/ai-kit) — a NEW restriction vs. the prior
  session, which had used `mcp__github__search_code`/`search_issues` freely.
  `search_code`/`search_issues` (cross-repo search) still worked; per-repo
  content/metadata tools did not.
- Confirmed only: program crate `spl-token-2022` on `master` HEAD (commit
  fetched live via raw.githubusercontent.com, 2026-09-28) is at version 11.1.0,
  matching crates.io's published 11.1.0 (2026-09-23) — so the crate source in
  the local clone is current mainline, but this does NOT by itself prove what
  bytecode is deployed on mainnet-beta at that program ID.
- WebSearch found no primary statement of who holds Token-2022's current
  upgrade authority (single key / multisig / Squads). One Solana Foundation
  reference program (Subscriptions & Allowances) is confirmed Squads-multisig
  controlled, but nothing ties that pattern to Token-2022 itself.
  **UNVERIFIED — recommend a follow-up session with RPC/explorer access,
  or Helius `heliusChain.getAccountInfo` on the ProgramData account
  derived from TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb.**
- Known (High, carried from prior session): the program is upgradeable, not
  immutable, per the Solana Foundation's own June 2025 post-mortem text.

## 2. ZK ElGamal Proof feature-gate epochs — CONFIRMED, upgraded to High confidence

Primary source: `LiteSVM/litesvm` repo, `crates/litesvm/src/features.rs`
(commit `1b59ae0538b9531dd9e389d87ca1272686d27f6f`, fetched via
raw.githubusercontent.com 2026-09-28). LiteSVM hardcodes real mainnet-beta
activation slots for each feature ID so that local test validators replay
history accurately — this is the same table Anza/community fuzzing and
simulation tools use, and it agrees exactly with the WebSearch-synthesized
post-mortem numbers from the prior session:

| Feature | Feature ID (pubkey) | Mainnet activation slot | Epoch (slot/432000) |
|---|---|---|---|
| `zk_elgamal_proof_program_enabled` | (enable, 2024) | 315,792,000 | 731 |
| `disable_zk_elgamal_proof_program` | `zkdoVwnSFnSLtGJG7irJPEYUpmb4i7sGMGcnN6T9rnC` | 347,760,000 | 805.0 |
| `reenable_zk_elgamal_proof_program` | `zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN` | 424,224,000 | 982.0 |

Feature ID pubkeys corroborated independently in `firedancer-io/firedancer`
`src/flamenco/features/feature_map.json` and `fd_features_generated.c`
(both fetched via `mcp__github__search_code`, which still works cross-repo).
Confidence: **High** (2 independent primary/tooling sources agree exactly on
slot numbers and pubkeys; still not a literal read of the Agave
`feature-gate-tracker` GitHub issue itself, which could not be reached this
session — semantic `search_issues` against `anza-xyz/agave` and an attempted
`anza-xyz/feature-gate-tracker` repo search both failed to surface the
specific issues by exact title).

Also confirmed via source: `anza-xyz/mollusk` `harness/src/feature_set.rs` and
`solana-foundation/surfpool` `crates/types/src/features.rs` both list
`disable_zk_elgamal_proof_program` / `reenable_zk_elgamal_proof_program` as
live, implemented feature-set fields (High — corroborates the gate exists and
is finalized in the current Agave feature set, code search 2026-09-28).

## 3. Exact instruction APIs — extensions 24–28 (read directly, High confidence)

Source: `interface/src/extension/{pausable,permissioned_burn,scaled_ui_amount,
confidential_mint_burn}/instruction.rs` in local clone
(commit `28a131de9e25e292f7a5f6c164498d90d4b38359`), full files read verbatim.

**Pausable** (`TokenInstruction::PausableExtension`):
- `Initialize` — 1 account (mint, writable), data `{authority: Address}`. Must run
  before `InitializeMint`.
- `Pause` / `Resume` — 2 accounts (mint writable, pause authority signer or
  multisig owner + M signers). Sets/clears `paused` bool on `PausableConfig`.

**PermissionedBurn** (`TokenInstruction::PermissionedBurnExtension`):
- `Initialize` — 1 account (mint), data `{authority: Address}`. Must run before
  `InitializeMint`.
- `Burn` / `BurnChecked` — accounts: source (writable), mint (writable),
  permissioned-burn-authority (signer), owner/delegate (signer, or multisig
  owner + M signers). Data: amount (+decimals for Checked).
- `ConfidentialBurn` — burns from the confidential balance; accounts include
  optional instructions-sysvar + up to 3 pre-verified ZK proof context-state
  accounts, plus the permissioned-burn authority signer and owner signer.

**Enforcement (processor.rs, read directly, lines ~1120-1300 of
`program/src/processor.rs`, `process_burn`)**:
- The processor branches on `BurnInstructionVariant::{Standard, Permissioned}`.
- If the mint has `PermissionedBurnConfig` with `authority: Some(_)`, the
  **standard `Burn`/`BurnChecked` instruction is rejected** with
  `TokenError::InvalidInstruction` — callers MUST use the dedicated
  permissioned-burn instruction variant instead (same discriminant byte
  space, different instruction enum: `PermissionedBurnExtension::Burn` /
  `BurnChecked`), which additionally requires the configured permissioned-burn
  authority as an extra signer account distinct from the token owner/delegate.
- If the mint has the extension but the config's `authority` is `None`, the
  permissioned variant also fails (`InvalidInstruction`, "use the standard
  burn" — msg!).
- **Answer to the specific question**: yes, there is a dedicated permissioned
  burn instruction; regular `Burn`/`BurnChecked` errors out with
  `TokenError::InvalidInstruction` once the extension (with an authority set)
  is initialized on the mint, and the extra required signer is the
  permissioned-burn authority account (account index 2 in the accounts list),
  on top of the normal owner/delegate signer.

**ScaledUiAmount** (`TokenInstruction::ScaledUiAmountExtension`):
- `Initialize` — 1 account (mint), data `{authority: MaybeNull<Address>,
  multiplier: f64}`. Must run before `InitializeMint`. Fails if multiplier
  <= 0 or subnormal.
- `UpdateMultiplier` — mint + authority (or multisig), data
  `{multiplier: f64, effective_timestamp: i64}`. If timestamp is in the past,
  takes effect immediately; otherwise scheduled.
- Mutually exclusive with `InterestBearingConfig` at the mint-combination
  check level (confirmed in prior session's notes, `check_for_invalid_mint_extension_combinations`).

**ConfidentialMintBurn** (`TokenInstruction::ConfidentialMintBurnExtension`):
- `InitializeMint` — 1 account (mint), data `{supply_elgamal_pubkey,
  decryptable_supply}`. MUST be in the same transaction as
  `TokenInstruction::InitializeMint`, else another party could front-run
  the initialization.
- `RotateSupplyElGamalPubkey`, `UpdateDecryptableSupply`, `Mint`, `Burn`
  (all ZK-proof-gated, with instructions-sysvar + up to 3 context-state
  accounts for equality/validity/range proofs), `ApplyPendingBurn`.
- Requires `ConfidentialTransferMint` extension present (mint-combination
  check, prior session).
- **Cross-extension interaction confirmed in processor.rs**: standard
  `MintTo`/`Burn` (process_mint_to at ~line 1083, process_burn at ~line 1215)
  both explicitly reject the mint (`TokenError::IllegalMintBurnConversion`)
  if `ConfidentialMintBurn` extension is present — i.e. once a mint has
  confidential mint/burn enabled, the plain SPL `MintTo`/`Burn` paths are
  permanently disabled for it; only the confidential Mint/Burn instructions
  work.

## 4. Other account-level extension rules confirmed directly in processor.rs

(Read `process_transfer` ~lines 360-460, `process_mint_to`/`process_burn`
~lines 1050-1300, and grepped the whole file — all High confidence, primary
source.)

- **NonTransferable**: a source account with `NonTransferableAccount` marker
  fails any transfer with `TokenError::NonTransferable` before amount checks.
  `MintTo` to a non-transferable mint requires the destination account to have
  BOTH `ImmutableOwner` AND `NonTransferableAccount`, else
  `TokenError::NonTransferableNeedsImmutableOwnership`.
- **MintRequiredForTransfer**: when a transfer instruction omits the mint
  account (legacy `Transfer` without mint), the processor still checks the
  source account's extensions; if it carries `TransferHookAccount`,
  `TransferFeeAmount`, or `PausableAccount` markers, the transfer is rejected
  with `TokenError::MintRequiredForTransfer` — callers must use
  `TransferChecked`/`TransferCheckedWithFee` and supply the mint so the
  processor can evaluate hook/fee/pause state.
- **Pausable**: checked in `process_transfer`, `process_mint_to`, and
  `process_burn` — if `PausableConfig.paused == true`, all three fail with
  `TokenError::MintPaused`. (Confirms Pause halts mint+burn+transfer, not
  just transfer, as the doc comment states.)
- **CpiGuard**: when `lock_cpi` is set AND the call is happening inside a CPI
  (`in_cpi()`), and the signing authority equals the account owner (covers
  both plain-owner and permanent-delegate-as-owner cases), blocks Transfer
  (`CpiGuardTransferBlocked`), Approve (`CpiGuardApproveBlocked`), SetAuthority
  on owner/close-authority (`CpiGuardSetAuthorityBlocked` /
  `CpiGuardOwnerChangeBlocked`), Burn (`CpiGuardBurnBlocked`), and
  CloseAccount (`CpiGuardCloseAccountBlocked`).

## 5. SDK support matrix for extensions 24–28

| Package (version) | Pausable (26/27) | PermissionedBurn (28) | ScaledUiAmount (25) | ConfidentialMintBurn (24) | Source |
|---|---|---|---|---|---|
| `@solana-program/token-2022` 0.19.0 (Kit/Codama-generated JS) | Full — `initializePausableConfig`, `pause`, `resume` | Full — `initializePermissionedBurn`, `permissionedBurn`, `permissionedBurnChecked`, `permissionedConfidentialBurn` | Full — `initializeScaledUiAmountMint`, `updateMultiplierScaledUiMint` | Full — `initializeConfidentialMintBurn`, `confidentialMint`, `confidentialBurn`, `rotateSupplyElgamalPubkey`, `updateConfidentialMintBurnDecryptableSupply`, `applyConfidentialPendingBurn` | `.d.ts` files listed directly in unpacked npm tarball, 2026-09-28 |
| `@solana/spl-token` 0.4.15 (legacy web3.js) | Full — `src/extensions/pausable/{actions,instructions,state}.ts` | Full — `src/extensions/permissionedBurn/{instructions,state}.ts` | Full — `src/extensions/scaledUiAmount/{actions,instructions,state}.ts` | **Not implemented** — `ExtensionType` enum has it commented out (`// ConfidentialMintBurn, // Not implemented yet`), value 24 skipped, no `confidentialMintBurn` extension folder | Unpacked npm tarball source, 2026-09-28 |
| spl-token CLI (`clients/cli`, token-2022 repo master) | Full — `--enable-pause`, `pause`/`resume` subcommands, `--pause-authority` | Full — `--enable-permissioned-burn`, `--permissioned-burn <authority>`, `authorize permissioned-burn`, `--permissioned-burn-authority` on burn | Full — `--ui-amount-multiplier`, `update-ui-amount-multiplier` subcommand, `--ui-multiplier-authority` | Partial — `--enable-confidential-mint-burn` flag exists at mint creation; no dedicated confidential-mint/burn subcommands found in this grep (not fully verified) | `clap_app.rs` fetched via raw.githubusercontent.com, grepped directly |
| anchor-spl 1.2.0 (`spl/src/token_2022_extensions/`) | Partial — CPI wrapper `pausable.rs` (`pausable_initialize`, `pausable_pause`, `pausable_resume`) + `extensions::pausable::authority` account constraint in `lang/syn` | **None** — no `permissioned_burn.rs` module, no `extensions::permissioned_burn` constraint | **None** — no `scaled_ui_amount.rs` module, no constraint | **None** — no `confidential_mint_burn.rs` module, no constraint | Local clone (`scratchpad/anchor`, commit `bce1622`), directory listing + grep of `constraints.rs` |
| `pinocchio-token-2022` 0.4.0 | Full — `instructions/extensions/pausable/{initialize,pause,resume}.rs`, state `pausable.rs`/`pausable_account.rs` | Full — `instructions/extensions/permissioned_burn/{initialize,burn,burn_checked}.rs`, state `permissioned_burn.rs` | Full — `instructions/extensions/scaled_ui_amount/{initialize,update_multiplier}.rs` | **None** — no confidential_mint_burn module anywhere (also no ConfidentialTransfer support at all in this crate) | `.crate` downloaded from static.crates.io and extracted, full file tree read |

**Corrects prior session's notes**, which had (Medium confidence, WebSearch-only)
described pinocchio-token-2022 as providing "core instructions only, without
extension-specific CPI builders" — that is now confirmed FALSE for
Pausable/PermissionedBurn/ScaledUiAmount (all present with dedicated modules);
only ConfidentialMintBurn (and confidential transfers generally) is absent.

## 6. 2026 issues/PRs of note

- **PR #1508**, `solana-program/token-2022`, "SlotReferenceFee: per-slot
  escalating in-kind fee mint extension" by community contributor
  `staccDOTsol`. **Status: Open, not merged** (per WebSearch synthesis of the
  PR page, could not fetch the PR directly — github.com blocked this session).
  Would add a new mint extension (implicitly #29) with a per-slot reference
  counter; the n-th transfer in a slot pays `floor_basis_points * n^2` bps,
  capped at `cap_basis_points`, first `free_references` free. Design doc
  referenced as `proposals/slot-reference-fee.md` in the PR branch, but that
  path does NOT exist on `main` (404 via raw.githubusercontent.com) — i.e. not
  yet merged into mainline docs. **Medium confidence** (single WebSearch
  synthesis, not independently read).
- No other 2026 extension-proposal PRs/issues were surfaced this session;
  `mcp__github__search_code`/`search_issues` cross-repo tools work but a full,
  systematic PR sweep of `solana-program/token-2022` issues/PRs list could not
  be done because `list_issues`/`list_pull_requests`-style per-repo browsing
  requires repo access this session does not have. **Flag as an incomplete
  sweep — recommend a follow-up with either restored github.com access or the
  solana-dev MCP.**
- Did not find any 2026 deprecation notices or JS-client breaking-change
  announcements (e.g. "wallet-only confidential key derivation") this session;
  UNVERIFIED, not contradicted either — simply not found in available sources.

## Sources added this session

- https://raw.githubusercontent.com/solana-program/token-2022/master/program/Cargo.toml (11.1.0 confirmed on master HEAD, 2026-09-28)
- https://raw.githubusercontent.com/solana-program/token-2022/master/clients/cli/src/clap_app.rs (full CLI flag surface for extensions 25-28, 2026-09-28)
- Local clone `/home/user/solana-program/token-2022`, `program/src/processor.rs` (process_transfer, process_mint_to, process_burn — read directly)
- Local clone `interface/src/extension/{pausable,permissioned_burn,scaled_ui_amount,confidential_mint_burn}/instruction.rs` (read in full)
- https://raw.githubusercontent.com/LiteSVM/litesvm/1b59ae0538b9531dd9e389d87ca1272686d27f6f/crates/litesvm/src/features.rs (ZK ElGamal feature-gate slots)
- GitHub code search (cross-repo, via `mcp__github__search_code`) hits in: `firedancer-io/firedancer` (`feature_map.json`, `fd_features_generated.c`), `anza-xyz/mollusk` (`harness/src/feature_set.rs`), `solana-foundation/surfpool` (`crates/types/features.rs`), `jito-foundation/jito-solana`, `Syndica/sig`
- npm tarballs unpacked locally: `@solana-program/token-2022@0.19.0`, `@solana/spl-token@0.4.15` (dist/.d.ts and src/ read directly)
- `static.crates.io/crates/pinocchio-token-2022/pinocchio-token-2022-0.4.0.crate` (downloaded and extracted, full source tree read)
- Local clone `/tmp/.../scratchpad/anchor` (Anchor master, commit bce1622349d2303483e990548f424c79e510b5f1, 2026-09-28) — `spl/src/token_2022_extensions/`, `lang/syn/src/parser/accounts/constraints.rs`
- WebSearch synthesis (Medium/Low, not independently fetched): PR #1508 status/description; general "Token-2022 upgrade authority" queries (no primary source found)

## Remaining UNVERIFIED (carried + new)

1. Token-2022 mainnet program's current upgrade authority (key/multisig identity) — no RPC/explorer access this session.
2. Whether the mainnet-deployed bytecode is actually v11.1.0 (or which version) — only the git source is confirmed at that version; no on-chain confirmation.
3. PR #1508 (SlotReferenceFee) exact current review status/comments — WebSearch synthesis only, github.com directly blocked.
4. spl-token CLI's confidential-mint-burn subcommand surface beyond the `--enable-confidential-mint-burn` creation flag — not fully grepped.
5. Whether any *other* 2026 PRs propose new ExtensionType variants — sweep incomplete (no repo-scoped issue/PR listing access this session).
6. Any 2026 client-breaking-change announcements (e.g. wallet-only confidential key derivation) — not found, not ruled out.
