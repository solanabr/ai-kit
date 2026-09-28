# Token-2022 security research — full notes

Read first: existing coverage in
- .claude/skills/ext/solana-dev/skills/solana-dev/references/security.md lines ~413-624
  (transfer fee accounting, calculate_fee vs calculate_inverse_fee rounding, permanent
  delegate, mint close+reinit, account closure conditions/.closable(), transfer vs
  transfer_checked, transfer hook 3-check list (mint/transferring/ownership),
  metadata spoofing bidirectional check, memo transfer, dynamic rent, audit checklist,
  remaining_accounts, self-reentrancy A->A, log injection, slot/epoch boundary, TOCTOU,
  pool squatting, donation attacks, randomness, rounding direction, unchecked casts).
  Source cited: @0xcastle_chain X thread — community, not audit-firm-sourced.
- trailofbits token-integration-analyzer: EVM/ERC20-only (Slither, ERC777, weird-token
  DB). Zero Solana/Token-2022 content — nothing to dedupe against beyond general
  "integration safety" framing (balance-delta accounting, allowlists) which the Solana
  file already covers in Solana-specific terms.

## 1. Incidents (2023-2026)

### ZK ElGamal Proof Program bug #1 (April 2025) — soundness, no known exploit
- Reported April 16 2025 by researcher "LonelySloth" via Anza GitHub Security Advisory,
  PoC included. Root cause: on-chain ZK ElGamal Proof program omitted some algebraic
  components from the Fiat-Shamir transcript hash, letting a prover forge proofs the
  program would accept as valid (arbitrary proof construction).
- Timeline: Apr 17 ~18:00 UTC Solana Foundation/Jito began contacting validators;
  ~23:00 UTC same day a second, related issue found needing a second patch; by Apr 18
  ~20:00 UTC supermajority stake adopted patch; announced publicly 21:01 UTC.
  Only Token-2022 Confidential Transfer used the affected ElGamal functionality.
  No known exploit / no funds lost.
  Source: solana.com/news/post-mortem-may-2-2025 (blocked by proxy here, so summarized
  via search snippets only — MEDIUM confidence, corroborated by coindesk.com/.../2025/05/05,
  decrypt.co/317894, cryptonews.com — community press, not primary re-read).

### ZK ElGamal Proof Program bug #2 (June 2025) — Fiat-Shamir "phantom challenge", led to full disable
- Root cause: a prover-generated "challenge" value (part of a sigma OR-proof) was not
  absorbed into the transcript — a phantom-challenge / Fiat-Shamir soundness bug.
  Allowed forging a sigma OR proof to bypass fee validation in confidential transfers;
  attacker could manipulate encrypted fee amounts to arbitrarily mint/burn without
  revealing the real transfer value (per WebSearch summary of
  blog.zksecurity.xyz/posts/solana-phantom-challenge-bug/, ZK/SEC Quarterly — could not
  WebFetch directly, egress blocked; MEDIUM confidence, single source type).
- Because this was the second ZK ElGamal issue in two months, Solana disabled
  confidential transfers entirely rather than hot-patch again: disable-gate activated
  June 19 2025 at start of mainnet-beta epoch 805 (ZK ElGamal Proof program disabled via
  feature activation). Re-enable gate activated June 4 2026, epoch 982; Token-2022
  redeployed with confidential instructions restored later that month.
  Source: solana.com/news/post-mortem-june-25-2025 (blocked here, summarized via
  WebSearch snippet — HIGH confidence on dates since corroborated independently by
  github.com/solana-program/token-2022 issue #657, which is directly readable and
  confirms CT/CTFee/ConfidentialMint/ConfidentialBurn were disabled pending audit).
  No $ impact reported — bug was caught/disclosed before exploitation (per search
  summaries); UNVERIFIED whether any funds were actually at risk on mainnet before the
  disable, treat as no-known-loss.

### Permanent Delegate "burn scam" factory (ongoing, escalated ~2024-2026)
- Mechanism: PermanentDelegate extension gives one authority the power to transfer/burn
  ANY holder's tokens with no signature from the holder — by design (compliance use
  case), abused as an automated rug vector on pump.fun-style launches.
