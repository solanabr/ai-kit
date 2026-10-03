---
name: solana-dev
description: Routing hub for Solana development. Maps a task to the one reference to read first in the ext/ skill submodules or the kit's local skills.
user-invocable: true
---

# Solana skill hub

Find the task, read the linked file, and follow further links only as needed. Paths are relative to this file.

Every install carries the core packs: solana-dev, auditor-skill and colosseum. The other `ext/` packs are extensions: the kit pins them, and a project installs one when a task needs it. A row that links into an extension gives its install command; run it when the linked folder is missing (`/update` keeps what you install). The Extensions table at the end lists each one with when to use it.

When sources overlap: the program-code house rules in the project instruction file (`CLAUDE.md`, or `AGENTS.md` in `--agents` installs) win; a protocol's official skill wins for its own SDK (Jupiter, Metaplex, Helius, MagicBlock, Alchemy); [ext/solana-dev](ext/solana-dev/skills/solana-dev/SKILL.md) wins for general Solana work; sendai and community skills fill gaps only.

## Programs

| Task | Read |
|------|------|
| Any program, client or test work (entry point) | [solana-dev SKILL.md](ext/solana-dev/skills/solana-dev/SKILL.md) |
| Anchor | [programs/anchor.md](ext/solana-dev/skills/solana-dev/references/programs/anchor.md); upgrading to 1.x: [migrating-v0.32-to-v1.md](ext/solana-dev/skills/solana-dev/references/anchor/migrating-v0.32-to-v1.md) |
| Pinocchio, CU optimization | [programs/pinocchio.md](ext/solana-dev/skills/solana-dev/references/programs/pinocchio.md) |
| Account and PDA design | [programs/design-patterns.md](ext/solana-dev/skills/solana-dev/references/programs/design-patterns.md) |
| Tests: LiteSVM, Mollusk, Surfpool | [testing.md](ext/solana-dev/skills/solana-dev/references/testing.md), [surfpool/overview.md](ext/solana-dev/skills/solana-dev/references/surfpool/overview.md) |
| Error codes, failing transactions | [common-errors.md](ext/solana-dev/skills/solana-dev/references/common-errors.md) |
| Toolchain version pairing | [compatibility-matrix.md](ext/solana-dev/skills/solana-dev/references/compatibility-matrix.md) |
| Security review | [security.md](ext/solana-dev/skills/solana-dev/references/security.md), then [auditor-skill](ext/auditor-skill/SKILL.md) for the audit itself (scope-gated checklists, 1,424 items; see Security tooling below) |
| Financial math, Quasar zero-copy | [RUST.md](ext/quicknode-anchor/skills/solana/RUST.md), [ANCHOR.md](ext/quicknode-anchor/skills/solana/ANCHOR.md), [QUASAR.md](ext/quicknode-anchor/skills/solana/QUASAR.md) from [quicknode-anchor](ext/quicknode-anchor/); reference files only, skip that repo's SKILL.md workflow layer (install: `bash .claude/bin/skills.sh add quicknode-anchor`) |
| Formal verification (Lean 4) | [qedgen](ext/qedgen/skills/qedgen/SKILL.md) from [QEDGen](ext/qedgen/); needs the `qedgen` CLI, plus `MISTRAL_API_KEY` or `ARISTOTLE_API_KEY` depending on the command (install: `bash .claude/bin/skills.sh add qedgen`) |
| Port from Solidity/EVM | [eth-to-sol](ext/eth-to-sol/SKILL.md) from [eth-to-sol](ext/eth-to-sol/): [type-mapping](ext/eth-to-sol/translation/type-mapping.md), [pattern-mapping](ext/eth-to-sol/translation/pattern-mapping.md), [stdlib-mapping](ext/eth-to-sol/translation/stdlib-mapping.md), [mental-model](ext/eth-to-sol/translation/mental-model.md), [translation/](ext/eth-to-sol/translation/), [security/](ext/eth-to-sol/security/), [optimization/](ext/eth-to-sol/optimization/); concept map: [solana-vs-evm.md](ext/solana-new/skills/idea/solana-beginner/references/solana-vs-evm.md) (install: `bash .claude/bin/skills.sh add eth-to-sol solana-new`) |

