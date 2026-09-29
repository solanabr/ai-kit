---
name: deployment
description: "Program deployment runbook: devnet then mainnet, verifiable builds, Squads v4 multisig upgrades, upgrade-authority staging, rollback, and cost estimation."
---

# Deployment

The runbook behind `/deploy`; `/setup-ci-cd` owns the CI workflow. Kit policy: devnet first, and mainnet only with the user's explicit go-ahead. Get that go-ahead yourself; do not rely on a tool gate to stop you. Claude Code adds one — a PreToolUse hook matching only the literal `anchor deploy` and `solana program deploy`, blocking them when the command or the configured cluster says mainnet unless prefixed with `CONFIRM_MAINNET=1`. Even there, `anchor program deploy|upgrade`, `anchor upgrade`, `solana program write-buffer`, `set-upgrade-authority` and `--final` pass unchecked. Codex runs the same gate from `.codex/hooks.json`, but only once `/hooks` has trusted it; any other runtime has none. Every mainnet command needs explicit confirmation first regardless.

## Anchor 1.x changes that affect deploys

- `anchor deploy` also uploads the IDL to Program Metadata (`--no-idl` skips it). `anchor idl init|upgrade --filepath target/idl/<name>.json` republishes it; the program ID comes from the IDL's `address`.
- A program deployed with Anchor 0.32 or older that has a legacy IDL account: close it with the 0.32 CLI (`anchor idl close <PROGRAM_ID>`) while the 0.32 binary is still deployed, then deploy the 1.x binary, or that rent is stranded. See [migrating-v0.32-to-v1.md](ext/solana-dev/skills/solana-dev/references/anchor/migrating-v0.32-to-v1.md), sections 5 and 10.
- Anchor no longer shells out to the `solana` CLI. Loader flags go after `--`: `anchor deploy -- --with-compute-unit-price 50000`. `anchor program deploy|upgrade|write-buffer|set-buffer-authority|set-upgrade-authority|show|dump|close` mirror the `solana program` commands used below, and newer CLIs deprecate top-level `anchor deploy`/`anchor upgrade` in their favor.
- `anchor verify <PROGRAM_ID>` wraps `solana-verify` since 0.32; binaries built with older Anchor will not verify with it.

## Build once, deploy that artifact

1. `/test-rust` green, `/audit-solana` for code that holds funds, `/profile-cu` baseline recorded.
2. `anchor build` for the IDL and types, then `solana-verify build --library-name <lib>` last. It rebuilds `target/deploy/<lib>.so` in Docker, and it is the build that `solana-verify verify-from-repo` and `anchor verify` reproduce. Any later `anchor build` or `cargo build-sbf` overwrites that file with a non-deterministic binary.
3. Record `solana-verify get-executable-hash target/deploy/<lib>.so` next to the release commit.
4. Back up `target/deploy/<name>-keypair.json` (it is the program address) outside the repo before the first deploy.

## Devnet

```bash
anchor deploy -p <name> --provider.cluster devnet          # first deploy
anchor upgrade target/deploy/<lib>.so --program-id <PROGRAM_ID> --provider.cluster devnet
solana program show <PROGRAM_ID> -u devnet
solana logs <PROGRAM_ID> -u devnet                         # while exercising each instruction
```

Rehearse the exact mainnet flow here, including a multisig upgrade through a devnet Squad.

## Cost estimation

- Program rent: `solana rent $(( $(wc -c < target/deploy/<lib>.so) + 45 ))` (ProgramData has a 45-byte header). With `--max-len <N>` to reserve growth room, use N + 45.
- A buffer holding about the same rent exists while writing; the deploy or upgrade instruction drains it to the payer (first deploy) or the spill account (upgrade).
- Writing takes many transactions (roughly one per KB of program). On mainnet add `--with-compute-unit-price <micro-lamports>`, use `--use-rpc` to send writes through the RPC instead of directly to leaders (more reliable from CI or behind NAT), and `--max-sign-attempts` for blockhash expiry. Use a paid RPC; public endpoints rate-limit the writes.
- A failed deploy leaves a funded buffer: list with `solana program show --buffers` and reclaim with `solana program close --buffers`, or resume with the printed seed phrase via `solana-keygen recover -o buffer.json` and `solana program deploy --buffer buffer.json ...`.

