# Token Extensions skill suite — research notes
Date: 2026-09-28. Repo: /home/user/ai-kit (read-only, not edited).

## Network notes
- solana.com blocked by egress proxy (confirmed).
- api.stackexchange.com and solana.stackexchange.com BOTH blocked at the proxy layer (curl: `CONNECT tunnel failed, response 403` on both `api.stackexchange.com` and `solana.stackexchange.com`) — this held even though the task brief suggested api.stackexchange.com "if not blocked." WebFetch to solana.stackexchange.com also refused ("Claude Code is unable to fetch from solana.stackexchange.com"). WebSearch (Brave-backed) does not appear to index solana.stackexchange.com question pages usefully — `site:solana.stackexchange.com` queries returned zero on-domain hits across 4 attempts.
- **Goal B item 4 (StackExchange top questions) is UNVERIFIED / NOT COMPLETED.** No reliable substitute source found in the time budget. Recommend a follow-up with direct browser access or a proxy allowlist change.
- github.com, raw.githubusercontent.com worked fine once repos were added via add_repo (public repos serve unauthenticated reads regardless of attach; GitHub MCP `search_issues`/`list_commits` needed `add_repo` first for `list_commits`, but `search_issues` worked globally without explicit attach — inconsistent, noted for future sessions).

## Goal A.1 — solana-com docs inventory (apps/docs/content/docs/en/)
Repo: https://github.com/solana-foundation/solana-com (sparse shallow clone, then `git fetch --depth=3000 origin main` for history). All dates are last-commit-touching-file, from local git log (author repo default branch `main`, current HEAD `4d59f49f`).

URL mapping: `apps/docs/content/docs/en/X.mdx` → `https://solana.com/docs/X` (fumadocs convention; `index.mdx` → directory root).

### tokens/extensions/ (Token-2022 extension pages)
| Path (docs/en/tokens/extensions/) | URL | Last touched | Kit(TS) | Rust | Anchor |
|---|---|---|---|---|---|
| index.mdx | /docs/tokens/extensions | 2026-08-26 | - | 2 blocks | - |
| transfer-hook.mdx | /docs/tokens/extensions/transfer-hook | 2026-08-26 | 0 (web3.js only, 1 ref) | 35 blocks | 29 mentions |
| transfer-hook-integration.mdx | /docs/tokens/extensions/transfer-hook-integration | 2026-08-20 | 8 | 0 | - |
| metadata.mdx | /docs/tokens/extensions/metadata | 2026-09-14 | 5 | 1 | - |
| dynamic-metadata-nft.mdx | /docs/tokens/extensions/dynamic-metadata-nft | 2026-08-26 | 0 | 1 | 21 mentions (Anchor-first guide) |
| transfer-fees.mdx | /docs/tokens/extensions/transfer-fees | 2026-04-24 | 5 | 1 | - |
| interest-bearing-tokens.mdx | /docs/tokens/extensions/interest-bearing-tokens | 2026-08-26 | 5 | 1 | - |
| non-transferrable-tokens.mdx | /docs/tokens/extensions/non-transferrable-tokens | 2026-04-24 | 5 | 1 | - |
| permanent-delegate.mdx | /docs/tokens/extensions/permanent-delegate | 2026-04-24 | 5 | 1 | - |
| permissioned-burn.mdx | /docs/tokens/extensions/permissioned-burn | 2026-06-19 | 5 | 1 | - |
| memo-transfer.mdx | /docs/tokens/extensions/memo-transfer | 2026-04-24 | 6 | 1 | - |
| cpi-guard.mdx | /docs/tokens/extensions/cpi-guard | 2026-04-24 | 5 | 1 | - |
| immutable-owner.mdx | /docs/tokens/extensions/immutable-owner | 2026-04-24 | 5 | 1 | - |
| default-state.mdx | /docs/tokens/extensions/default-state | 2026-04-24 | 5 | 1 | - |
| close-mint.mdx | /docs/tokens/extensions/close-mint | 2026-04-24 | 5 | 1 | - |
| pausable.mdx | /docs/tokens/extensions/pausable | 2026-04-24 | 5 | 1 | - |
| group-member.mdx | /docs/tokens/extensions/group-member | 2026-04-24 | 5 | 1 | - |
| scaled-ui-amount/index.mdx | /docs/tokens/extensions/scaled-ui-amount | 2026-04-24 | 5 | 1 | - |
| scaled-ui-amount/integration-guide.mdx | .../scaled-ui-amount/integration-guide | (see grep) | 3 (web3.js v1 heavy) | 0 | - |
| scaled-ui-amount/issuer-guide.mdx | .../scaled-ui-amount/issuer-guide | (see grep) | 0 | 0 | - |
| confidential-transfer/index.mdx | /docs/tokens/extensions/confidential-transfer | 2026-08-26 | 0 | 0 | - |
| confidential-transfer/create-mint.mdx | .../confidential-transfer/create-mint | (bulk) | 10 | 2 | - |
| confidential-transfer/create-token-account.mdx | .../create-token-account | (bulk) | 13 | 2 | - |
| confidential-transfer/deposit-tokens.mdx | .../deposit-tokens | (bulk) | 10 | 1 | - |
| confidential-transfer/apply-pending-balance.mdx | .../apply-pending-balance | (bulk) | 10 | 1 | - |
| confidential-transfer/transfer-tokens.mdx | .../transfer-tokens | (bulk) | 13 | 1 | - |
| confidential-transfer/withdraw-tokens.mdx | .../withdraw-tokens | (bulk) | 11 | 1 | - |
| confidential-transfer/integration-guide.mdx | .../integration-guide | 2026-09-15 | 14 | 4 | - |
| confidential-transfer/issuer-guide.mdx | .../issuer-guide | 2026-09-14 | 7 | 6 | - |