Anchor 1.x defaults this kit uses (not all spelled out upstream): SPL transfers through `token_interface::transfer_checked`, account space `T::DISCRIMINATOR.len() + T::INIT_SPACE`, Rust LiteSVM tests under `programs/<name>/tests/` (`anchor test` runs Surfpool).

## Clients and frontend

| Task | Read |
|------|------|
| Wallet connection, React hooks, `@solana/kit` UI | [frontend.md](ext/solana-dev/skills/solana-dev/references/frontend.md) |
| Transactions, Kit and web3.js boundary | [kit-web3-interop.md](ext/solana-dev/skills/solana-dev/references/kit-web3-interop.md) |
| web3.js to Kit migration | [solana-kit-migration/](ext/sendai/skills/solana-kit-migration/), [solana-kit/](ext/sendai/skills/solana-kit/) (install: `bash .claude/bin/skills.sh add sendai`) |
| Clients generated from an IDL (Codama, Shank) | [idl-codegen.md](ext/solana-dev/skills/solana-dev/references/idl-codegen.md) |
| Payments, Solana Pay, Kora | [payments.md](ext/solana-dev/skills/solana-dev/references/payments.md) |
| Official doc links | [resources.md](ext/solana-dev/skills/solana-dev/references/resources.md) |
| Vercel, Next.js, AI SDK, v0 | [ext/vercel/skills/](ext/vercel/skills/) from [Vercel](ext/vercel/) (install: `bash .claude/bin/skills.sh add vercel`) |
| UI design direction; Playwright tests of a local dApp | Anthropic's `frontend-design/SKILL.md` and `webapp-testing/SKILL.md` (install: `bash .claude/bin/skills.sh add anthropic-skills`; later sessions load them by description) |

## Tokens and NFTs

| Task | Read |
|------|------|
| Token-2022 extensions: pick, combine and create them (CLI, Kit, Anchor); fees, hooks, metadata, pausable, soulbound | [token-extensions](token-extensions/SKILL.md) |
| Confidential transfers | [confidential-transfers.md](ext/solana-dev/skills/solana-dev/references/confidential-transfers.md) |
| NFTs: Core, Token Metadata, Bubblegum, Candy Machine, Umi | [metaplex](ext/metaplex/skills/metaplex/SKILL.md) (official; install: `bash .claude/bin/skills.sh add metaplex`) |

## DeFi, RPC and data

| Task | Read |
|------|------|
| Jupiter swap, lend, perps, trigger, recurring | [integrating-jupiter](ext/jupiter/skills/integrating-jupiter/SKILL.md) (official); also [jupiter-lend](ext/jupiter/skills/jupiter-lend/SKILL.md), [jupiter-swap-migration](ext/jupiter/skills/jupiter-swap-migration/SKILL.md), [jupiter-vrfd](ext/jupiter/skills/jupiter-vrfd/SKILL.md) (install: `bash .claude/bin/skills.sh add jupiter`) |
| Helius RPC, DAS, webhooks, Sender, priority fees | [helius](ext/helius/helius-skills/helius/SKILL.md) (official; install: `bash .claude/bin/skills.sh add helius`) |
| SVM internals, consensus, validators, SIMDs | [svm](ext/helius/helius-skills/svm/SKILL.md) (install: `bash .claude/bin/skills.sh add helius`) |
| Alchemy RPC, DAS, Yellowstone gRPC; keyless x402 access | [alchemy-api](ext/alchemy/skills/alchemy-api/SKILL.md) (official), [agentic-gateway](ext/alchemy/skills/agentic-gateway/SKILL.md) (install: `bash .claude/bin/skills.sh add alchemy`) |
| MagicBlock Ephemeral Rollups: delegated state, real-time apps and games, private payments, VRF, cranks | [magicblock](ext/magicblock/skill/SKILL.md) (official; install: `bash .claude/bin/skills.sh add magicblock`) |

