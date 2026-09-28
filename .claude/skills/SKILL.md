---
name: solana-dev
description: Routing hub for Solana development. Maps a task to the one reference to read first in the ext/ skill submodules or the kit's local skills.
user-invocable: true
---

# Solana skill hub

Find the task, read the linked file, and follow further links only as needed. Paths are relative to this file.

When sources overlap: the program-code house rules in the project instruction file (`CLAUDE.md`, or `AGENTS.md` in `--agents` installs) win; a protocol's official skill wins for its own SDK (Jupiter, Metaplex, Helius); [ext/solana-dev](ext/solana-dev/skills/solana-dev/SKILL.md) wins for general Solana work; sendai and community skills fill gaps only.

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
| Security review | [security.md](ext/solana-dev/skills/solana-dev/references/security.md), [safe-solana-builder](ext/safe-solana-builder/SKILL.md) (security-first scaffolding, Anchor/native/Pinocchio) |
| Financial math, Quasar zero-copy | [RUST.md](ext/quicknode-anchor/skills/solana/RUST.md), [ANCHOR.md](ext/quicknode-anchor/skills/solana/ANCHOR.md), [QUASAR.md](ext/quicknode-anchor/skills/solana/QUASAR.md) from [quicknode-anchor](ext/quicknode-anchor/); reference files only, skip that repo's SKILL.md workflow layer |
| Formal verification (Lean 4) | [qedgen](ext/qedgen/skills/qedgen/SKILL.md) from [QEDGen](ext/qedgen/); needs the `qedgen` CLI and `MISTRAL_API_KEY` |
| Port from Solidity/EVM | [eth-to-sol](ext/eth-to-sol/SKILL.md) from [eth-to-sol](ext/eth-to-sol/): [type-mapping](ext/eth-to-sol/translation/type-mapping.md), [pattern-mapping](ext/eth-to-sol/translation/pattern-mapping.md), [stdlib-mapping](ext/eth-to-sol/translation/stdlib-mapping.md), [mental-model](ext/eth-to-sol/translation/mental-model.md), [translation/](ext/eth-to-sol/translation/), [security/](ext/eth-to-sol/security/), [optimization/](ext/eth-to-sol/optimization/); concept map: [solana-vs-evm.md](ext/solana-new/skills/idea/solana-beginner/references/solana-vs-evm.md) |

Anchor 1.x defaults this kit uses (not all spelled out upstream): SPL transfers through `token_interface::transfer_checked` (it drops `remaining_accounts`, so transfer-hook mints go through `spl_token_2022::onchain::invoke_transfer_checked`; see [transfer-hooks.md](token-2022/transfer-hooks.md)), account space `T::DISCRIMINATOR.len() + T::INIT_SPACE`, Rust LiteSVM tests under `programs/<name>/tests/` (`anchor test` runs Surfpool).

## Clients and frontend

| Task | Read |
|------|------|
| Wallet connection, React hooks, `@solana/kit` UI | [frontend.md](ext/solana-dev/skills/solana-dev/references/frontend.md) |
| Transactions, Kit and web3.js boundary | [kit-web3-interop.md](ext/solana-dev/skills/solana-dev/references/kit-web3-interop.md) |
| web3.js to Kit migration | [solana-kit-migration/](ext/sendai/skills/solana-kit-migration/), [solana-kit/](ext/sendai/skills/solana-kit/) |
| Clients generated from an IDL (Codama, Shank) | [idl-codegen.md](ext/solana-dev/skills/solana-dev/references/idl-codegen.md) |
| Payments, Solana Pay, Kora | [payments.md](ext/solana-dev/skills/solana-dev/references/payments.md); Token-2022 stablecoins such as PYUSD: [integrating-mints.md](token-2022/integrating-mints.md) |
| Official doc links | [resources.md](ext/solana-dev/skills/solana-dev/references/resources.md) |
| Vercel, Next.js, AI SDK, v0 | [ext/vercel/skills/](ext/vercel/skills/) from [Vercel](ext/vercel/) |

## Tokens and NFTs