### tokenization/
| Path | URL | Last touched | Notes |
|---|---|---|---|
| index.mdx | /docs/tokenization | 2026-07-29 | overview |
| quickstart.mdx | /docs/tokenization/quickstart | 2026-07-29 | |
| token-acl.mdx | /docs/tokenization/token-acl | 2026-08-26 | Token ACL (permissioned-token gating layer); kit=9 code refs |
| dvp.mdx | /docs/tokenization/dvp | 2026-09-14 | delivery-vs-payment guide; uses `clusterApiUrl`/devnet airdrop patterns (flag: devnet-only demo code, not stale per se) |
| nav-strikes.mdx | /docs/tokenization/nav-strikes | 2026-07-29 | explicitly labelled "Built with @solana/kit (web3.js 2.0)" — current |

### Staleness flags found
- `tokens/extensions/scaled-ui-amount/issuer-guide.mdx` line ~148: "overridden, but this is **not live yet**" — explicit not-yet-shipped feature note. FLAG.
- `tokens/extensions/transfer-hook-integration.mdx`: explicitly documents both Kit and the "deprecated `@solana/web3.js`" library side by side — internally consistent, not stale, but confirms web3.js v1 is officially deprecated in these docs while still being taught (transitional).
- Most single-extension pages (transfer-fees, non-transferrable, permanent-delegate, memo-transfer, cpi-guard, immutable-owner, default-state, close-mint, pausable, group-member, scaled-ui-amount/index) share the exact same last-commit timestamp `2026-04-24T13:30:30-05:00` — a single bulk mechanical edit (likely a template/format pass), not organic content updates. Content itself wasn't diffed line-by-line for staleness beyond the grep below; recommend a follow-up content review if the skill will assert version-specific facts from these pages.
- No other "not yet on mainnet" / "coming soon" / "devnet only" (as a *limitation*, vs. demo-script devnet airdrop) markers found via grep across tokens/ and tokenization/.
- Confidence: Medium (single source: the repo itself, git log dates only — dates confirm *last touch*, not necessarily *content correctness*; no diff against solana.com production render was done since solana.com is network-blocked).

## Goal A.2 — developer-content repo status
https://github.com/solana-foundation/developer-content — **SUPERSEDED**, confirmed High confidence (repo's own README, first lines):
> "# Content Moved to solana-com Repo ... Contributions moving forward should be made to the solana-com repo. The developer docs content for solana.com is located in the `/content` directory on the solana-com repo which contains the pages for `/docs`, `/developers/cookbook`, `/developers/guides`, `/developers/courses`."
Do not link skill content to developer-content paths; link to solana-com paths only.