Other protocols from [SendAI](ext/sendai/skills/) (install: `bash .claude/bin/skills.sh add sendai`): perps [phoenix](ext/sendai/skills/phoenix/) and leverage [lavarage](ext/sendai/skills/lavarage/); AMMs [raydium](ext/sendai/skills/raydium/), [meteora](ext/sendai/skills/meteora/), [orca](ext/sendai/skills/orca/); lending [kamino](ext/sendai/skills/kamino/), [marginfi](ext/sendai/skills/marginfi/); LSTs [sanctum](ext/sendai/skills/sanctum/); launches [pumpfun](ext/sendai/skills/pumpfun/); oracles [pyth](ext/sendai/skills/pyth/), [switchboard](ext/sendai/skills/switchboard/); multisig [squads](ext/sendai/skills/squads/); bridging [debridge](ext/sendai/skills/debridge/), [lifi](ext/sendai/skills/lifi/); encrypted compute [arcium](ext/sendai/skills/arcium/); ZK compression [light-protocol](ext/sendai/skills/light-protocol/); data [birdeye](ext/sendai/skills/birdeye/), [wallet-analysis](ext/sendai/skills/wallet-analysis/); RPC [carbium](ext/sendai/skills/carbium/), [quicknode](ext/sendai/skills/quicknode/); order book [manifest](ext/sendai/skills/manifest/); order flow [dflow](ext/sendai/skills/dflow/); account cleanup [sol-incinerator](ext/sendai/skills/sol-incinerator/); agents [solana-agent-kit](ext/sendai/skills/solana-agent-kit/); wallets [phantom-connect](ext/sendai/skills/phantom-connect/); scanning [vulnhunter](ext/sendai/skills/vulnhunter/). SendAI's own jupiter, metaplex, helius and magicblock folders are older copies; the official skills above supersede them.

## Security tooling

