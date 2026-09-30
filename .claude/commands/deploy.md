---
description: "Deploy a program to devnet, or to mainnet after the user's explicit go-ahead"
disable-model-invocation: true
---

Deploy the workspace program(s) to the cluster in $ARGUMENTS (default `devnet`). Squads upgrade proposals, rollback and cost tables: [deployment.md](../skills/deployment.md).

## Devnet

1. `solana config get` and `solana address`: confirm the RPC URL and the deployer. Keep keypair paths under `~/.config/solana/` out of commands (the secrets hook blocks them) and rely on the configured default signer.
2. New program: `anchor keys sync` so `declare_id!` and `Anchor.toml` match `target/deploy/<name>-keypair.json`, then rebuild with `/build-program`. Skipping this gives `DeclaredProgramIdMismatch` at runtime.
3. Fund: `solana airdrop 2` (rate-limited; fall back to the web faucet). Cost: `solana rent <size of the .so in bytes>`; the deploy needs about twice that until the buffer closes.
4. Deploy with the cluster in the command, so the approval prompt shows it: `anchor deploy --provider.cluster devnet`, or `solana program deploy target/deploy/<name>.so -u devnet`.
5. Publish the IDL; in Anchor 1.x it lives in Program Metadata: `anchor idl init --filepath target/idl/<name>.json` the first time, `anchor idl upgrade --filepath target/idl/<name>.json` after upgrades.
6. Verify with `solana program show <PROGRAM_ID>` (authority, data length) and run the integration tests against devnet.
7. Record the ID in `.program-id-devnet` and in the app env (e.g. `NEXT_PUBLIC_PROGRAM_ID`).

## Mainnet

Start only when the user asks for mainnet, and first report which preconditions are missing: `/audit-solana` with no open Critical or High findings; tests and fuzzing pass; a devnet deployment exercised the real flows; the upgrade-authority plan is decided; an external audit for programs that hold user funds.

1. Show the user the program, deployer address and balance, estimated cost and upgrade authority, and wait for an explicit yes.
2. `anchor build --verifiable` (needs Docker; writes `target/verifiable/<name>.so`), then deploy that artifact: `anchor deploy --verifiable --provider.cluster mainnet`. Plain `anchor deploy` would ship `target/deploy/` instead. With the Solana CLI: `solana program deploy target/verifiable/<name>.so --url mainnet-beta --with-compute-unit-price <micro-lamports> --use-rpc`, so the write transactions land under congestion.
3. Verify: `anchor verify <PROGRAM_ID> --provider.cluster mainnet`; `solana program dump <PROGRAM_ID> dump.so --url mainnet-beta` and diff it against the deployed file. The dump is zero-padded to the ProgramData size, so hash equal lengths: `head -c $(wc -c < target/verifiable/<name>.so) dump.so | shasum -a 256` against `shasum -a 256 target/verifiable/<name>.so`. Confirm the upgrade authority with `solana program show`.
4. Publish the IDL (devnet step 5), then record `.program-id-mainnet`, `deployment-mainnet.json` (programId, deployedAt, deployer, upgradeAuthority, commit) and the production app env.
5. Smoke-test read-only paths first, then writes with minimal amounts.

## Upgrade authority staging

<!-- Adapted from sendaifun/solana-new (deploy-to-mainnet), MIT -->
| Stage | Authority | Command |
|---|---|---|
| Launch to ~3 months | Deployer key on a hardware wallet, so fixes ship fast | none |
| ~3 months, stable | Squads vault address (not the multisig account) | `solana program set-upgrade-authority <ID> --new-upgrade-authority <VAULT> --skip-new-upgrade-authority-signer-check` |
| Audited and battle-tested | None, irreversible; the user runs it (blocked for Claude) | `solana program set-upgrade-authority <ID> --final` |

## Guardrails

- Deploys, upgrades, buffer writes, `extend`, program and buffer closes and authority changes stop for the user's approval on every cluster. The prompt names the cluster it resolved (from `-u`/`--url`/`--provider.cluster`, else `Anchor.toml` or `solana config`). On mainnet, get the step 1 go-ahead first; the prompt is a second check, not a replacement.
- `--final`, `solana program close --bypass-warning`, `solana program-v4 finalize` and `spl-token authorize --disable` can't be undone, so they are blocked for Claude. Give the user the exact command to run.
- A failed or interrupted deploy leaves its SOL in a buffer account. Either resume with `solana program deploy --buffer <buffer-keypair>` once the user has recovered that keypair from the printed seed phrase (`solana-keygen recover`), or reclaim the SOL with `solana program close --buffers`.
- Never print keypair files or seed phrases.