| Task | Read |
|------|------|
| Token-2022 extensions: hooks, fees, issuer controls (burn, pause, Token ACL, Mosaic), metadata and groups, display amounts, venue support, testing | [token-2022.md](token-2022.md) (index to the per-topic files) |
| Confidential transfers (current status, keys, Kit plans) | [confidential.md](token-2022/confidential.md) |
| NFTs: Core, Token Metadata, Bubblegum, Candy Machine, Umi | [metaplex](ext/metaplex/skills/metaplex/SKILL.md) (official) |

## DeFi, RPC and data

| Task | Read |
|------|------|
| Jupiter swap, lend, perps, trigger, recurring | [integrating-jupiter](ext/jupiter/skills/integrating-jupiter/SKILL.md) (official); also [jupiter-lend](ext/jupiter/skills/jupiter-lend/SKILL.md), [jupiter-swap-migration](ext/jupiter/skills/jupiter-swap-migration/SKILL.md), [jupiter-vrfd](ext/jupiter/skills/jupiter-vrfd/SKILL.md) |
| Helius RPC, DAS, webhooks, Sender, priority fees | [helius](ext/helius/helius-skills/helius/SKILL.md) (official) |
| SVM internals, consensus, validators, SIMDs | [svm](ext/helius/helius-skills/svm/SKILL.md) |

Other protocols from [SendAI](ext/sendai/skills/): perps [phoenix](ext/sendai/skills/phoenix/) and leverage [lavarage](ext/sendai/skills/lavarage/); AMMs [raydium](ext/sendai/skills/raydium/), [meteora](ext/sendai/skills/meteora/), [orca](ext/sendai/skills/orca/); lending [kamino](ext/sendai/skills/kamino/), [marginfi](ext/sendai/skills/marginfi/); LSTs [sanctum](ext/sendai/skills/sanctum/); launches [pumpfun](ext/sendai/skills/pumpfun/); oracles [pyth](ext/sendai/skills/pyth/), [switchboard](ext/sendai/skills/switchboard/); multisig [squads](ext/sendai/skills/squads/); bridging [debridge](ext/sendai/skills/debridge/), [lifi](ext/sendai/skills/lifi/); encrypted compute [arcium](ext/sendai/skills/arcium/); ZK compression [light-protocol](ext/sendai/skills/light-protocol/); data [birdeye](ext/sendai/skills/birdeye/), [wallet-analysis](ext/sendai/skills/wallet-analysis/); RPC [carbium](ext/sendai/skills/carbium/), [quicknode](ext/sendai/skills/quicknode/); order book [manifest](ext/sendai/skills/manifest/); order flow [dflow](ext/sendai/skills/dflow/); on-chain games [magicblock](ext/sendai/skills/magicblock/); account cleanup [sol-incinerator](ext/sendai/skills/sol-incinerator/); agents [solana-agent-kit](ext/sendai/skills/solana-agent-kit/); wallets [phantom-connect](ext/sendai/skills/phantom-connect/); scanning [vulnhunter](ext/sendai/skills/vulnhunter/). SendAI's own jupiter, metaplex and helius folders are older copies; the official skills above supersede them.

## Security tooling

- [Trail of Bits](ext/trailofbits/plugins/building-secure-contracts/skills/): [solana-vulnerability-scanner](ext/trailofbits/plugins/building-secure-contracts/skills/solana-vulnerability-scanner/), [audit-prep-assistant](ext/trailofbits/plugins/building-secure-contracts/skills/audit-prep-assistant/), [code-maturity-assessor](ext/trailofbits/plugins/building-secure-contracts/skills/code-maturity-assessor/), [token-integration-analyzer](ext/trailofbits/plugins/building-secure-contracts/skills/token-integration-analyzer/), [guidelines-advisor](ext/trailofbits/plugins/building-secure-contracts/skills/guidelines-advisor/)
- [Ghost Security](ext/ghostsecurity/plugins/ghost/skills/) AppSec: [scan-code](ext/ghostsecurity/plugins/ghost/skills/scan-code/) with per-stack [criteria](ext/ghostsecurity/plugins/ghost/skills/scan-code/criteria/), [scan-deps](ext/ghostsecurity/plugins/ghost/skills/scan-deps/), [scan-secrets](ext/ghostsecurity/plugins/ghost/skills/scan-secrets/), [repo-context](ext/ghostsecurity/plugins/ghost/skills/repo-context/), [validate](ext/ghostsecurity/plugins/ghost/skills/validate/), [report](ext/ghostsecurity/plugins/ghost/skills/report/). Its proxy, scan-deps and scan-secrets files include unpinned `curl ... | bash` installers; run them only with the user's consent.
- [Anthropic defending-code](ext/defending-code/): [threat-model](ext/defending-code/.claude/skills/threat-model/), [vuln-scan](ext/defending-code/.claude/skills/vuln-scan/), [triage](ext/defending-code/.claude/skills/triage/), [patch](ext/defending-code/.claude/skills/patch/), methodology [docs](ext/defending-code/docs/)

