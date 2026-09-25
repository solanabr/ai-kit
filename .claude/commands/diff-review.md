---
description: "Review the branch diff for Solana security issues, CU waste and AI slop"
---

Review this branch's changes against the base branch ($ARGUMENTS, default `main`, else `master`) and report findings by severity, each with `file:line` and a concrete fix. Vulnerability classes: [security.md](../skills/ext/solana-dev/skills/solana-dev/references/security.md); scanning workflow: [solana-vulnerability-scanner](../skills/ext/trailofbits/plugins/building-secure-contracts/skills/solana-vulnerability-scanner/) (install first: `bash .claude/bin/skills.sh add trailofbits`).

## Steps

1. Diff: `git diff <base>...HEAD`, plus `git diff HEAD` for uncommitted work, and `--stat` for scope. Read the whole file when a hunk lacks context (account structs, handlers).
2. Solana checks on the changed code:
   - New or changed accounts carry owner, signer and PDA constraints; each `UncheckedAccount` has a `/// CHECK:` the code enforces.
   - Math on amounts is checked, with no narrowing `as`; no `unwrap()`/`expect()` in program code.
   - PDAs reuse the stored bump (`bump = acct.bump`); handlers do not call `find_program_address`.
   - CPIs validate the target program and `.reload()` accounts they mutate.
   - Token code uses `transfer_checked` with `token_interface` and handles Token-2022 transfer hooks and fees where the mint may be Token-2022.
   - Pre-1.0 Anchor habits: `@coral-xyz/anchor` imports (now `@anchor-lang/core`), `CpiContext::new` given an `AccountInfo`, plain `transfer`, hardcoded `8 +` in `space`.
   - Clients keep amounts as `bigint`/`BN`, mix web3.js 1.x and `@solana/kit` types only through an interop layer ([kit-web3-interop.md](../skills/ext/solana-dev/skills/solana-dev/references/kit-web3-interop.md)), and regenerate the IDL client when the program interface changed (`/generate-idl-client`).
   - No hardcoded addresses or RPC URLs outside constants or config; no API keys in client code.
   - CU waste: `msg!` with formatting on hot paths; needless `.clone()` or `Vec` copies of account data.
   - Changed instructions have tests, including their failure paths.
3. AI slop: comments that restate the code; over-commented files; try/catch that only rethrows or swallows; defensive checks duplicating Anchor constraints; verbose errors leaking internals; dead helpers or copies of existing utilities; stubs and TODOs presented as finished; docs describing behavior the code does not have.
4. Capture learnings: when a Critical or Warning finding repeats a mistake already seen in this repo, or the user confirms a convention, append one line under `## Project Learnings` in the project instruction file (`CLAUDE.md`, or `AGENTS.md` in `--agents` installs). Skip one-off findings.

## Output

```
DIFF REVIEW: <branch> vs <base> | <n> files | +<added> -<removed>
CRITICAL (fix before merge): exploitable or fund-affecting, e.g. missing validation or signer, unchecked math on balances
WARNING (fix, or accept explicitly): hardcoded addresses, re-derived bumps, Token-2022 gaps, AI slop
INFO: CU and style suggestions, test gaps
Each finding: file:line | issue | fix | why
```

The branch is ready when Critical is empty and each Warning is fixed or accepted by the user.
