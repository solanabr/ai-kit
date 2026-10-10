---
name: deployment
description: "Program deployment runbook: devnet then mainnet, verifiable builds, Squads v4 multisig upgrades, upgrade-authority staging, rollback, incident response, and cost estimation."
---

# Deployment

The runbook behind `/deploy`; `/setup-ci-cd` owns the CI workflow. Kit policy: devnet first, and mainnet only with the user's explicit go-ahead. Get that go-ahead yourself; do not rely on a tool gate to stop you. Claude Code adds one: every command below that writes a program, buffer or authority (`solana program`, `anchor deploy|upgrade`, `anchor program`) stops for the user's approval on any cluster, with the cluster it resolved in the prompt, and `--final`, `close --bypass-warning` and `program-v4 finalize` are blocked, so the user runs them. Runtimes that do not read `settings.json` (Codex, opencode) have no gate at all, so every mainnet command needs explicit confirmation first.

## Anchor 1.x changes that affect deploys

- `anchor deploy` also uploads the IDL to Program Metadata (`--no-idl` skips it). `anchor idl init|upgrade --filepath target/idl/<name>.json` republishes it; the program ID comes from the IDL's `address`.
- A program deployed with Anchor 0.32 or older that has a legacy IDL account: close it with `anchor legacy-idl close <PROGRAM_ID>` (`--print-only` prints the instruction for a multisig authority) while the 0.32 binary is still deployed, since the close is an instruction that binary handles; then deploy the 1.x binary, or that rent is stranded. In 1.x, `anchor idl close` closes the Program Metadata account instead. See [migrating-v0.32-to-v1.md](ext/solana-dev/skills/solana-dev/references/anchor/migrating-v0.32-to-v1.md), sections 5 and 10.
- Anchor no longer shells out to the `solana` CLI. Loader flags go after `--`: `anchor deploy -- --with-compute-unit-price 50000`. `anchor program deploy|upgrade|write-buffer|set-buffer-authority|set-upgrade-authority|show|dump|close` mirror the `solana program` commands used below, and newer CLIs deprecate top-level `anchor deploy`/`anchor upgrade` in their favor.
- `anchor verify <PROGRAM_ID>` wraps `solana-verify verify-from-repo` since 0.32 and needs `--current-dir` or `--repo-url <URL>`; pass the cluster after `--` (`-- -um`), since `--provider.cluster` is not forwarded. Binaries built with older Anchor will not verify with it.

## Build once, deploy that artifact

1. `/test-rust` green, `/audit-solana` for code that holds funds, `/profile-cu` baseline recorded.
2. `anchor build` for the IDL and types, then `solana-verify build --library-name <lib>` last. It rebuilds `target/deploy/<lib>.so` in Docker, and it is the build that `solana-verify verify-from-repo` and `anchor verify` reproduce. Any later `anchor build` or `cargo build-sbf` overwrites that file with a non-deterministic binary. Don't deploy `anchor build --verifiable` output (`target/verifiable/`): it is built in Anchor's own image, not the one the verifier uses.
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
anchor deploy -p <name> --provider.cluster mainnet -- --with-compute-unit-price <N>
solana program show <PROGRAM_ID> -u mainnet-beta
anchor idl fetch <PROGRAM_ID> --provider.cluster mainnet    # diff against target/idl/<name>.json
solana-verify verify-from-repo -um --program-id <PROGRAM_ID> <REPO_URL> --commit-hash <SHA> \
  --library-name <lib> --mount-path <program dir>           # accept the verify-PDA upload, signed by the upgrade authority