- Sept 2024: Binance/CryptoRank/Cryptotimes reported scammers burning victims' tokens
  seconds after purchase — a Jupiter community member's swap into token "RED" was burned
  7 seconds after the swap completed. Source: cryptorank.io, binance.com/en/square (Sept
  2024) — MEDIUM, press coverage not a post-mortem.
- By March 2026 this had scaled into what one write-up (dev.to, "ohmygod") calls "2026's
  largest automated rug pull factory," with RugCheck.xyz reportedly flagging over 40% of
  new Solana token launches as carrying PermanentDelegate. LOW confidence — single
  community blog source (dev.to), numbers not independently corroborated; flag as
  UNVERIFIED / LOW.
- BONKKILLER honeypot (April 29 2024, not 2025 — correcting an initial mis-date):
  freeze-authority abuse (DefaultAccountState/Freeze, not strictly PermanentDelegate)
  used to trap buyers after $4.6M in 24h volume; creator pulled $1.62M across 11
  transactions per on-chain data; market cap nominally hit $328T due to inflated/broken
  supply math. Sources: cointelegraph.com, benzinga.com, cryptonews.com (Apr-May 2024).
  MEDIUM confidence (multiple press outlets agree on the core facts and $ figures).

### Sell-blocker / honeypot transfer hooks (pattern, not single named incident found)
- General pattern reported by security/on-chain-risk writers (paragraph.com/@quantumaudit,
  onchainrisk.io, dev.to/mrwizardlyloaf "Token-2022 Traps That Drain AI Trading Agents"):
  a mutable transfer-hook program is deployed permissive at launch, then the hook
  authority upgrades the hook program post-listing to tax sells at up to 99% or block
  them outright. Could not find a single named, dated, audited incident with a specific
  $ loss figure for a *transfer-hook*-specific sell-blocker (as distinct from the
  freeze-authority-based BONKKILLER case above) — treat the "hook upgraded after
  listing" mechanism as HIGH confidence (documented by Raydium/Meteora's own hook-gating
  policy: Raydium excludes hooks entirely "no safe sandbox exists"; Meteora allows hooks
  only when hook program AND hook authority are both revoked — i.e. venues treat a live
  upgrade authority on a hook as the core risk) but the aggregate/individual dollar
  figures for hook-specific rugs as SPECULATIVE/UNVERIFIED pending a named case.

### Mint close + reinitialization, pausable abuse, metadata spoofing, CT proof bugs beyond ZK
- No standalone dated real-world *exploit* found for mint-close+reinit or pausable abuse
  specifically (beyond the ZK ElGamal items and the permanent-delegate/freeze cases
  above) — these remain, per available sources, catalogued as *risks* in audit
  checklists (Neodyme, Offside Labs — see below) rather than as named incidents with
  public post-mortems. Mark UNVERIFIED that a named mint-close-reinit or pausable-abuse
  hack has occurred publicly as of 2026-09-28; do not assert one in the skill without
  further primary-source confirmation (solana.com and public RPC are blocked in this
  research pass, which limits confirmation).

## 2. Audit checklists — new items not already in security.md / ToB skill