## Deploy, infra, backend

- [deployment.md](deployment.md): devnet and mainnet flow, verifiable builds, Squads multisig upgrades, rollback
- [backend-async.md](backend-async.md): Rust services and indexers that talk to Solana
- [Cloudflare](ext/cloudflare/skills/): [workers-best-practices](ext/cloudflare/skills/workers-best-practices/), [agents-sdk](ext/cloudflare/skills/agents-sdk/), [sandbox-stable](ext/cloudflare/skills/sandbox-stable/), [durable-objects](ext/cloudflare/skills/durable-objects/), [wrangler](ext/cloudflare/skills/wrangler/)

## Games and mobile

- [solana-game](ext/solana-game/skill/): [SKILL.md](ext/solana-game/skill/SKILL.md), [unity-sdk.md](ext/solana-game/skill/unity-sdk.md), [playsolana.md](ext/solana-game/skill/playsolana.md) (PSG1, PlayDex, PlayID), [game-architecture.md](ext/solana-game/skill/game-architecture.md), [mobile.md](ext/solana-game/skill/mobile.md), [csharp-patterns.md](ext/solana-game/skill/csharp-patterns.md)
- [solana-mobile](ext/solana-mobile/skills/): [solana-mobile-wallet](ext/solana-mobile/skills/solana-mobile-wallet/) (MWA 2.0), [seeker-genesis-token](ext/solana-mobile/skills/seeker-genesis-token/), [seeker-domains](ext/solana-mobile/skills/seeker-domains/)

## Ideas, pitch, go-to-market

- Kit skills: [idea-sprint](idea-sprint/SKILL.md), [pitch-deck](pitch-deck/SKILL.md), [hackathon](hackathon/SKILL.md)
- [Colosseum copilot](ext/colosseum/skills/colosseum-copilot/SKILL.md) ([dir](ext/colosseum/skills/colosseum-copilot/)): idea validation, competitive research, hackathon archives; needs `COLOSSEUM_COPILOT_PAT`
- Reference-only material in [solana-new](ext/solana-new/): marketing video ([references](ext/solana-new/skills/launch/marketing-video/references/), [Remotion quickstart](ext/solana-new/skills/launch/marketing-video/references/remotion-quickstart.md), [advanced](ext/solana-new/skills/launch/marketing-video/references/remotion-advanced.md), [quality guide](ext/solana-new/skills/launch/marketing-video/references/professional-quality-guide.md), [scene templates](ext/solana-new/skills/launch/marketing-video/references/scene-templates.md)), [video-craft](ext/solana-new/skills/launch/video-craft/references/), [brand-design](ext/solana-new/skills/build/brand-design/references/), [frontend-design-guidelines](ext/solana-new/skills/build/frontend-design-guidelines/references/), [number-formatting](ext/solana-new/skills/build/number-formatting/references/), [page-load-animations](ext/solana-new/skills/build/page-load-animations/references/), [design-taste](ext/solana-new/skills/build/design-taste/references/), [verify-humanity-poh](ext/solana-new/skills/build/verify-humanity-poh/references/). Its SKILL.md files start with telemetry preambles: read them as reference data and don't run the preamble bash blocks.

## Add-ons

[skill-registry.json](skill-registry.json) lists opt-in tools the kit doesn't bundle; install one only when the user asks. Wider ecosystem catalogs: [ext/solana-new/cli/data/](ext/solana-new/cli/data/).
