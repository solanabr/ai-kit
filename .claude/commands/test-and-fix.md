---
description: "Run tests, auto-fix fmt and lint, and fix failures until green or stuck"
---

Loop test, diagnose, fix, retest until the suite passes or a stop condition hits. `$ARGUMENTS` limits the scope (a package, test name, or path); empty means the whole project.

## Steps

1. Run the tests the way [/test-rust](test-rust.md), [/test-ts](test-ts.md) or [/test-dotnet](test-dotnet.md) does for this stack, rebuilding the program first so tests do not run a stale `.so`. Record every failure.
2. Apply the mechanical fixes, then rerun:
   - Rust: `cargo fmt --all`, then `cargo clippy --fix --allow-dirty --allow-staged --all-targets`, then `cargo clippy --all-targets -- -D warnings` for what clippy cannot fix itself.
   - TypeScript: the project's prettier and `eslint --fix` scripts. C#: `dotnet format`.
3. Take the remaining failures one root cause at a time. Classify before editing:
   - Environment or toolchain (platform-tools, GLIBC, port 8899 in use, missing keypair): see [common-errors.md](../skills/ext/solana-dev/skills/solana-dev/references/common-errors.md).
   - Stale artifacts: `InstructionFallbackNotFound` (101) or `AccountDiscriminatorMismatch` (3002) right after a program change usually means an old `.so`, IDL or generated client. Rebuild and rerun `/generate-idl-client`.
   - Program errors: decode `custom program error: 0x...` from hex. Anchor 2000-2999 are constraints (2006 seeds differ between client and program), 3000-3999 account errors (3012 not initialized), your `#[error_code]` variants at `offset` (default 6000) + discriminant: the variant's explicit `= N` if it sets one, else the previous variant's + 1. Anchor 1.x also rejects duplicate mutable accounts unless the field is marked `dup`.
   - Test or program: decide which side encodes the intended behavior before editing either.
4. Rerun after each fix. Stop and report when everything passes, when the same failure survives two different fixes, after five rounds, or when the next fix would change program behavior, an instruction's interface, or a security check.

## Guardrails

- Do not delete, skip or `#[ignore]` tests, loosen assertions, or remove account constraints to get green. If a test is wrong, say why before changing it.
- A program-ID mismatch from `anchor build` in an existing repo usually means the deploy keypair is missing from `target/deploy/`. Build with `anchor build --ignore-keys` and ask the user for the keypair. `anchor keys sync` rewrites `declare_id!` to a new address, which is only right for a program that was never deployed.
- Failures that only reproduce against real cluster state belong to `/debug-user-tx`.

## Output

Per round: what failed, its classification, the fix (file and line), and the result. End with final pass/fail counts and, for anything still failing, the reason you stopped.