- [safe-ai-skill](https://github.com/solanabr/safe-ai-skill), core (the `safe-ai-skill@stbr` plugin): hooks gate mainnet, value-moving and authority actions and secret reads. At session start it pins skills and `ext/` submodules and moves any that drift or look unsafe into quarantine, so a missing `ext/` path may be quarantined rather than uninitialized. Its ask or deny is the user's policy, so don't retry the action another way. CLI (on PATH while the plugin is enabled, else `npx @stbr/safe-ai-skill`): `status`, `verify check <dir>`, `registry list`.
- [auditor-skill](ext/auditor-skill/SKILL.md), core: the kit's audit pack, scope-gated so it loads only the checklists a repo needs. Programs — [account validation](ext/auditor-skill/checklists/01-program-account-validation.md), [access control](ext/auditor-skill/checklists/02-program-access-control.md), [arithmetic](ext/auditor-skill/checklists/03-program-arithmetic-safety.md), [CPI and PDA](ext/auditor-skill/checklists/04-program-cpi-pda.md), [state machines](ext/auditor-skill/checklists/05-program-state-machine.md), [economics](ext/auditor-skill/checklists/06-program-economic-logic.md), [opsec and governance](ext/auditor-skill/checklists/07-program-opsec-governance.md); the code around them — [TypeScript](ext/auditor-skill/checklists/08-typescript-safety.md), [backend](ext/auditor-skill/checklists/09-backend-security.md), [frontend](ext/auditor-skill/checklists/10-frontend-security.md), [supply chain](ext/auditor-skill/checklists/11-supply-chain.md), [secrets](ext/auditor-skill/checklists/12-secrets-opsec.md), [deployment](ext/auditor-skill/checklists/13-deployment-infrastructure.md), [testing and formal verification](ext/auditor-skill/checklists/16-formal-verification-testing.md), [logging and incident response](ext/auditor-skill/checklists/17-logging-monitoring-incident-response.md), [privacy and change management](ext/auditor-skill/checklists/18-privacy-compliance-change-management.md), [AI-agent surface](ext/auditor-skill/checklists/19-ai-agent-security.md), [Rust services](ext/auditor-skill/checklists/20-rust-offchain-services.md). Also [known-vectors](ext/auditor-skill/known-vectors/) (138 worked attacks), [framework idioms](ext/auditor-skill/references/framework-idioms/), [invariant catalog](ext/auditor-skill/references/invariant-catalog.md), [false positives](ext/auditor-skill/references/false-positives.md), [report format](ext/auditor-skill/references/report-format.md), and [FULL-AUDIT.md](ext/auditor-skill/FULL-AUDIT.md) for the whole-repo run. It supersedes the trailofbits, ghostsecurity, defending-code and safe-solana-builder packs the kit used to pin. Its tool-execution layer wraps Trail of Bits at `vendor/trailofbits`, which the installers do not fetch: the pack tests for the directory and falls back to its own grep-based discovery when it is absent, so treat that layer as opt-in (`git -C .claude/skills/ext/auditor-skill submodule update --init`) rather than present.

## Deploy, infra, backend

- [deployment.md](deployment.md): devnet and mainnet flow, verifiable builds, Squads multisig upgrades, rollback
- [backend-async.md](backend-async.md): Rust services and indexers that talk to Solana
- MCP server for a program or API: Anthropic's `mcp-builder/SKILL.md` (install: `bash .claude/bin/skills.sh add anthropic-skills`); its evaluation script needs `ANTHROPIC_API_KEY`
- [Cloudflare](ext/cloudflare/skills/) (install: `bash .claude/bin/skills.sh add cloudflare`): [workers-best-practices](ext/cloudflare/skills/workers-best-practices/), [agents-sdk](ext/cloudflare/skills/agents-sdk/), [sandbox-stable](ext/cloudflare/skills/sandbox-stable/), [durable-objects](ext/cloudflare/skills/durable-objects/), [wrangler](ext/cloudflare/skills/wrangler/)

## Games and mobile

- [solana-game](ext/solana-game/skill/) (install: `bash .claude/bin/skills.sh add solana-game`): [SKILL.md](ext/solana-game/skill/SKILL.md), [unity-sdk.md](ext/solana-game/skill/unity-sdk.md), [playsolana.md](ext/solana-game/skill/playsolana.md) (PSG1, PlayDex, PlayID), [game-architecture.md](ext/solana-game/skill/game-architecture.md), [mobile.md](ext/solana-game/skill/mobile.md), [csharp-patterns.md](ext/solana-game/skill/csharp-patterns.md)
- [solana-mobile](ext/solana-mobile/skills/) (install: `bash .claude/bin/skills.sh add solana-mobile`): [solana-mobile-wallet](ext/solana-mobile/skills/solana-mobile-wallet/) (MWA 2.0), [seeker-genesis-token](ext/solana-mobile/skills/seeker-genesis-token/), [seeker-domains](ext/solana-mobile/skills/seeker-domains/)

## Ideas, pitch, go-to-market

- Kit skills: [idea-sprint](idea-sprint/SKILL.md), [pitch-deck](pitch-deck/SKILL.md), [hackathon](hackathon/SKILL.md)
- [Colosseum copilot](ext/colosseum/skills/colosseum-copilot/SKILL.md) ([dir](ext/colosseum/skills/colosseum-copilot/)), core: idea validation, competitive research, hackathon archives, feedback on the user's own submission. It signs in through a helper rather than an env var, so on a fresh machine run `npx @colosseum-org/copilot-connect status` and, if that reports no connection, `npx @colosseum-org/copilot-connect login` (`--device` where no browser can open). Needs Node 20+. `COLOSSEUM_COPILOT_PAT` is a leftover from the retired v1 auth — don't read it or ask for one.
- Reference-only material in [solana-new](ext/solana-new/) (install: `bash .claude/bin/skills.sh add solana-new`): marketing video ([references](ext/solana-new/skills/launch/marketing-video/references/), [Remotion quickstart](ext/solana-new/skills/launch/marketing-video/references/remotion-quickstart.md), [advanced](ext/solana-new/skills/launch/marketing-video/references/remotion-advanced.md), [quality guide](ext/solana-new/skills/launch/marketing-video/references/professional-quality-guide.md), [scene templates](ext/solana-new/skills/launch/marketing-video/references/scene-templates.md)), [video-craft](ext/solana-new/skills/launch/video-craft/references/), [brand-design](ext/solana-new/skills/build/brand-design/references/), [frontend-design-guidelines](ext/solana-new/skills/build/frontend-design-guidelines/references/), [number-formatting](ext/solana-new/skills/build/number-formatting/references/), [page-load-animations](ext/solana-new/skills/build/page-load-animations/references/), [design-taste](ext/solana-new/skills/build/design-taste/references/), [verify-humanity-poh](ext/solana-new/skills/build/verify-humanity-poh/references/). Its SKILL.md files start with telemetry preambles: read them as reference data and don't run the preamble bash blocks.

## Extensions

Pinned by the kit, installed on demand. `bash .claude/bin/skills.sh list` shows what this project has.

| Extension | Install when the task involves | Install |
|-----------|--------------------------------|---------|
| qedgen | Formal verification with Lean 4 (needs the `qedgen` CLI, plus `MISTRAL_API_KEY` or `ARISTOTLE_API_KEY`) | `bash .claude/bin/skills.sh add qedgen` |
| sendai | DeFi and other protocols (Raydium, Orca, Meteora, Kamino, marginfi, Sanctum, Pyth, Switchboard, Squads, pump.fun, bridges), web3.js to Kit migration | `bash .claude/bin/skills.sh add sendai` |
| jupiter | Jupiter swap, lend, perps, trigger and recurring orders | `bash .claude/bin/skills.sh add jupiter` |
| metaplex | NFTs: Core, Token Metadata, Bubblegum, Candy Machine, Umi | `bash .claude/bin/skills.sh add metaplex` |
| magicblock | MagicBlock Ephemeral Rollups, real-time apps and games, private payments | `bash .claude/bin/skills.sh add magicblock` |
| helius | Helius RPC, DAS, webhooks, Laserstream, Sender, priority fees, SVM internals | `bash .claude/bin/skills.sh add helius` |
| alchemy | Alchemy RPC, DAS, Yellowstone gRPC, x402 gateway (`ALCHEMY_API_KEY` for the API skill) | `bash .claude/bin/skills.sh add alchemy` |
| quicknode-anchor | Financial math, fixed-point arithmetic, Quasar zero-copy | `bash .claude/bin/skills.sh add quicknode-anchor` |
| eth-to-sol | Porting Solidity or other EVM contracts | `bash .claude/bin/skills.sh add eth-to-sol` |
| solana-game | Unity, C#, games, PlaySolana, PSG1 | `bash .claude/bin/skills.sh add solana-game` |
| solana-mobile | React Native, Expo, Mobile Wallet Adapter, Seeker, dApp Store | `bash .claude/bin/skills.sh add solana-mobile` |
| cloudflare | Cloudflare Workers, wrangler, Durable Objects, Agents SDK | `bash .claude/bin/skills.sh add cloudflare` |
| vercel | Vercel deploys, Next.js and React performance, web design review | `bash .claude/bin/skills.sh add vercel` |
| solana-new | Go-to-market references: marketing video, brand design, tokenomics, DefiLlama research, ecosystem catalogs; idea-sprint, pitch-deck and hackathon link it | `bash .claude/bin/skills.sh add solana-new` |
| anthropic-skills | UI design direction, Playwright tests of a local web app, building an MCP server (Anthropic's Apache-2.0 frontend-design, webapp-testing and mcp-builder, installed as top-level skills in `skills/<name>/`) | `bash .claude/bin/skills.sh add anthropic-skills` |

## Add-ons

[skill-registry.json](skill-registry.json) records each pack's tier, triggers, license and source. Its entries without a tier are opt-in tools the kit doesn't pin; install one only when the user asks and `safe-ai-skill add skill|mcp <source>` returns `proceed: true`. Wider ecosystem catalogs: [ext/solana-new/cli/data/](ext/solana-new/cli/data/) (install: `bash .claude/bin/skills.sh add solana-new`).
