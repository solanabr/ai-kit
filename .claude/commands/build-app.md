---
description: "Build the web client (Next.js, Vite, React) and check env, types and bundle"
---

Build the web client in $ARGUMENTS (default: the app directory whose `package.json` has a `build` script) for the cluster its program is deployed on. Current client patterns: [frontend.md](../skills/ext/solana-dev/skills/solana-dev/references/frontend.md).

## Steps

1. Install with the package manager that owns the lockfile (`pnpm-lock.yaml`, `yarn.lock`, `bun.lock`/`bun.lockb`, `package-lock.json`), in frozen mode (`npm ci`, `pnpm install --frozen-lockfile`).
2. Env: don't read or copy `.env*`. If `.env.local` is missing, print `cp .env.example .env.local` for the user to run. The firewall covers `.env.local` under the same rules as `.env`, deliberately — it holds the same values. For what is set, use names and presence only (`bash .claude/bin/env-keys.sh .env.local`); for the program ID, compare `.program-id-devnet` / `.program-id-mainnet` (written by `/deploy`) against what the app logs at runtime, and ask the user to confirm the cluster rather than reading the RPC URL. If the program interface changed, regenerate the client first with `/generate-idl-client`.
3. Type-check with `tsc --noEmit`: Vite builds do not type-check, `next build` does. Run the `lint` script if there is one.
4. Build with `<pm> run build`. Output: `.next/` (Next.js), `dist/` (Vite), `build/` (CRA).
5. Verify: no `*.map` files in the production output unless intended; note the largest JS chunks; preview with `<pm> run start` (Next.js) or `<pm> run preview` (Vite).

## Failure fixes

- `Buffer is not defined` (Vite): add `vite-plugin-node-polyfills` with `nodePolyfills({ include: ['buffer'] })`. web3.js 1.x, the Anchor TS client (`@anchor-lang/core`) and wallet-adapter need it; `@solana/kit` does not.
- `window is not defined` or hydration errors (Next.js): wallet and web3 code belongs in `'use client'` leaf components.
- Env var undefined in the browser: client-side vars need the `NEXT_PUBLIC_` or `VITE_` prefix, and a rebuild, because they are inlined at build time.
- Oversized bundle: lazy-load wallet UI and heavy SDKs; drop `@solana/wallet-adapter-wallets` bundles, since Wallet Standard wallets register themselves; prefer `@solana/kit` over web3.js 1.x for new code.

## Guardrails

- Every `NEXT_PUBLIC_` / `VITE_` value ships in the bundle. Keep RPC URLs that embed an API key (Helius and similar) behind a server route.
- Never print an env value, including an RPC URL that embeds a key. Report key names and whether they are set.

## Output

Framework, package manager, output directory and size, largest chunks, and the env/cluster check result.