## Goal A.3 — Foundation MCP server(s) + llms.txt
Three distinct Solana-Foundation-branded MCP repos exist, easy to conflate:
1. **solana-foundation/solana-dev-mcp** — https://github.com/solana-foundation/solana-dev-mcp — a *demo/reference* MCP server (getBalance/getAccountInfo/getTransaction RPC wrappers + prompts), explicitly a teaching example, not the production docs server. Medium confidence (repo README + mcpservers.org listing, not independently cloned/read in full).
2. **solana-foundation/solana-mcp-official** — https://github.com/solana-foundation/solana-mcp-official — the production Foundation MCP, live at **mcp.solana.com**. Per web search (Solana Compass article + repo description, Medium confidence, not directly cloned): exposes 5 tools — `Solana_Expert__Ask_For_Help` and `Solana_Documentation_Search` (semantic RAG), `list_sections`/`get_documentation` (canonical-spec retrieval), and `program_autofixer` (Anchor/Pinocchio Rust checks). Ingests 4 sources: official Solana docs, Anchor Framework docs, Solana Program Examples, and **Solana Stack Exchange** — i.e. it likely already indexes token-extension docs and SE content, which argues for *linking* to it as a live-query tool from the skill rather than re-indexing docs manually. NOTE: this session's own `solana-dev` MCP tool (configured in this environment, presumably pointed at one of these) **failed to connect** (`ERR_PROXY_TUNNEL: 403 Forbidden`) — could not independently verify tool list from inside this session; the `list_sections`/`get_documentation`/`Solana_Documentation_Search` tool names matched what the system prompt describes for "solana-dev MCP," so this is very likely the same server.
3. **solana-foundation/awesome-solana-ai** — a curated list repo (not an MCP server itself), catalogs MCP servers/tools including the above.
- **llms.txt: CONFIRMED published**, High confidence — found directly in the solana-com source tree:
  - `apps/docs/src/app/llms.txt` (root-level llms.txt)
  - `apps/docs/src/app/docs/[section]/llms.txt` (dynamic, per-doc-section llms.txt — confirms a `/docs/tokens/llms.txt` / `/docs/tokenization/llms.txt` style endpoint likely exists per section)
  - `apps/docs/src/app/llms-full.txt` (full-corpus variant)
  - Did not fetch the rendered output (solana.com blocked); confirmed only that the generator routes exist in the repo. Skill files should link to `https://solana.com/docs/tokens/llms.txt`-style URLs as the low-token canonical reference once verified live (verify from outside this session, since solana.com is blocked here).

## Goal B.4 — Solana StackExchange top token-2022 questions
**NOT COMPLETED — network blocked both via API and WebFetch, WebSearch does not surface solana.stackexchange.com results.** See Network notes above. No fabricated list produced. Recommend retry from an environment with SE access, or ask the user for an SE data dump / export.

