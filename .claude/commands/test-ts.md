---
description: "Run TypeScript tests for programs (Anchor TS, Kit) and dApp frontends"
---

Run the project's TypeScript suites and report each failure with its cause. `$ARGUMENTS` narrows the run (a file, test name pattern, or workspace package); empty means everything.

Harness setup (Kit LiteSVM plugin, embedded Surfpool under vitest): [testing.md](../skills/ext/solana-dev/skills/solana-dev/references/testing.md). Client and wallet patterns: [frontend.md](../skills/ext/solana-dev/skills/solana-dev/references/frontend.md).

## Steps

1. If program code changed, rebuild it (`NO_DNA=1 anchor build`); if instructions or accounts changed, regenerate the client with `/generate-idl-client`. A stale IDL or client fails as discriminator or account-count errors.
2. Run the suite that fits:
   - Anchor TS tests (`tests/*.ts`). Anchor 1.x scaffolds them only with `anchor init --test-template mocha`; its default template is Rust LiteSVM (see `/test-rust`). `NO_DNA=1 anchor test` builds, starts Surfpool, deploys, and runs `[scripts] test` from Anchor.toml.
   - One test at a time: keep a surfnet up (`anchor test --detach` or `anchor localnet`), then `anchor run test -- --grep <pattern>` (`-t` for jest; keep the pattern free of spaces). `anchor run` exports the `ANCHOR_PROVIDER_URL` and `ANCHOR_WALLET` that `AnchorProvider.env()` reads. Typing the wallet path yourself trips the kit's secrets hook, which blocks commands naming `~/.config/solana/id.json`.
   - The Anchor TS package is `@anchor-lang/core`. Imports from `@coral-xyz/anchor`, including deep `dist/cjs/idl` imports, are pre-1.0 and need updating.
   - Kit program tests: `@solana/kit-plugin-litesvm` for in-process tests, `@solana/surfpool/kit` for an embedded surfnet per suite with `client.cheatcodes`. Run Surfpool-backed files serially (vitest `fileParallelism: false` or a separate config).
   - Frontend: the package's `test` script (vitest or jest). E2E: `npx playwright test`, or drive the running app through the Playwright MCP if it is configured (`/setup-mcp` adds it). Real wallet extensions need a persistent browser context and break when the wallet updates its popups, so for E2E register a test Wallet Standard wallet with `registerWallet()` from `@wallet-standard/wallet`, backed by a `@solana/kit` keypair behind a test-only flag, against localnet or devnet. The worked example is `kit/nextjs/tests/mock-wallet.ts` in [solana-foundation/templates](https://github.com/solana-foundation/templates/blob/main/kit/nextjs/tests/mock-wallet.ts): it starts with no connected accounts, so the real connect flow runs.
3. Rerun only the failing file or test name.

## Reading failures

- `@anchor-lang/core` throws `AnchorError` with `error.errorCode.code` (the variant name) and `logs`; for a `SendTransactionError`, `await err.getLogs(connection)`. `anchor test` also streams program logs to `.anchor/program-logs/`.
- Kit: a failed preflight is `SOLANA_ERROR__JSON_RPC__SERVER_ERROR_SEND_TRANSACTION_PREFLIGHT_FAILURE`, with logs in `e.context.logs` and the instruction error in `e.cause`. Codama clients export `is<Program>Error(e, ...)` for custom codes.
- Anchor error codes: 2000-2999 constraints (2006 seeds mismatch), 3000-3999 accounts (3012 not initialized), your `#[error_code]` variants at `offset` (default 6000) + discriminant: the variant's explicit `= N` if it sets one, else the previous variant's + 1.
- Kit returns `bigint` for u64 and lamports; compare with `1_000n`. Jest shows "Do not know how to serialize a BigInt" instead of the real assertion when a failing value is a bigint; rerun with `--runInBand` to see it.
- `AccountNotFound` for mainnet accounts under `anchor test`: Anchor starts Surfpool offline; set `[surfpool] online = true` and `datasource_rpc_url` in Anchor.toml. `ECONNREFUSED ::1:8899`: use `127.0.0.1`, not `localhost`. Other environment errors: [common-errors.md](../skills/ext/solana-dev/skills/solana-dev/references/common-errors.md).

## Output

Per suite: passed, failed and skipped counts. Per failure: test name, decoded error, the log line that explains it, and whether the test or the code is wrong. Use [/test-and-fix](test-and-fix.md) to iterate on failures.