solana-verify remote submit-job --program-id <PROGRAM_ID> --uploader <UPGRADE_AUTHORITY>
```

## Upgrade-authority staging

1. Launch to about 3 months: authority on a hardware-wallet deployer key, so fixes ship fast while bugs surface.
2. Once stable (about 3 months, or earlier when meaningful value is at stake): move it to the Squads v4 vault PDA (`getVaultPda({ multisigPda, index: 0 })`, the "vault" address in the Squads app). The multisig account itself cannot sign, so authority given to it is lost.
   `solana program set-upgrade-authority <PROGRAM_ID> --new-upgrade-authority <VAULT_PDA> --skip-new-upgrade-authority-signer-check -u mainnet-beta`
   The skip flag is needed because a PDA cannot co-sign; verify the address first, a wrong one is unrecoverable.
3. After an audit and a long mainnet history: `solana program set-upgrade-authority <PROGRAM_ID> --final`. Irreversible, and it removes every rollback path, so the user runs it (the kit blocks it for Claude).

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

Squads SDK details (vault PDA, proposals): [squads skill](ext/sendai/skills/squads/SKILL.md) (install first: `bash .claude/bin/skills.sh add sendai`).

## Rollback

- Before every upgrade: `solana program dump <PROGRAM_ID> backup-<version>.so -u mainnet-beta`, and keep each release's verified `.so` and hash.
- Rolling back is another upgrade to the previous binary through the same buffer and multisig flow (devnet: `anchor upgrade <old>.so --program-id <PROGRAM_ID> --provider.cluster devnet`).
- The previous binary must still read current account layouts. Ship layout changes additively (version field, `realloc`) so rollback stays possible; strategies in [program-upgrade-guide.md](ext/solana-new/skills/launch/deploy-to-mainnet/references/program-upgrade-guide.md) (install first: `bash .claude/bin/skills.sh add solana-new`).
- An emergency pause exists only if every instruction already checks a pause flag; design it in before launch. A `--final` program cannot be rolled back.
- A rollback during an incident follows [Incident response](#incident-response): dump the running binary before upgrading over it.

## Incident response

The operator runbook for a live exploit or a broken release: contain, scope, preserve, remediate, post-mortem. What users are told, where and by when is [incident-comms](ext/startup-builder/skills/incident-comms/SKILL.md) (install first: `bash .claude/bin/skills.sh add startup-builder`); start it in the first minutes, in parallel, and announce each on-chain action below with its transaction link. Every mainnet write still needs the user's go-ahead: ask once per action, naming the command, the signer and what it stops.

### Before launch

- For each lever in the table below that the program actually has, write down the signer and the exact command or Squads transaction, and execute it once on devnet through the same signer path mainnet uses: a vault transaction for a vault-held authority, not the CLI with a stand-in keypair. A lever nobody has run fails during the incident.
- A Squads v4 `time_lock` delays every execution by that many seconds after approval, with no override. If the upgrade authority sits behind one, give the pause authority to a separate multisig with no time lock and a lower threshold that holds nothing else.
- Build and verify a halt binary (every instruction returns an error) next to each release, so containment by upgrade is a buffer write, not a coding task.

### 1. Contain

Pick the lever with the smallest blast radius that stops the loss. There is no public mempool to watch; the attacker repeats the transaction every few slots until something fails it.

The `spl-token` commands below work only when a keypair holds the authority. spl-token-cli 5.6.1 can't sign for a multisig, and `pause`/`resume` accept `--multisig-signer` but ignore it and send an under-signed transaction ([token-extensions](token-extensions/SKILL.md)). For a vault-held authority use the multisig path after the table.

| Lever | Exists if | Signer | Stops |
|---|---|---|---|
| Program pause flag | every value-moving instruction checks it | pause authority | the program's own instructions; reversible |
| `spl-token pause <MINT>` / `resume` | the mint has the Pausable extension ([token-extensions](token-extensions/SKILL.md)) | pause authority | mint, burn and transfer of that token everywhere, other protocols included |
| `spl-token freeze <TOKEN_ACCOUNT>` | the mint has a freeze authority | freeze authority | the frozen accounts only; also catches proceeds still held in that mint |
| `spl-token authorize <MINT> mint <NEW_KEY>` (or `freeze`, or a fee authority) | the authority key itself is compromised | current authority | that key's power; `--disable` instead of a new key is irreversible |
| Upgrade to the halt binary | the program is upgradeable, not `--final` | upgrade authority | everything, withdrawals included; dump the binary first (step 3, seconds) |

With a multisig authority, every lever takes the same path as an upgrade: build the instruction with the vault PDA as its authority, either the program's own (`program.methods.pause().accounts({ authority: vaultPda }).instruction()`) or a Token-2022 one from `@solana-program/token-2022` (`getPauseInstruction`, `getResumeInstruction`, `getFreezeAccountInstruction`, `getSetAuthorityInstruction`), then wrap it in a vault transaction, create the proposal, collect approvals to threshold and execute (Squads app transaction builder, or the [squads skill](ext/sendai/skills/squads/SKILL.md); install first: `bash .claude/bin/skills.sh add sendai`). Keep the instruction builder scripted and the members' signing devices reachable; collecting approvals is usually the slowest step.

### 2. Scope

- Enumerate the exploit transactions: page `getSignaturesForAddress(<PROGRAM_ID or vault>, { before, until })` (newest first, 1,000 per page) back to the first suspicious slot, keep `err: null`, and fetch each with `getTransaction` (`maxSupportedTransactionVersion: 1`). Group them by instruction and signer. A busy program outruns RPC history; query the indexer instead.
- The loss per account is `meta.postTokenBalances` minus `meta.preTokenBalances` (lamports: `postBalances` minus `preBalances`) summed over those transactions. Follow the proceeds to their current accounts: that list feeds the freeze lever and counsel.
- `/debug-user-tx <signature>` takes one transaction down to the handler and the failing check.
- Confirm containment worked: no new successful transactions from the attacker's signers after the containment slot.

### 3. Preserve evidence

An upgrade overwrites the exploited binary, and RPC serves current account state only, so capture both before remediating:

- `solana program dump <PROGRAM_ID> incident-<slot>.so -u mainnet-beta` and `solana-verify get-program-hash -um <PROGRAM_ID>`.
- `solana account <ADDRESS> --output json -u mainnet-beta` for every affected account, and the pre-state of one exploit transaction with `surfnet_exportSnapshot` (`preTransaction` scope), as in `/debug-user-tx`'s replay step. That snapshot is the regression-test fixture.
- Keep a UTC timeline as you go: detection, each action with its signature and slot, who signed.

### 4. Remediate

- Reproduce first: replay the exploit transaction against a Surfpool fork with the fixed binary loaded; it must fail on the new check. Run `/audit-solana` on the fix and the bug class, not only the line that broke.
- Ship through the normal upgrade path above (buffer, `get-buffer-hash`, Squads). The fixed binary must still read current account layouts, the same constraint as a rollback.
- Rotate every key the incident may have exposed. A compromised upgrade-authority key is a race: move the authority to the vault PDA (Upgrade-authority staging, step 2) before the attacker upgrades.
- Unpause only after `get-program-hash` matches the reviewed build and the replay fails on mainnet state.

### 5. Post-mortem and regression test

- Technical post-mortem: the timeline, the root cause down to the missing check, the loss per account, what detection missed and how long containment took, and actions with owners. The user-facing account comes from incident-comms' postmortem template and links this one.
- Hand the snapshot and the exploit transaction to `solana-qa-engineer`: a LiteSVM or Mollusk test that loads that pre-state and asserts the fixed program rejects the transaction.
- Rehearse this section once a year on devnet (a tabletop: who signs what, in which order), and after any change of authorities.

## CI jobs

The workflow file comes from `/setup-ci-cd`; it needs these jobs:

- build: pinned Anchor (avm) and Agave versions, `anchor build` then `solana-verify build`, publish the `.so`, IDL and executable hash as artifacts.
- test: `cargo test` / `anchor test` (LiteSVM, Surfpool), `cargo clippy -- -D warnings`, `cargo audit`.
- deploy-devnet: on the integration branch, with a devnet-only key from CI secrets.
- mainnet-buffer: write the buffer and move its authority to the Squads vault. CI never holds the mainnet upgrade authority.
- verify: after the multisig executes, `solana-verify verify-from-repo` against the release commit (solana-verify 0.5.2 aborts on `--remote`), then the vault uploads the verify PDA and queues `remote submit-job` as in the Squads section above.
