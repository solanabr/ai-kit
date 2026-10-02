---
description: "Run Rust tests for programs (LiteSVM, Mollusk, Surfpool, Trident) and backends"
---

Run the project's Rust test suites and report each failure with its cause. `$ARGUMENTS` narrows the run (a package, test name, or filter passed to `cargo test`); empty means everything.

Harness setup and patterns: [testing.md](../skills/ext/solana-dev/skills/solana-dev/references/testing.md). Surfpool flags and cheatcodes: [surfpool/overview.md](../skills/ext/solana-dev/skills/solana-dev/references/surfpool/overview.md).

## Steps

1. Rebuild the program before running program tests: `NO_DNA=1 anchor build` or `cargo build-sbf`. LiteSVM and Mollusk load `target/deploy/<name>.so` (the Anchor LiteSVM template `include_bytes!`s it at compile time), so `cargo test` alone tests whatever binary was built last. `NO_DNA=1` turns off Anchor and Surfpool prompts and TUIs for agent runs.
2. Run the suite that fits:
   - Anchor 1.x: `anchor init` scaffolds Rust LiteSVM tests in `programs/<name>/tests/` with `[scripts] test = "cargo test"`. `NO_DNA=1 anchor test` builds, starts Surfpool, deploys, runs that script, and streams program logs to `.anchor/program-logs/`. In-process suites need no validator: `anchor test --skip-local-validator --skip-deploy` (newer `anchor init` writes `skip_local_validator = true` for you), or `cargo test -p <name>` after step 1.
   - Native or Pinocchio: `cargo test-sbf` builds the program and sets `SBF_OUT_DIR`, where `Mollusk::new(&id, "<name>")` finds `<name>.so` (it also searches `tests/fixtures` and the cwd).
   - Mollusk, for single-instruction and CU tests: `Check::compute_units(n)` expects exactly n, so assert a ceiling on `result.compute_units_consumed` yourself. `MolluskComputeUnitBencher` (run through `cargo bench`) writes `compute_units.md` with deltas.
   - Surfpool, for mainnet-fork state and cheatcodes: `NO_DNA=1 surfpool start` and point tests at `http://127.0.0.1:8899`, or embed `surfpool-sdk` so each suite owns its surfnet. Install with `curl -sL https://run.surfpool.run/ | bash`; the `surfpool` crate on crates.io is an unrelated package.
   - Fuzzing: Trident (`trident init` once, then `trident fuzz run fuzz_0`), or `anchor fuzz` (Crucible) on Anchor 1.2+. Give runs minutes to hours and assert invariants such as value conservation, not only "no panic".
   - Rust backends: `cargo test --workspace`; add `-- --test-threads=1` when tests share a database, and set `DATABASE_URL` for `#[sqlx::test]`.
3. Rerun only the failures: `cargo test <name> -- --exact --nocapture`.

## Reading failures

- LiteSVM `send_transaction` returns `Err(FailedTransactionMetadata)`: `e.err` is the transaction error and `e.meta.logs` holds the program logs. Read the logs before changing code.
- `custom program error: 0x...` is hex. In Anchor, 2000-2999 are constraint violations (2006 `ConstraintSeeds`: client and program disagree on seeds), 3000-3999 account errors (3012 `AccountNotInitialized`), 4100 `DeclaredProgramIdMismatch` (the test loaded the program at an address other than its `declare_id!`), and your `#[error_code]` variants at `offset` (default 6000) + discriminant: the variant's explicit `= N` if it sets one, else the previous variant's + 1.
- LiteSVM rejects a byte-identical transaction sent twice; call `svm.expire_blockhash()` between identical sends.
- `AccountNotFound` for a mainnet account under `anchor test`: Anchor starts Surfpool offline. Set `[surfpool] online = true` and `datasource_rpc_url` in Anchor.toml. Suites written for `solana-test-validator` can run with `anchor test --validator legacy`. Stop other local validators first, since both want port 8899.
- Toolchain and environment errors (platform-tools, GLIBC, the litesvm native binary): [common-errors.md](../skills/ext/solana-dev/skills/solana-dev/references/common-errors.md).

## Output

Per suite: passed, failed and ignored counts. Per failure: test name, decoded error, the log line that explains it, and whether the test or the program is wrong. Include CU figures when Mollusk checks ran. Next steps: [/test-and-fix](test-and-fix.md) to iterate on failures, `/benchmark` to compare CU against `.claude/benchmarks/cu-baseline.json`.