Neodyme (neodyme.io/en/blog/token-2022/, "Don't shoot yourself in the foot with
extensions" + neodyme.io/reports/Token%202022%20-%202024.pdf) and Offside Labs
(blog.offside.io/p/token-2022-security-best-practices-part-1 and -part-2) — both blocked
by egress proxy for direct fetch; content below reconstructed from WebSearch snippets
only, so treat specifics as MEDIUM/LOW and re-verify by reading the primary posts when
solana-adjacent domains are reachable.

Candidate NEW checks (not in the two files already read) to verify and add:
1. Neodyme audit (2024 PDF, Robert Reith lead) — explicit statement that Neodyme does
   not audit by generic checklist but builds an extension-by-extension invariant model;
   worth citing as methodology ("audit each extension combination against its own
   invariants, not a generic list") rather than line items — HIGH (primary PDF exists,
   title/author confirmed via search even though not fetched).
2. Zellic (reports.zellic.io/publications/spl-token-2022) — original Solana Foundation
   audit, Sep 19–Oct 7 2022, 7 findings (2 critical, 3 low, 1 informational), focused on
   account (de)serialization correctness, mint accounting invariants, and extension
   guarantee violations. Could not re-fetch report to list the 7 findings by name
   (egress blocked) — MEDIUM, title/date/count corroborated by search snippet only.
3. Offside Labs Part 1 (Mint & Token Account) and Part 2 (5 extensions) exist as a
   two-part series; Part 2 confirmed to cover TransferFeeConfig specifically noting fee
   is recorded in the *recipient* account's extension data and is NOT part of the
   spendable/available balance until withdrawn — this is a sharper framing than
   security.md's "fee deducted from receiver's end" and worth folding in: the withheld
   fee sits in the recipient's own account state, inaccessible until someone calls
   WithdrawWithheldTokensFromAccounts, meaning integrators must not just do delta
   accounting but must know *whose* account temporarily custodies the fee.
4. GitHub SPL token-2022 repo, issue-tracker-documented footgun: ExtraAccountMeta can be
   a PDA seeded off *another* program or off the transfer's own account data; if a
   client/integrator caches resolved extra accounts and the issuer rotates the hook
   program or edits the ExtraAccountMetaList between cache and send, resolution goes
   stale and the tx fails-closed (not a silent bypass, but a DoS/footgun) — this is a
   distinct integration risk from the "attacker-supplied fake accounts" risk already in
   security.md's transfer-hook section, and should be added as a client-side caching
   caveat.

Not independently confirmed enough to add without further reading: any Sec3-specific
"Token-2022 security" checklist (search found no distinct Sec3 Token-2022 publication —
UNVERIFIED it exists under that framing) and no Accretion- or Halborn-specific
Token-2022 checklist was found in this pass (UNVERIFIED / not found).

## 3. Risk-flag tooling

- RugCheck.xyz: public Swagger API (api.rugcheck.xyz/swagger) exposing token/wallet risk
  endpoints (GET /tokens/{id}/report, /wallet/{address}/risk); 0-100 risk score built
  from mint authority, freeze authority, holder concentration, creator history. Several
  third-party OSS wrappers exist (aethernet404/rugcheck, romankurnovskii/RugCheck-CLI,
  kukapay/rug-check-mcp) but these call RugCheck's hosted API — the core scoring engine
  itself does not appear to be open source (only client wrappers are). "RugCheck AI"
  (per dev.to summary) explicitly flags mints carrying a transfer hook as DANGER by
  reading the mint directly. MEDIUM confidence (API existence/shape corroborated by
  multiple independent OSS repos referencing it; core-engine-closed-source is inferred
  from absence of a rugcheck.xyz backend repo in results, not confirmed negative).
- Jupiter: token verification program (docs.jup.ag/user-docs/launch/vrfd/token-verification,
  verified.jup.ag) is a human/community verification list (ticker collisions, market cap
  floor) — separate from its on-chain "warnings"/risk surface, which per search draws on
  holder concentration, liquidity, freeze authority and other on-chain red flags, updated
  in real time. UNVERIFIED whether Jupiter's warning UI explicitly enumerates
  PermanentDelegate/TransferHook/Pausable by name vs. a generic "risky token" flag —
  worth checking developers.jup.ag/docs/tokens/verification directly when reachable.
- Phantom (docs.phantom.com/developer-powertools/solana-token-extensions-token22):
  confirmed to show an explicit warning for PermanentDelegate ("delegate can burn/transfer
  any amount, cannot be revoked by holder") and to surface the transfer-fee percentage on
  every send confirmation screen when TransferFeeConfig is present. HIGH confidence —
  Phantom's own developer docs page, title matched directly by search.
- SolSniffer (solsniffer.com): "Snifscore" 1-100 across 20+ on-chain indicators,
  general-purpose (wash trading, LP lock, holder concentration) — no confirmed
  Token-2022-extension-specific breakdown found in this pass (UNVERIFIED whether it
  enumerates individual Token-2022 extensions vs. treating "Token-2022" as one flag).
- Birdeye: combines rug-detection signals with trading data; a solana-foundation/tokens
  GitHub issue (#30, "RFC: on-chain enrichment for mint authority + Token-2022 safety
  signals") explicitly notes Birdeye/CoinGecko/ClickHouse/Webacy are currently *off-chain*
  risk sources and proposes adding on-chain Token-2022 extension data — implying, as of
  that RFC, Birdeye's risk model was NOT yet reading Token-2022 extensions directly.
  MEDIUM confidence, single GitHub issue as source, but it is a primary/first-party
  signal (Solana Foundation's own tokens repo).

## 4. Compute-unit costs and account sizes

- Confidential transfer range proof: 111,000–368,000 CU depending on bit width; the
  256-bit batched range proof alone is >25% of the 1.4M CU per-tx ceiling, ~0.49-0.59%
  of a full block depending on slot-time regime (75M CU blocks at 300ms slots vs 62.5M
  at 250ms slots from epoch 1037). A confidential transfer overall runs "two orders of
  magnitude" more compute than a plain transfer (a few thousand CU baseline).
  Source: xroot.dev/blog/solana-confidential-transfers-kill-switch-proof-cost (blocked
  for direct fetch here; figures via WebSearch snippet only — MEDIUM, single source,
  numbers precise enough and internally consistent that they read as sourced from
  primary program benchmarks, but not independently re-verified against spl-token-2022
  test suite in this pass).
- Transfer hook overhead (from a solana-program-library PR/test comparison surfaced by
  search): a "hooked" transfer using a fixed 4-account extra-meta list costs ~38.5k CU
  vs ~22.8k CU for the equivalent non-hooked baseline test — i.e. roughly +15-16k CU for
  a simple hook (1 find_program_address + 1 CPI create + validation of 4 metas vs 1).
  LOW/MEDIUM confidence — figures read from a WebSearch summary of program-library test
  code, not confirmed by directly reading the test file; treat as illustrative order of
  magnitude, re-verify by reading solana-program/token-2022 test fixtures directly
  before publishing as fact.
- Plain transferChecked (no extensions): baseline "a few thousand CU" per the same
  xroot.dev summary — could not pin an exact figure (e.g. ~5-10k CU commonly cited
  elsewhere for classic SPL transfer, UNVERIFIED for Token-2022 transferChecked
  specifically in this pass).
- Account sizes: Token-2022 preserves the original 82-byte Mint / 165-byte Account
  layout as a prefix, then appends a TLV region per enabled extension — so size is
  variable and must be computed (e.g. via getMinimumBalanceForRentExemptAccountWithExtensions /
  ExtensionType::try_calculate_account_len), never hardcoded. This matches and
  reinforces (does not duplicate beyond restating) security.md's existing "don't
  hardcode token account rent" section — no new fact here beyond confirming the
  82/165-byte prefix detail, which security.md doesn't currently state explicitly and
  could be added as a one-line precision.

## 5. Transfer hook specific risks

- Reentrancy: Token-2022's transfer hook is a *read-only guest* from the token program's
  perspective — the hook CANNOT alter the transfer amount (unlike transfer fee, which is
  computed by the token program itself). The `TransferHookAccount` extension carries a
  `transferring` boolean flag, set true only while the token program is mid-CPI into the
  hook; hook programs should check it and reject any invocation that isn't actually
  nested inside a real Token-2022 transfer CPI (this is the specific mechanism behind
  security.md's existing "verify transferring state" checklist item — worth citing the
  flag name explicitly if not already named). Solana permits self-reentrant CPI (program
  calling itself, A->A) in general — the transfer-hook design does not eliminate that
  general Solana reentrancy surface, it only gives hook authors one flag to gate on.
  Source: multiple corroborating summaries (dev.to "imported Ethereum's deadliest bug
  class", RareSkills Token-2022 spec write-up) — MEDIUM/HIGH, consistent across sources
  but not read from the Token-2022 program source directly in this pass.
- Hook program upgradeability: the core, venue-level mitigation is checking whether the
  hook program's upgrade authority (and the ExtraAccountMetaList's update authority) has
  been revoked. Raydium's stated policy is to exclude hooks entirely; Meteora requires
  both the hook program AND hook authority to be revoked before allowing a hooked mint —
  i.e. the practical industry check is "is this hook program immutable," which maps
  directly to the kit's existing program-verification guidance (`solana program show`
  upgrade authority check) applied to the *hook program*, not just the token program.
- Extra account meta spoofing: an attacker can write their own hook program that calls a
  victim's hook directly (not via a real transfer), passing fabricated source/destination
  accounts that nonetheless reference a legitimate mint — this is exactly
  security.md's existing 3rd bullet ("token accounts actually belong to the mint passed
  in"). No new attack vector found beyond what's already documented; the one addition is
  the ExtraAccountMetaList staleness/DoS footgun from section 2 above (client caches
  resolved metas, issuer rotates hook/list, resolution goes stale) — a correctness bug,
  not an exploit, but worth a line for integrators.
- CPI Guard + hooks: not found as a documented interaction in this pass beyond
  security.md's existing generic CPI Guard coverage (CPI Guard close-destination-must-be-
  owner rule already listed). UNVERIFIED whether CPI Guard specifically blocks or
  interacts with hook-triggered CPIs differently from any other CPI — flag as an open
  question for a follow-up read of the Token-2022 program source.
- Confidential transfer + hooks / amount u64::MAX: could not find a primary source in
  this pass documenting how transfer hooks observe amounts under confidential transfer
  (where the plaintext amount is not available to the hook, or a sentinel is used) —
  mark UNVERIFIED / needs a direct read of the Token-2022 confidential-transfer +
  transfer-hook interaction code before asserting a "u64::MAX" sentinel behavior in the
  skill. Do not state this as fact without further verification.

## Sources list (for citation in the report)
- solana.com/news/post-mortem-may-2-2025 (blocked; via search)
- solana.com/news/post-mortem-june-25-2025 (blocked; via search)
- github.com/solana-program/token-2022/issues/657 (read directly)
- blog.zksecurity.xyz/posts/solana-phantom-challenge-bug/ (blocked; via search)
- coindesk.com/markets/2025/05/05/... (blocked; via search)
- cryptorank.io/news/feed/0cf43-... ; binance.com/en/square/post/2024-09-04-... (Permanent Delegate, Sept 2024)
- dev.to/ohmygod/solanas-permanent-delegate-burn-scam-... (2026 scale claim, LOW conf)
- cointelegraph.com/news/solana-memecoin-hits-328-trillion-market-cap-but-its-honeypot ;
  benzinga.com/content/38537072/... ; cryptonews.com/news/solana-meme-coin-hits-a-328t-...
  (BONKKILLER, Apr 2024)
- neodyme.io/en/blog/token-2022/ ; neodyme.io/reports/Token%202022%20-%202024.pdf (blocked; via search)
- reports.zellic.io/publications/spl-token-2022 (blocked; via search)
- blog.offside.io/p/token-2022-security-best-practices-part-1 and -part-2 (blocked; via search)
- xroot.dev/blog/solana-confidential-transfers-kill-switch-proof-cost (blocked; via search)
- docs.phantom.com/developer-powertools/solana-token-extensions-token22 (title matched via search)
- docs.jup.ag/user-docs/launch/vrfd/token-verification ; developers.jup.ag/docs/tokens/verification
- api.rugcheck.xyz/swagger/index.html ; github.com/aethernet404/rugcheck, romankurnovskii/RugCheck-CLI, kukapay/rug-check-mcp
- solsniffer.com
- github.com/solana-foundation/tokens/issues/30 (Birdeye off-chain-only RFC)
- github.com/solana-labs/solana-program-library issues #6108 / #5108 (extra-account-meta resolution)