## Goal B.5/6 — GitHub issue pain points (solana-program/token-2022, legacy solana-labs/solana-program-library, solana-program/transfer-hook)
Repo note: `solana-labs/solana-program-library` is **archived/split**, confirmed High confidence (repo's own README): "PLEASE READ: This repo no longer contains the SPL program implementations... broken up into separate repos... under the solana-program organization," listing Token-2022 → `solana-program/token-2022`, Transfer Hook → `solana-program/transfer-hook`, ATA → `solana-program/associated-token-account`, Token-Metadata → `solana-program/token-metadata`, Token-Group → `solana-program/token-group`. Its **historical issues remain the best corpus of developer pain** (2000+ comments across the retrieved sample) even though the code moved; new issues should be filed against solana-program/*.

Searches used GitHub's `search_issues` (semantic, ranked by comments/reactions) against `repo:solana-program/token-2022` and `repo:solana-labs/solana-program-library`. `repo:solana-program/transfer-hook` returned 0 hits for several queries — the split repo has very little issue history yet (most transfer-hook pain is still filed against the legacy solana-program-library repo, pre-split).

### Theme clusters (ranked by approximate issue count / comment volume observed)
1. **ATA / associated-token-account confusion (program id, derivation, recovery)** — ~10+ issues, up to 24 comments each. Root cause: people derive ATAs with the wrong owner/program combination, don't realize Token-2022 needs `TOKEN_2022_PROGRAM_ID` in ATA derivation, or send funds to a non-ATA address and can't recover them.
   - https://github.com/solana-labs/solana-program-library/issues/2640 (24 comments) "Associated token account owner is changeable"
   - https://github.com/solana-labs/solana-program-library/issues/2457 (16 comments) "Please Help. My tokens went to associated account."
   - https://github.com/solana-labs/solana-program-library/issues/3326 (11 comments) "getOrCreateAssociatedTokenAccount throws TokenAccountNotFoundError for different errors"
   - https://github.com/solana-labs/solana-program-library/issues/2248 (7) "No way to recover tokens sent to a token address whose authority is an associated token account"

2. **Transfer hook: extra-account-meta resolution / off-chain-vs-on-chain mismatch** — footgun cluster, several closed issues with 4-10 comments each.
   - https://github.com/solana-labs/solana-program-library/issues/6623 (10) "spl-transfer-hook create-extra-metas : Result::unwrap() on an Err value: Downcast"
   - https://github.com/solana-labs/solana-program-library/issues/6064 (4) "Transfer Hook: Off-chain and on-chain helpers are resolving keys incorrectly"
   - https://github.com/solana-labs/solana-program-library/issues/6845 (4) "Unable to use seed to generate an ExtraAccountMeta that isn't a PDA"
   - https://github.com/solana-labs/solana-program-library/issues/5042 (5) "Transfer hook interface error reporting" (opaque errors when hook resolution fails)
   - https://github.com/solana-program/token-2022/issues/66 / solana-labs/solana-program-library#7004 (dup, 7 comments) "invoke_transfer_checked failed with out of memory for 2 transfers with hook" — combining transfer-fee + transfer-hook blows compute/stack.

3. **Confidential transfers: ZK ElGamal proof program availability / broken on cluster** — recurring "it's disabled/broken" reports tied to the zk-elgamal-proof program being toggled on/off clusters.
   - https://github.com/solana-program/token-2022/issues/657 (11) "Re-enabling the ZK ElGamal Proof Program and Token-22 Confidential Transfer Features"
   - https://github.com/solana-labs/solana-program-library/issues/6146 (6) "Confidential transfers currently broken?"
   - https://github.com/solana-program/token-2022/issues/523 (1) "configure-confidential-transfer-account fails with invalid instruction data due to disabled zk-elgamal-proof program"
   - https://github.com/solana-labs/solana-program-library/issues/6338 (10, open) "Confidential Transfer Support in @solana/spl-token" (JS client lag)

4. **CLI / client footguns around fee & withheld-token withdrawal, multisig, offline signing** —
   - https://github.com/solana-labs/solana-program-library/issues/7042 (6) "token-cli: withdraw-withheld-tokens silently fails"
   - https://github.com/solana-labs/solana-program-library/issues/1805 (9) "Issue with offline multisig token transfer signing using spl-token-cli"
   - https://github.com/solana-labs/solana-program-library/issues/7059 (3) "Unable to use the token cli to transfer tokens that have the transfer-fee and transfer-hook extensions"
   - https://github.com/solana-labs/solana-program-library/issues/1479 (7) "transfer requires knowledge of sender token account address"

5. **Metadata pointer / rent / account-size confusion** —
   - https://github.com/solana-program/token-2022/issues/701 (1) "initializing spl metadata gives error: Failed to reallocate account data" (didn't pre-fund rent for the larger metadata-carrying mint)
   - https://github.com/solana-labs/solana-program-library/issues/4551 / #4701 (5 each) CLI didn't support metadata-pointer set/update at time of filing (now resolved, but shows the extension's rollout lag pattern)
   - https://github.com/solana-program/token-2022/issues/1036 (closed) "NonTransferable mint should check for NonTransferableAccount" — extension-interaction gap (mint-level flag not enforced at account level).

6. **JS/TS client lag behind Rust program (spl-token-js / @solana/spl-token feature gaps)** — recurring theme where an extension ships in Rust before the TS SDK: transfer-hook JS support (#5974, #4337), SetTransferFee (#5451), confidential transfer JS (#6338).

7. **wasm32 / build-target regressions** — https://github.com/solana-program/token-2022/issues/293 (6) "regression in wasm32 support for latest releases of spl-token-2022" — affects anyone building browser-side signing/serialization.

No strong evidence found (in this pass) for "anchor version mismatch" as a distinct high-volume theme in the issue trackers directly — `dynamic-metadata-nft.mdx` on solana-com is itself Anchor-heavy (21 mentions) suggesting Anchor integration is covered in docs; Anchor+Token-2022 friction (e.g. `InterfaceAccount<Mint>` vs extension data, `Anchor.toml` IDL gen for Token-2022 CPIs) is a plausible pain point from general community knowledge but is **Speculative** here — not confirmed by a specific highly-commented issue in this search pass.

## Files/paths referenced (all under this session's scratchpad, not /home/user/ai-kit)
- /tmp/claude-0/-home-user-ai-kit/e1e74919-c970-5d7d-a36e-55697dbb879a/scratchpad/docs-pain/repos/solana-com (sparse shallow clone, tokens/ + tokenization/ + app/src for llms.txt check)
- /tmp/claude-0/-home-user-ai-kit/e1e74919-c970-5d7d-a36e-55697dbb879a/scratchpad/docs-pain/repos/developer-content (shallow clone, README only read)
- /tmp/claude-0/-home-user-ai-kit/e1e74919-c970-5d7d-a36e-55697dbb879a/scratchpad/docs-pain/repos/spl-legacy (shallow clone of solana-labs/solana-program-library, README only read)
