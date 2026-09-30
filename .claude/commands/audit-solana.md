---
description: "Audit Solana program code for exploitable bugs and write a findings report"
---

Audit the program(s) in $ARGUMENTS (default: every program in the workspace) for exploitable bugs. Secrets, dependencies, CI and webhooks around the program are `/audit-infra`.

## Read before auditing

- [security.md](../skills/ext/solana-dev/skills/solana-dev/references/security.md): vulnerability classes plus the program-side and Token-2022 checklists
- [solana-vulnerability-scanner](../skills/ext/trailofbits/plugins/building-secure-contracts/skills/solana-vulnerability-scanner/) (install first: `bash .claude/bin/skills.sh add trailofbits`): CPI, PDA, account-validation and instruction-introspection sweeps
- [safe-solana-builder](../skills/ext/safe-solana-builder/SKILL.md): audit-derived rules
- [programs/anchor.md](../skills/ext/solana-dev/skills/solana-dev/references/programs/anchor.md) and [programs/pinocchio.md](../skills/ext/solana-dev/skills/solana-dev/references/programs/pinocchio.md): framework-specific patterns

## Steps

1. Scope: list each instruction with its accounts and signers, and mark the ones that move funds or change authority. Review those first.
2. Automated pass: `cargo audit`; `cargo clippy --all-targets -- -W clippy::arithmetic_side_effects -W clippy::unwrap_used -W clippy::expect_used -W clippy::panic -D warnings`; `cargo geiger` if installed (unsafe usage); the test suite via `/test-rust`.
3. Per instruction, check:
   - **Owner**: every account read as state has its owner checked (`Account<T>` / `InterfaceAccount<T>` in Anchor); each `UncheckedAccount` or raw `AccountInfo` has a `/// CHECK:` whose claim the code enforces.
   - **Signer**: privileged actions require a signer that is tied to stored state (`has_one`, `address =`, or an explicit key compare).
   - **PDAs**: seeds are namespaced per account type and per user (no collisions); the bump is the stored canonical one.
   - **Type confusion**: discriminator checked (automatic for Anchor `Account<T>`, manual in Pinocchio/native).
   - **Duplicate mutable accounts**: Anchor 1.x rejects them unless marked `dup`, so review every `dup`; native/Pinocchio handlers taking two accounts of one type must compare keys.
   - **Other inputs**: `remaining_accounts` validated like named accounts; sysvars read through `Sysvar::get()` or address-checked; instruction introspection checks the program ID of the inspected instruction.
   - **Arithmetic**: checked math on every amount, `try_into` instead of narrowing `as`, division by zero, rounding in the protocol's favor.
   - **CPI**: target program fixed or validated; PDA signer seeds never passed to a caller-chosen program; accounts mutated by a CPI reloaded before reuse; no decisions on state read before the CPI.
   - **Tokens**: `transfer_checked` through `token_interface`; Token-2022 extensions handled where the mint may use them (transfer fees change the received amount, transfer hooks, permanent delegate, mint close authority).
   - **Lifecycle**: init cannot be replayed or front-run (config and admin init restricted to the upgrade authority or a known key); close zeroes data and drains all lamports (revival); realloc zeroes new space.
   - **Pinocchio/native**: `create_account` on a PDA fails if someone pre-funded it (use allocate + assign + transfer); zero-copy casts check length and alignment and never reference fields of `repr(packed)` structs; writable and signer flags enforced.
   - **Economics**: slippage bounds; oracle staleness and confidence; first-depositor or donation inflation of share prices; loops over caller-controlled lengths (CU exhaustion).
4. Fuzz programs that hold funds with Trident (`trident init`, then `trident fuzz run <target>`) and triage crashes. Hand missing tests (each error path and constraint failure) to solana-qa-engineer.
5. Deploy readiness: `anchor build --verifiable` succeeds; the upgrade-authority holder and plan, admin keys, emergency pause and security assumptions are documented; if CI has no security checks, suggest `/setup-ci-cd`.

## Output

Write `docs/security-audit-<YYYY-MM-DD>.md`:
- Summary: counts per severity (Critical, High, Medium, Low, Info)
- Each finding: severity, title, `file:line`, instruction, exploit scenario (who sends what, with which accounts), fix
- Unconfirmed suspicions in a separate "needs verification" list, not mixed with findings
- Tests run: unit, fuzz (duration), CU (`/profile-cu`)
- Verdict: ready for an external audit, or needs fixes

Recommend an external audit before mainnet for programs that hold user funds. Offer to fix Critical and High findings, then re-run on the changed code.
