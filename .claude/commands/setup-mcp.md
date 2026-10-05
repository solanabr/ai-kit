---
description: "Configure MCP server API keys in .env and add the optional MCP servers"
model: sonnet
---

Walk the user through filling in `.env`. Secrets go in `.env`, never in `.mcp.json`.

Never read `.env` — the firewall denies it at Medium and High, and a value read into the transcript has already left the machine. Appending is the only contact this command has with the file.

## Steps

1. Don't create `.env` yourself. If it may be missing, print this for the user to run and wait for them:
   ```bash
   cp .env.example .env
   ```
2. See which keys are already set, by name only:
   ```bash
   bash .claude/bin/env-keys.sh 2>/dev/null || echo "HELPER_UNAVAILABLE"
   ```
   It prints one `KEY set|empty` line per key and never a value. Skip keys it reports as `set` unless the user asks to replace one; for a replacement, print the edit for the user to make rather than rewriting the file. On `HELPER_UNAVAILABLE`, ask which keys they want to set instead of guessing.
3. For each remaining key below, in order, ask the user to paste a value or say "skip". Append accepted values; leave skipped keys alone; never echo a value back.
   ```bash
   printf '%s=%s\n' "$KEY" "$VALUE" >> .env
   ```
   Append, never read-modify-write: there is nothing to read first. If the append is refused (Medium denies `.env` writes), print the line for the user to run.

   MCP server key (the only one `.mcp.json` reads):
   - `HELIUS_API_KEY`: Helius RPC and DAS API for the `helius` MCP server (https://dev.helius.xyz)

   Optional skill/CLI keys, read at runtime by skill CLIs in `.claude/skills/ext/`, not by any MCP server:
   - `MISTRAL_API_KEY`: QEDGen formal-verification CLI, for `fill-sorry` and `generate` (https://console.mistral.ai)
   - `ARISTOTLE_API_KEY`: QEDGen formal-verification CLI, for the `aristotle` proof-search commands (https://aristotle.harmonic.fun)
   - `THEGRID_API_KEY`: TheGrid Colosseum project-graph queries (https://thegrid.id)
   - `THEGRID_GRAPHQL_ENDPOINT`: the default `https://beta.node.thegrid.id/graphql` works for most
   - `QUICKNODE_RPC_URL`, `QUICKNODE_WSS_URL`, `QUICKNODE_API_KEY`: QuickNode RPC, WebSocket/Streams and DAS for the `quicknode` skill (https://www.quicknode.com)
   - `X_BEARER_TOKEN`: X API bearer token for the `ct-alpha` CT research skill (https://developer.x.com)
   - `DFLOW_API_KEY`: DFlow order-flow integration skill (credentials from hello@dflow.net)

   Not an env key: the core `colosseum` skill signs in through its own helper, which keeps the credential in the OS store. If the user wants it working now, have them run `npx @colosseum-org/copilot-connect login` (Node 20+; `--device` where no browser can open) and check it with `status`. Never ask for a `COLOSSEUM_COPILOT_PAT` — that mechanism is retired.
4. Ask which optional MCP servers to add; the default is none, since each one starts with every session. Print the command for each one the user picks, for them to run — `Bash(claude *)` is denied at every firewall tier, since a nested `claude` re-rolls the whole policy. Each adds the server for this user and project only; append `--scope project` only if the user wants to share it through `.mcp.json`.
   - Playwright, browser automation (needs a browser Playwright can launch): `claude mcp add playwright -- npx -y @playwright/mcp@latest --headless`
   - Chrome DevTools, real performance traces and Core Web Vitals off a running page: `claude mcp add chrome-devtools -- npx -y chrome-devtools-mcp@1.10.1`. Google's own server (Apache-2.0, published on npm). It drives a Chrome instance, so it reads and acts on whatever that browser can reach, including any session the user is signed into — offer it for performance work against a local dev server, not as a default extra. Pin the version as above rather than `@latest`, so an upstream change cannot alter what attaches.
   - Surfpool, local validator and mainnet-fork control: `claude mcp add surfpool -- surfpool mcp`. It needs the `surfpool` CLI on PATH; check with `command -v surfpool`, and if it is missing give the user the install command (`curl -L https://surfpool.run/install | sh` or `brew install txtx/taps/surfpool`) rather than running it.
   - Chainstack, multi-chain RPC platform control: `claude mcp add --transport http chainstack https://mcp.chainstack.com/mcp`. It needs a key from https://console.chainstack.com/user/settings/api-keys for most of what it does — node deployment, project management and testnet funding — passed as `--header "Authorization: Bearer <key>"` on that command. Five read-only tools (docs search, platform status, pricing) answer without one. Every tool is listed either way, so a keyless install looks complete and fails at the call; say which half works before the user adds it.
   - Supabase, the Postgres backend behind an indexer or dApp. Offer the read-only, project-scoped form first, as the recommended default: `claude mcp add --transport http supabase "https://mcp.supabase.com/mcp?read_only=true&project_ref=<ref>"`. Say what each parameter does and let the user choose — `read_only=true` hides the 12 write tools and forces `execute_sql` into a read-only Postgres session; `project_ref` drops the whole `account` group, which is what removes cross-project reach and `create_project`. Unflagged, `DEFAULT_FEATURES` gives 31 tools of which 12 write (36 exist, 13 of them not read-only). If the user wants write access — applying a migration, seeding a table — give them the form without the parameters they don't want, and tell them what it reaches: `execute_sql` is an unrestricted SQL channel into the app's database, `DROP`, `DELETE` and `TRUNCATE` included with no statement filtering, and `apply_migration` is the same reach with DDL. `create_project` and `create_branch` also spend money, branches hourly-billed on paid plans. Which form fits is the user's call; make it an informed one rather than a narrow one. Quote the path exactly: `https://mcp.supabase.com/mcp` is the server, `https://mcp.supabase.com/api/mcp` is a documentation page. There is no keyless half to try first — `POST initialize` answers 401 even with `?features=docs` — so the user authenticates through the flow the server starts. `?features=docs` alone narrows it to documentation lookup, which is what Supabase's own repository pins in its `.mcp.json`. For the stdio form, `npx -y @supabase/mcp-server-supabase@latest --read-only --project-ref=<ref>`: its `SUPABASE_ACCESS_TOKEN` is an account-wide personal access token reaching every organization and project the user belongs to, and `--project-ref` narrows what the server does with it rather than what the token can do — a wider credential than the HTTP form needs, whichever tool set they pick.
   - Cloudflare, operating the Workers, KV, R2, D1, DNS and Queues behind a dApp: `claude mcp add --transport http cloudflare https://mcp.cloudflare.com/mcp --header "Authorization: Bearer <token>"`. Tell the user what they are attaching before they run it: the server exposes the entire Cloudflare API (2,594 endpoints) through three tools, because the OpenAPI spec stays server-side and the agent writes JavaScript against it — `docs` searches Cloudflare's developer docs, `search` queries `spec.paths` to find endpoints, and `execute` calls `cloudflare.request()`. That last one is not read-only: it reaches whatever the token reaches, deploying Workers, editing DNS records and purging Queues included. So the hardening here is the credential, not a query parameter: have the user create an API token at https://dash.cloudflare.com/profile/api-tokens scoped to the specific zone or account resources they want reachable, rather than reusing a broad one, and for an account token add `Account Resources : Read` so the server can auto-detect the account ID. Dropping the `--header` uses OAuth instead, which asks them to pick permissions on Cloudflare's consent screen — fine interactively, but it leaves no artifact to review later. Have the user paste the token into their own command; don't ask for it here. Keep the `?codemode=false` form out of it unless they ask — it registers ~2,500 individual tools and costs ~244k tokens against ~1.1k for the three. Nothing answers unauthenticated (`POST initialize` returns 401), and tokens with Client IP Address Filtering enabled are unsupported. The kit's pinned `cloudflare` skill pack is the no-credential alternative when the user wants to write Worker code rather than change what is deployed.
   - Phantom, a wallet and trading surface: `claude mcp add phantom -- npx -y @phantom/mcp-server`. Say what the 29 tools are before the user adds it, since this is the one server here that acts on funds rather than reporting on them: `solana_sign`/`solana_send` and `evm_sign`/`evm_send` land signed transactions, and `buy`, `pay`, `transfer`, `wallet_rebalance`, `withdraw_from_hyperliquid_spot` and nine `perps_*` tools (open, close, leverage, deposit, withdraw) move real funds. It takes no key — `phantom_login` authenticates and keeps the session on disk — so after that first login nothing re-prompts between the server and a trade, and no firewall tier denies its tools by name. Offer it for wallet, payment or trading work, and say that the boundary is what the logged-in wallet holds.
   - Nansen, wallet and token intelligence: `claude mcp add --transport http nansen https://mcp.nansen.ai/ra/mcp --header "NANSEN-API-KEY: <key>"`. Paid product: the server answers nothing without a key (a free API account at https://app.nansen.ai works within its credit limits; premium data needs a paid plan). It is also heavy — around 50 tool schemas load into context in every session it is attached to — so suggest it only when the user wants on-chain analytics, not as a default extra. Have the user paste the key into their own command; don't ask them to send it here.

   context-mode ships in `.mcp.json` as a default server, so it is not offered here.

## Output

Configured or skipped for each key (names only — nothing in this command ever holds a value past the append), grouped as MCP and skill/CLI, then the commands printed for the optional servers, then remind the user to restart Claude Code so the changes are picked up.
