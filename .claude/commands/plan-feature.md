---
description: "Plan a Solana feature before coding: accounts, PDAs, instructions, risks, tests"
---

Write an implementation plan for the feature described in `$ARGUMENTS`. Plan only; write no code. If `.claude/context/idea.md` exists (written by the `startup-builder` pack's idea-sprint skill: `bash .claude/bin/skills.sh add startup-builder`), start from it instead of re-asking what it already answers.

## Steps

1. Read the code the feature touches. Ask the user only about decisions that change the design: who signs and who pays rent, expected scale and contention, upgradeability, target clusters, Token vs Token-2022.
2. If the account model or the program split is still open, spawn `solana-architect` and plan from its design.
3. Write the plan below. Size each account from its fields (Anchor 1.x: `T::DISCRIMINATOR.len() + T::INIT_SPACE`), price its rent, and give each instruction a CU estimate that `/profile-cu` will verify later.

## Plan format

1. **Summary**: the problem, who it is for, and the one flow that must work.
2. **Accounts**: per account: purpose, PDA seeds, fields with sizes, total bytes and rent, and which instructions create, mutate and close it.
3. **Instructions**: per instruction: accounts (signer, writable, PDA), arguments with bounds, checks, state changes, events, errors, CU estimate.
4. **Integrations**: CPIs into other programs, SDKs, RPC and indexer needs.
5. **Clients**: generated client (`/generate-idl-client`), frontend, Unity or backend touchpoints.
6. **Phases**: ordered; each lists the files to add or change, the tests that prove it done, and its review gate (`/test-rust`, `/diff-review`, plus `/audit-solana` for code that holds funds).
7. **Risks**: CU and transaction size (1232 bytes for legacy and v0, 4096 for v1), account growth and realloc, write-lock contention on shared accounts, upgrades and data migration, changes in external programs.
8. **Tests**: happy paths, every error path, adversarial cases (wrong signer, substituted or duplicated accounts, boundary amounts), and Surfpool mainnet-fork tests for CPIs into live programs.
9. **Rollout**: devnet first through `/deploy`, then the mainnet and upgrade-authority plan.

## Output

The plan as markdown, ending with open questions for the user. Drop sections that do not apply.
