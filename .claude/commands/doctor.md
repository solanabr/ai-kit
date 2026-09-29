---
description: "Read-only check of toolchain and kit config, with one fix-it command per failure"
model: sonnet
---

Run the eight checks below, then report. Status values: `OK` healthy, `WARN` works but fix soon, `FAIL` blocks workflows, `n/a` not applicable.

## Checks

**1. Core toolchain.** `node --version`, `npm --version`, `claude --version`. OK when all exist and node is 18+. Missing: `brew install node` / `npm install -g @anthropic-ai/claude-code`.

**2. Solana CLI and cluster.** `solana --version`; `solana config get | grep "RPC URL"`; `solana balance --url devnet`.
- WARN devnet balance 0: `solana airdrop 2 --url devnet`
- WARN cluster is mainnet during development: `solana config set --url devnet`
- FAIL no CLI: `sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"`

**3. Rust/Anchor toolchain** (`n/a` unless `Anchor.toml` or `programs/` exists). `rustc --version`, `cargo --version`, `anchor --version`, `avm --version`.
- FAIL no rustc/cargo: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- FAIL no anchor: `cargo install --git https://github.com/solana-foundation/anchor avm --force && avm install latest && avm use latest`
- WARN `anchor --version` differs from `anchor_version` in `Anchor.toml`: `avm use <version>`

**4. Git submodules.** `git submodule status`; lines starting with a space are OK.
- FAIL `-` prefix (uninitialized): `git submodule update --init --recursive`
- WARN `+` prefix (checkout differs from the recorded SHA): `git submodule update --recursive`, or `/resync` if intentional

**5. Environment keys.** Compare key names only; never print values.
```bash
comm -23 \
  <(grep -oE '^[A-Z_]+=' .env.example 2>/dev/null | sort -u) \
  <(grep -oE '^[A-Z_]+=' .env 2>/dev/null | sort -u)   # in .env.example, missing from .env
grep -E '^[A-Z_]+=$' .env 2>/dev/null | cut -d= -f1      # present but empty
```
- WARN key missing or empty: `/setup-mcp` (MCP keys) or edit `.env`
- FAIL no `.env`: `cp .env.example .env`, then `/setup-mcp`

**6. Kit version vs upstream.**
```bash
cat .claude/VERSION
# The mainnet gate is a file now; a missing one disarms every deploy check.
test -r .claude/bin/hooks/pre-deploy.sh && echo "GATE ok" || echo "GATE MISSING"
git ls-remote --tags --sort=-v:refname https://github.com/solanabr/ai-kit | head -3
```
- WARN behind the latest tag: `bash .claude/bin/update.sh`; preview with `--dry-run`
- FAIL no `VERSION` file (corrupted or pre-1.0 config): the same update command

**7. MCP config.**
```bash
python3 -c "import json; d=json.load(open('.mcp.json')); print('\n'.join(d.get('mcpServers', {}).keys()))" \
  2>/dev/null || echo "INVALID or missing .mcp.json"
if grep -q '"surfpool"' .mcp.json 2>/dev/null; then
  surfpool --version 2>/dev/null || echo "MISSING surfpool CLI"
fi
grep -q 'memsearch-mcp' .mcp.json 2>/dev/null && echo "RETIRED memsearch-mcp entry"
```
OK when it parses and lists the default servers (helius, solana-dev, context7) plus any the user added.
- FAIL parse failure: `curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/.mcp.json -o .mcp.json`
- WARN a listed server's API key failed check 5: `/setup-mcp`
- WARN `surfpool` listed but the CLI is missing: `curl -L https://surfpool.run/install | sh` (or `brew install txtx/taps/surfpool`)
- WARN `memsearch-mcp` listed: that npm package is not published, so the server never starts; delete the `memsearch` entry from `.mcp.json`

**8. Dual-install guard.** The plugin (`/plugin install solana-ai-kit@stbr`) and a full install (`install.sh` into `.claude/`) in the same project double-load commands, hooks and MCP servers (`/deploy` beside `/solana-ai-kit:deploy`, the banner printed twice).
```bash
PLUGIN_ON=$(grep -lE '"solana-ai-kit@[^"]*"[[:space:]]*:[[:space:]]*true' \
  .claude/settings.json "$HOME/.claude/settings.json" 2>/dev/null | head -1)
[ -f .claude/VERSION ] && echo "FULL_INSTALL present"
[ -n "$PLUGIN_ON" ] && echo "PLUGIN enabled (in: $PLUGIN_ON)"
```
OK with exactly one of the two, `n/a` with neither. WARN with both; the fix is to pick one: `/plugin uninstall solana-ai-kit` (keeps the full install's permissions/sandbox policy and ext/ submodules), or remove the project `.claude/` and rely on the plugin, which carries neither.

## Output

One table, then fix-its for the non-OK rows only, in the order to run them:

```
## Doctor Report - <date>

| # | Check              | Status | Detail                          |
|---|--------------------|--------|---------------------------------|
| 1 | Core toolchain     | OK     | node 22.x, npm 10.x, claude 2.x |
| 2 | Solana CLI         | WARN   | cluster=mainnet, devnet bal 0   |
| 3 | Rust/Anchor        | OK     | anchor 1.0.2 = Anchor.toml      |
| 4 | Submodules         | FAIL   | 2 uninitialized (-)             |
| 5 | .env keys          | WARN   | HELIUS_API_KEY empty            |
| 6 | Config version     | OK     | 2.1.0 = upstream                |
| 7 | MCP config         | OK     | 3 servers parsed                |
| 8 | Dual-install guard | OK     | full install only (no plugin)   |

### Fix-its (run in order)
1. `git submodule update --init --recursive`
2. `/setup-mcp`
3. `solana airdrop 2 --url devnet`
```

## Guardrails

- Read-only: never write, edit or delete files. Print fix-its for the user to run.
- Never print `.env` values, keypair contents or anything secret-shaped.
- Network use is limited to read-only lookups (`git ls-remote`, `solana balance`). Never airdrop, deploy or send transactions for the user.
- If a check errors unexpectedly, mark it `WARN` with the one-line error and run the remaining checks.
