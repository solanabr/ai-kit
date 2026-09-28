# Section 9 gap-closure notes (2026-09-28)

Network: solana.com/spl.solana.com/explorer.solana.com/solscan.io/docs.phantom.com/
learn.backpack.exchange/web.archive.org all EGRESS_BLOCKED or unreachable via WebFetch
in this environment. github.com, raw.githubusercontent.com, WebSearch worked.
mcp__github list_pull_requests/etc. refused for solana-program/token-2022 (not the
attached repo — only search_code, a global search endpoint, worked).

## 1. Token-2022 upgrade authority / deployed version
- Program ID confirmed: TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb.
- github.com/solana-program/token-2022/releases/tag/program@v11.1.0 (2026-09-23):
  verbatim "This program is available on devnet and testnet." No mainnet mention.
  Verifiable build via solana-verifiable-build / OtterSec; commit
  8867f751c0f69367ba03af4f85510b5611989491; an "executable hash" was returned but at
  66 hex chars (not a clean 64-char sha256) — likely mangled by the summarizing
  fetch, do not trust the exact string.
- program@v11.0.0 release notes: verbatim "This program is available on all
  networks." (i.e. including mainnet-beta).
- => v11.0.0 is very likely still the mainnet-deployed build as of 2026-09-28;
  v11.1.0 (5 days old) has NOT been promoted to mainnet per its own release notes.
  This refines brief §2 item 1's "token-2022 program v11 'available on all
  networks'" — that phrase belongs to v11.0.0, not v11.1.0. Medium confidence
  (self-reported GitHub release notes, not cross-checked on-chain).
- Upgrade authority (key/multisig/none): NOT FOUND anywhere reachable — no
  security.txt, no deployment table in README, no audit report excerpt, no
  otter-sec verified-programs-api record content (only found the tool repos
  themselves, not a query result for this program). UNVERIFIED.
- Anza security-audits repo (github.com/anza-xyz/security-audits) lists an
  extensive audit history for token-2022 through Zellic 2026-09-24 (Halborn
  2022/2024, Zellic 2022/2025/2026, Trail of Bits 2023/2026 x2, NCC 2023,
  OtterSec 2023 x2, Certora 2024, Least Authority 2025-11, ZKSecurity 2025-09,
  Code4rena 2025-11, Qedit 2025-12, Asymmetric Research 2026-06). Medium
  confidence (WebFetch summary of the repo, not raw file listing).
- Human next step: `solana program show TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb
  -u mainnet-beta` gives authority + last-deployed slot directly; cross-check
  the slot's deployed hash against a version tag via
  `solana-verify get-program-hash <id>` or the OtterSec API
  (https://verify.osec.io/status/<id>).

## 2. Wallet extension support
Phantom (docs.phantom.com/developer-powertools/solana-token-extensions-token22 —
page itself blocked, read via WebSearch-cached snippet only, so treat as Low-Medium):
- Transfer Fee: fee % shown on the send confirmation screen.
- Metadata extension: supported.
- Permanent Delegate: warning shown to the user.
- Interest-Bearing: displays the rate.
- Transfer Hooks: mentioned as supported in a 2026 Phantom changelog note, but
  exact resolution behavior (does it run resolveExtraAccountMetas on send?) not
  confirmed from primary text.
- Non-transferable / confidential balances / scaled-ui-amount: NOT FOUND in this
  pass — UNVERIFIED for Phantom specifically.

Solflare: repeatedly described (3rd-party sources) as "one of the first native
Solana wallets with Token-2022 support" and supporting extensions generally;
no per-extension behavior found (help.solflare.com not fetched, not in search
results with detail). UNVERIFIED beyond "supports Token-2022 generally."

Backpack: learn.backpack.exchange article exists ("What are Solana Token
Extensions?") but domain is EGRESS_BLOCKED; only a generic "Backpack supports
Token Extensions" claim surfaced via WebSearch summary, no per-extension detail.
UNVERIFIED beyond general support.

PumpSwap: not investigated this pass (deprioritized under time budget) —
still fully unverified, same as brief.

Protocol-level (not wallet-specific, applies everywhere): ConfidentialTransfer
and TransferHook extensions cannot be combined on the same mint (amount is
encrypted, hook needs the plaintext amount) — repeated across multiple
independent summaries of solana.com docs. Medium-High confidence.

solana-foundation/solana-com repo (github code search) has no per-extension
wallet-support matrix file; `packages/ecosystem-data/src/wallets/wallet-data.ts`
and `apps/web/builder/section-page/en/solutions-token-extensions.json` only
carry generic wallet descriptions/icons and marketing copy ("Wallet support,
token issuers, block explorers and technical docs." for confidential
balances) — no structured per-extension support table exists there to read.

Human next step: open docs.phantom.com/developer-powertools/solana-token-
extensions-token22, help.solflare.com, and learn.backpack.exchange/articles/
what-are-solana-token-extensions directly (all blocked from this sandbox);
or mint a test token with each extension and check what each wallet's send
screen does with it.

## 3. Solana StackExchange top Token-2022 questions
Fully UNVERIFIED. solana.stackexchange.com and api.stackexchange.com are both
proxy-blocked (403 policy denial, confirmed in recentRelayFailures); web.archive.org
is not fetchable at all by the WebFetch tool in this environment ("unable to
fetch from web.archive.org", both for explorer/solscan and for a StackExchange
tag-listing snapshot). WebSearch queries with site:solana.stackexchange.com and
free-text queries naming the domain did not return any indexed SE pages —
either the search backend deprioritizes/excludes that domain or it isn't
well-indexed there. No titles or root causes obtained.
Human next step: browse https://solana.stackexchange.com/questions/tagged/
token-2022?sort=MostVotes directly.

## 4. Open PRs / 2026 deprecations
- PR #1508 CONFIRMED via direct WebFetch of
  github.com/solana-program/token-2022/pull/1508:
  - Title: "SlotReferenceFee: per-slot escalating in-kind fee mint extension"
  - Author: staccDOTsol; opened 2026-09-28 (today); state: OPEN; last activity
    same day; 2 comments (one is a bot usage-limit notice, no maintainer
    review yet).
  - Mechanism: mint keeps a per-slot reference counter in TLV; each
    TransferChecked registers against the current slot; n-th transfer in a
    slot pays floor_basis_points * n^2 bps (capped at cap_basis_points), with
    `free_references` free transfers first; fees harvested permissionlessly
    to an incinerator-owned sink + a configurable fee destination set at
    mint init. Design doc referenced at proposals/slot-reference-fee.md.
  - Explicitly NOT included in the PR: JS client bindings, CLI support, a
    feature gate for deployment. This would be extension type 29 if merged
    (28 exist today per brief).
  - High confidence — read directly, not search-summarized.
- No other open extension-proposal PRs or any 2026 deprecation announcements
  were found via WebSearch in this pass (queries for "open pull request new
  extension 2026" and "deprecate extension 2026" returned only generic docs,
  no GitHub PR hits). The github MCP tool's list_pull_requests is scoped to
  the attached repo only (solanabr/ai-kit) and refused solana-program/token-2022,
  so a full open-PR listing wasn't possible from here.
- Human next step: `gh pr list --repo solana-program/token-2022 --state open`
  or browse github.com/solana-program/token-2022/pulls to see the full open-PR
  set beyond what WebSearch surfaced.