## Mainnet first deploy

```bash
CONFIRM_MAINNET=1 anchor deploy -p <name> --provider.cluster mainnet -- --with-compute-unit-price <N>
solana program show <PROGRAM_ID> -u mainnet-beta
anchor idl fetch <PROGRAM_ID> --provider.cluster mainnet    # diff against target/idl/<name>.json
solana-verify verify-from-repo -um --program-id <PROGRAM_ID> <REPO_URL> --commit-hash <SHA> \
  --library-name <lib> --mount-path <program dir> --remote  # accept the verify-PDA upload
```

## Upgrade-authority staging

1. Launch to about 3 months: authority on a hardware-wallet deployer key, so fixes ship fast while bugs surface.
2. Once stable (about 3 months, or earlier when meaningful value is at stake): move it to the Squads v4 vault PDA (`getVaultPda({ multisigPda, index: 0 })`, the "vault" address in the Squads app). The multisig account itself cannot sign, so authority given to it is lost.
   `solana program set-upgrade-authority <PROGRAM_ID> --new-upgrade-authority <VAULT_PDA> --skip-new-upgrade-authority-signer-check -u mainnet-beta`
   The skip flag is needed because a PDA cannot co-sign; verify the address first, a wrong one is unrecoverable.
3. After an audit and a long mainnet history: `solana program set-upgrade-authority <PROGRAM_ID> --final`. Irreversible, and it removes every rollback path.

## Mainnet upgrade through Squads v4

```bash
solana program write-buffer target/deploy/<lib>.so -u mainnet-beta --with-compute-unit-price <N> --use-rpc
solana program set-buffer-authority <BUFFER> --new-buffer-authority <VAULT_PDA> -u mainnet-beta
solana-verify get-buffer-hash -um <BUFFER>                  # must equal the executable hash; reviewers check it
solana program extend <PROGRAM_ID> <BYTES> -u mainnet-beta  # only if the .so outgrew the current Data Length
```

`write-buffer` needs the buffer authority to sign each write, so write with the deployer key and hand the buffer to the vault afterwards. `extend` is permissionless, so the deployer key can pay for it. Then create the upgrade proposal in the Squads app's program manager (buffer plus a spill address for the refund), collect approvals, and execute. Afterwards:

- `solana-verify get-program-hash -um <PROGRAM_ID>` equals the executable hash.
- Refresh verification through the multisig: `solana-verify export-pda-tx <REPO_URL> --program-id <PROGRAM_ID> --uploader <VAULT_PDA> --encoding base58 --compute-unit-price 0`, import it into the Squads transaction builder, execute, then `solana-verify remote submit-job --program-id <PROGRAM_ID> --uploader <VAULT_PDA>`.

Squads SDK details (vault PDA, proposals): [squads skill](ext/sendai/skills/squads/SKILL.md).

## Rollback

- Before every upgrade: `solana program dump <PROGRAM_ID> backup-<version>.so -u mainnet-beta`, and keep each release's verified `.so` and hash.
- Rolling back is another upgrade to the previous binary through the same buffer and multisig flow (devnet: `anchor upgrade <old>.so --program-id <PROGRAM_ID> --provider.cluster devnet`).
- The previous binary must still read current account layouts. Ship layout changes additively (version field, `realloc`) so rollback stays possible; strategies in [program-upgrade-guide.md](ext/solana-new/skills/launch/deploy-to-mainnet/references/program-upgrade-guide.md).
- An emergency pause exists only if every instruction already checks a pause flag; design it in before launch. A `--final` program cannot be rolled back.

## CI jobs

The workflow file comes from `/setup-ci-cd`; it needs these jobs:

- build: pinned Anchor (avm) and Agave versions, `anchor build` then `solana-verify build`, publish the `.so`, IDL and executable hash as artifacts.
- test: `cargo test` / `anchor test` (LiteSVM, Surfpool), `cargo clippy -- -D warnings`, `cargo audit`.
- deploy-devnet: on the integration branch, with a devnet-only key from CI secrets.
- mainnet-buffer: write the buffer and move its authority to the Squads vault. CI never holds the mainnet upgrade authority.
- verify: `solana-verify verify-from-repo --remote` against the release commit after the multisig executes.
