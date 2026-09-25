---
description: "Migrate TypeScript from @solana/web3.js 1.x to @solana/kit"
---

Migrate `@solana/web3.js` 1.x code to `@solana/kit`. `$ARGUMENTS` can limit the scope to paths or packages; empty means the whole repo.

Read first: [kit-web3-interop.md](../skills/ext/solana-dev/skills/solana-dev/references/kit-web3-interop.md) (choosing the target, dependency boundaries) and [kit/overview.md](../skills/ext/solana-dev/skills/solana-dev/references/kit/overview.md) (the current plugin-client API). Detailed mappings and edge cases: [solana-kit-migration](../skills/ext/sendai/skills/solana-kit-migration/SKILL.md), with its `resources/api-mappings.md` and `docs/edge-cases.md` (install first: `bash .claude/bin/skills.sh add sendai`). Where it disagrees with kit/overview.md (older type names, no plugin client), follow kit/overview.md.

## Steps

1. Inventory: run the migration skill's `scripts/analyze-migration.sh <path>`, or grep for `@solana/web3.js` and `@solana/spl-token` imports outside `node_modules`. List the dependencies that need v1 objects (`Connection`, sync `Keypair`), such as the Anchor TS client, wallet-adapter and protocol SDKs.
2. Agree the target with the user:
   - Kit plugin client (`createClient().use(...)`) for code you own.
   - web3.js v3 (`@solana/web3.js@rc`, the v1 classes rebuilt on Kit) as a stepping stone for a large v1 codebase. It is a release candidate, so pin exact versions; its official migration skill is linked from kit-web3-interop.md.
   - Code that must keep v1 objects stays behind one adapter module that converts at the seam with `@solana/compat` (`fromLegacyPublicKey`, `fromLegacyKeypair`, `fromLegacyTransactionInstruction`, `fromVersionedTransaction`).
3. Migrate leaf utilities first, then shared modules, then pages and entry points. Run `npx tsc --noEmit` after each file and the tests after each module.
4. Finish when no `@solana/web3.js` import remains outside the adapter, tests pass, and unused packages are gone from package.json.

## Mappings that commonly go wrong

| web3.js 1.x | @solana/kit |
|---|---|
| `new Connection(url)` | `createClient().use(solanaRpc({ rpcUrl }))`, or `createSolanaRpc(url)` + `createSolanaRpcSubscriptions(wsUrl)`; raw RPC calls end in `.send()` |
| `new PublicKey(s)`, `.equals()` | `address(s)`: a branded string, compared with `===` |
| `Keypair.generate()`, `Keypair.fromSecretKey(b)` | `await generateKeyPairSigner()`, `await createKeyPairSignerFromBytes(b)` (async, WebCrypto) |
| `new Transaction()` + `sendAndConfirmTransaction` | `client.sendTransaction([ix])`, or `pipe(createTransactionMessage({ version: 0 }), ...)`, then `signTransactionMessageWithSigners` and `sendAndConfirmTransactionFactory({ rpc, rpcSubscriptions })` |
| `TransactionInstruction` | the `Instruction` type (`IInstruction` is the old name) |
| `SystemProgram.transfer` | `getTransferSolInstruction` from `@solana-program/system` |
| `@solana/spl-token` | `@solana-program/token` or `@solana-program/token-2022` (Codama-generated) |
| `number` lamports, `LAMPORTS_PER_SOL` | `bigint`: `lamports(1_000_000_000n)`, `solToLamports(sol('1.5'))`; RPC numbers come back as `bigint` |
| `bs58` | `getBase58Codec()` |
| `@solana/wallet-adapter-*` | `@solana/kit-plugin-wallet` (hooks in `/react`) with `@solana/react`; see [frontend.md](../skills/ext/solana-dev/skills/solana-dev/references/frontend.md) |
| `@coral-xyz/anchor` | `@anchor-lang/core`, which still uses v1 types: keep it behind the adapter or replace it with a Codama client (`/generate-idl-client`) |

web3.js 1.x cannot send v1 transactions. Kit plugin clients default to v0; moving to v1 is a separate decision that depends on wallet support: [transactions-v1.md](../skills/ext/solana-dev/skills/solana-dev/references/transactions-v1.md).

## Output

Files migrated, remaining web3.js usage with the reason for each, dependency changes, typecheck and test results.
