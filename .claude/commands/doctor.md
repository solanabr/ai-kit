---
description: "Read-only check of toolchain and kit config, with one fix-it command per failure"
model: sonnet
---

Run the eleven checks below, then report. Status values: `OK` healthy, `WARN` works but fix soon, `FAIL` blocks workflows, `n/a` not applicable.

## Checks

**1. Core toolchain.** `node --version`, `npm --version`. OK when both exist and node is 18+. Missing: `brew install node` / `npm install -g @anthropic-ai/claude-code`. Report the Claude Code version as `unknown` rather than running `claude --version` — `Bash(claude *)` is denied at every firewall tier (a nested `claude` re-rolls the whole policy); the user sees it in `/status`.

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

**5. Environment keys.** Expected names come from `.env.example`, which is tracked and holds no values. What is actually set comes from the names-and-presence helper, which prints one `KEY set|empty` line per key and never a value. Do not read `.env` — safe-ai-skill denies it while it is on, High denies it regardless, and a value read into the transcript has already left the machine.
```bash
grep -oE '^[A-Z_]+=' .env.example 2>/dev/null | tr -d = | sort -u   # expected names
bash .claude/bin/env-keys.sh 2>/dev/null || echo "HELPER_UNAVAILABLE"
```
The core `colosseum` skill is the one credential that is not an env key: it signs in through a helper that keeps the token in the OS store. Check it the same way the skill does, which neither reads nor prints a credential:
```bash
npx --yes @colosseum-org/copilot-connect status 2>&1 | tail -3 || echo "HELPER_UNAVAILABLE"
```
- `n/a` when there is no network or npx is unavailable.
- WARN no connection: `npx @colosseum-org/copilot-connect login` (Node 20+; `--device` where no browser can open). Until then the colosseum skill has nothing to query.
- `n/a — skipped (firewall tier denies .env reads)` when the helper is missing or exits non-zero: list the expected names and stop. A gate doing its job is never a `FAIL`.
- WARN key missing or empty: `/setup-mcp` (MCP keys) or edit `.env` by hand
- FAIL the helper reports no `.env` at all: `cp .env.example .env`, then `/setup-mcp`

**6. Kit version vs upstream.**
```bash
cat .claude/VERSION
git ls-remote --tags --sort=-v:refname https://github.com/solanabr/ai-kit | head -3
```
- WARN behind the latest tag: `/update`, or from a shell `SOLANA_AI_KIT_BRANCH="$(bash .claude/bin/kit-ref.sh)" bash .claude/bin/update.sh` (`.agents/bin/` for `--agents` installs); preview with `--dry-run`
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
- WARN `memsearch-mcp` listed: that npm package is not published, so the server never starts; delete the `memsearch` entry from `.mcp.json`. memsearch ships as a Claude Code plugin instead (`/plugin marketplace add zilliztech/memsearch`, `/plugin install memsearch`, then restart Claude Code)

**8. Dual-install guard.** The plugin (`/plugin install solana-ai-kit@stbr`) and a full install (`install.sh` into `.claude/`) in the same project double-load commands, hooks and MCP servers (`/deploy` beside `/solana-ai-kit:deploy`, the banner printed twice).
Detect it from the project config alone. `$HOME/.claude/settings.json` is outside the working directory, so High's read fence refuses it.
```bash
[ -f .claude/VERSION ] && echo "FULL_INSTALL present"
grep -qE '"solana-ai-kit@[^"]*"[[:space:]]*:[[:space:]]*true' .claude/settings.json 2>/dev/null \
  && echo "PLUGIN enabled (project scope)"
[ -f .claude/VERSION ] && [ -f .agents/VERSION ] && echo "DUAL_INSTALL .claude/ and .agents/"
```
OK with exactly one of the two, `n/a` with neither. WARN with both; the fix is to pick one: `/plugin uninstall solana-ai-kit` (keeps the full install's permissions/sandbox policy and ext/ submodules), or remove the project `.claude/` and rely on the plugin, which carries neither. Report user-scope enablement as `unknown` whenever check 9 shows the read fence on — a plugin enabled only in `~/.claude/settings.json` is invisible then, and `/plugin` is where the user can see it.
`DUAL_INSTALL` (a regular install beside an `--agents` one) is OK and works, but add one line to the report naming which side is governed, since this is where symmetry gets assumed: the rules, sandbox and hooks in `.claude/settings.json` bind Claude Code sessions only, and Codex, opencode or any other harness reading `.agents/` runs against the same repo, keys and clusters with none of them. There is no fix to offer.

**9. Firewall tier.** `.claude/security.json` declares the tier; `bash .claude/bin/firewall.sh apply` writes the generated `permissions` + `sandbox` block into `.claude/settings.json` and records the exact rule strings it wrote in `enforced.ruleIds`. Read both files, edit neither.
```bash
python3 - <<'PY'
import json, pathlib
def load(p):
    f = pathlib.Path(p)
    return json.loads(f.read_text()) if f.is_file() else {}
def fence(d):
    for src in (d.get("permissions") or {}, d):
        if "blockReadsOutsideWorkingDirectories" in src:
            return src["blockReadsOutsideWorkingDirectories"]
sec, cfg = load(".claude/security.json"), load(".claude/settings.json")
loc = load(".claude/settings.local.json")
perms = cfg.get("permissions") or {}
sb = cfg.get("sandbox") or {}
live = {r for k in ("deny", "ask", "allow") for r in (perms.get(k) or [])}
live |= set(sb.get("excludedCommands") or [])
live |= set((sb.get("network") or {}).get("deniedDomains") or [])
for k in ("denyRead", "allowRead", "denyWrite", "allowWrite"):
    live |= set((sb.get("filesystem") or {}).get(k) or [])
enf = sec.get("enforced") or {}
rec = set(enf.get("ruleIds") or [])
print("declared:", sec.get("tier") or (sec.get("declared") or {}).get("tier") or "none")
print("enforced:", enf.get("tier") or "none")
print("live_rules:", len(live), "recorded:", len(rec), "absent:", len(rec - live))
print("fence:", fence(cfg), "fence_local:", fence(loc))
print("sandbox:", (cfg.get("sandbox") or {}).get("enabled"), "sandbox_local:", (loc.get("sandbox") or {}).get("enabled"))
print("full_install:", pathlib.Path(".claude/VERSION").is_file())
print("config_dir:", pathlib.Path(".claude/VERSION").parent.name)
want = 0
for line in (pathlib.Path(".claude/bin/firewall.sh").read_text().splitlines()
             if pathlib.Path(".claude/bin/firewall.sh").is_file() else []):
    if line.startswith("RULE_SET_VERSION"):
        want = int("".join(c for c in line.split("=", 1)[1] if c.isdigit()) or 0)
        break
print("rule_set:", enf.get("ruleSetVersion") or 0, "shipped:", want)
mcp = [r for r in (perms.get("deny") or []) if r.startswith("mcp__")]
print("mcp_denies:", len(mcp))
PY
```
These states look alike and are not. Read them in this order; stop at the first that matches.
- `n/a` `config_dir: .agents`: an `--agents` install, which ships no `security.json`, no firewall and no `settings.json`, because no harness parses permission rules or a hooks array under `.agents/`. There is no tier to check and nothing to fix; enforcement needs a regular install run under Claude Code.
- FAIL declared or enforced `maintainer`: **the kit's maintainer tier is in force**, so the agent can rewrite the guard hooks in `.claude/hooks/` and start a nested `claude` with no policy, and `git submodule` runs unsandboxed. It exists only for working on the solana-ai-kit repository itself. Lead the whole report with this row, above the table, even in the kit repo: it is easy to forget once the kit work is done, and the next commit would fail `validate.sh` on it. Fix: `bash .claude/bin/firewall.sh apply relaxed`
- `n/a` declared `off`: the user chose no firewall. Nothing is generated and nothing is wrong — do not offer a fix.
- WARN `live_rules: 0` and `full_install: False`: this is the plugin path — the plugin ships `hooks/hooks.json` only, so no permission or sandbox policy is installable and no tier applies. Hooks still gate deploys. For a tier, do a full install: `bash <(curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh)`
- FAIL `live_rules: 0` and `full_install: True`: a full install whose `settings.json` lost its policy block. Regenerate: `bash .claude/bin/firewall.sh apply`
- WARN `live_rules` > 0 and `declared: none`: rules are present but no tier is recorded — an install from before the firewall. Pick the default: `/firewall relaxed`
- WARN declared `high` and `fence_local: False` (or `sandbox_local: False`): `.claude/settings.local.json` outranks the project file for both, so High's read fence is off and its guarantee is not in force. Drop the override: `python3 -c "import json;p='.claude/settings.local.json';d=json.load(open(p));(d.get('permissions') or {}).pop('blockReadsOutsideWorkingDirectories',None);d.pop('blockReadsOutsideWorkingDirectories',None);(d.get('sandbox') or {}).pop('enabled',None);json.dump(d,open(p,'w'),indent=2)"`
- FAIL `declared` ≠ `enforced`: a tier was declared but the generated rules are still the old tier's. Re-apply: `bash .claude/bin/firewall.sh apply`
- FAIL `absent` > 0: rules the last apply recorded are missing from `settings.json` — hand-edited, or a partial merge. Same fix: `bash .claude/bin/firewall.sh apply`
- WARN `rule_set` < `shipped`: the tier was generated by an older rule set, so rules added since then are not in force. Below 2, `medium`/`high` are not denying `context-mode`'s code executor; below 3, no tier is denying edits to `.safe-ai-skill/policy.yaml`; below 4, `high` is not denying Cloudflare's `execute`; below 5, no tier is denying the `--receive-pack`/`--upload-pack`/`--exec` git transport overrides or `gh issue delete`, and `medium`/`high` are not denying `gh api`; below 6, no tier is denying `gh repo delete` or `git config alias.*` (a git alias makes the dangerous verb vanish from every later command line), and `medium`/`high` are not denying Playwright's `browser_run_code_unsafe` and `browser_network_request`, nor `high` its `browser_evaluate`; below 7, no tier is denying `git --config-env` (the `git -c` code-execution route reading its value from an environment variable) or `git reflog delete`/`drop`, and `high` is not denying the file tools a repository's `.git/config` and `.git/hooks/`; below 8, `medium` is not denying writes to the project's `.env` and its variants, nor `high` reads of them. `/update` re-applies automatically; to do it now: `bash .claude/bin/firewall.sh apply`
- WARN declared `medium` or `high` and `mcp_denies: 0`: the MCP executor denies are missing for a tier that should have them. Same fix: `bash .claude/bin/firewall.sh apply`. `medium` carries 7 of them and `high` 9 — the two extra are `mcp__cloudflare__execute` and `mcp__playwright__browser_evaluate`, which `high` denies and `medium` deliberately does not. The count does not depend on which servers are attached: a tool-name deny is a string in `settings.json` either way.
- OK otherwise: report the tier and the rule count.

Whatever the row, a tier change only binds the next session: permission rules are read at session start.

**10. Fetch-and-execute guard.** `.claude/hooks/fetch-exec-guard.sh` gates `npx -y <stranger>`, `pnpm dlx`, `uvx`, `pipx run`, `cargo install` and `go install pkg@version` when the package is not a declared dependency — reporting at Relaxed and Medium, denying at High. The exception at High is `KIT_FETCH_EXEC_ALLOW` in that script: the packages the kit's own commands invoke (`create-solana-dapp`, `codama`, `shank-cli`, `avm` from Anchor's git repo and four more) are reported there rather than denied, matched on the exact name within one ecosystem. It is the only implementation route for gating `cargo install`, which sits in `permissions.allow` at every tier. The script is enforcement, the `hooks` entry in `settings.json` is what runs it, and `/update` delivers the first without ever rewriting the second (issue #91), so the two can disagree.
```bash
python3 - <<'PY'
import json, pathlib
def load(p):
    f = pathlib.Path(p)
    return json.loads(f.read_text()) if f.is_file() else {}
pre = ((load(".claude/settings.json").get("hooks") or {}).get("PreToolUse") or [])
def has(name):
    return any(name in (h.get("command") or "") for e in pre for h in (e.get("hooks") or []))
print("registered:", has("fetch-exec-guard"))
print("older_guards:", sum(has(g) for g in ("secrets-guard", "onchain-guard", "egress-guard")))
print("script:", pathlib.Path(".claude/hooks/fetch-exec-guard.sh").is_file())
print("full_install:", pathlib.Path(".claude/VERSION").is_file())
print("config_dir:", pathlib.Path(".claude/VERSION").parent.name)
PY
```
Read these in order; stop at the first that matches.
- `n/a` `config_dir: .agents`: an `--agents` install has no `settings.json` to register the guard in (check 9 says why). The script is on disk and runs only if the user wires it into their own harness.
- `n/a` `full_install: False`: the plugin path. The plugin's own `hooks/hooks.json` carries the guard, so there is nothing in the project to register and nothing wrong.
- OK `registered: True`: the gate is live. Report the tier it is acting at (check 9).
- WARN `registered: False` and `older_guards: 0` and `full_install: True`: no kit guard is registered at all, so the `hooks` array was emptied or rewritten by hand — **removed on purpose**. Report it and offer no fix; re-adding something the user deleted is not a repair.
- WARN `registered: False`, `older_guards: 3`, `script: False`: an install predating the guard that has not updated yet. `bash .claude/bin/update.sh` first, then the fix below.
- WARN `registered: False`, `older_guards: 3`, `script: True`: **this install predates the guard.** `/update` copied the script in but leaves `settings.json` alone, so the script is sitting there inert. Register it (this rewrites `settings.json` with standard JSON formatting, so hand-made spacing is lost):
```bash
python3 - <<'PY'
import json
p = ".claude/settings.json"
d = json.load(open(p))
cmd = 'H="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/fetch-exec-guard.sh"; [ -r "$H" ] && exec sh "$H"; exit 0'
d.setdefault("hooks", {}).setdefault("PreToolUse", []).append(
    {"matcher": "Bash|mcp__context-mode__.*",
     "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
json.dump(d, open(p, "w"), indent=2)
PY
```
- WARN anything else (`older_guards` 1 or 2): the array is partly hand-edited. Say which guards are missing and let the user decide; do not rewrite it.

One ambiguity this check cannot resolve: `older_guards: 3` with this one guard surgically removed looks exactly like an install that predates it. It is reported as "predates", so if the removal was deliberate, ignore the row — or set the firewall tier to `off`, which disables every guard explicitly.

**11. safe-ai-skill.** The kit's security plugin: it gates mainnet, authority and value-moving actions, MCP tools included, and pins skills and MCPs at session start. A full install enables it in `.claude/settings.json`, but Claude Code installs a plugin from an external source only when each user runs the install, so "enabled" and "installed" are separate questions. Claude Code's install list is an internal file, read best-effort; never run `claude` here.
```bash
python3 - <<'PY'
import json, os, pathlib, platform
def load(p):
    return json.loads(pathlib.Path(p).read_text())
pid = "safe-ai-skill@stbr"
enabled = None
for f in (".claude/settings.json", ".claude/settings.local.json"):  # the local file wins
    try:
        v = (load(f).get("enabledPlugins") or {}).get(pid)
    except (OSError, ValueError):
        continue
    if v is not None:
        enabled = v
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
here = os.path.realpath(".")
try:
    recs = (load(os.path.join(cfg, "plugins", "installed_plugins.json")).get("plugins") or {}).get(pid, [])
    hits = [r for r in recs if r.get("scope") == "user" or os.path.realpath(r.get("projectPath") or "/nonexistent") == here]
    installed = ", ".join("%s@%s" % (r.get("scope"), (r.get("gitCommitSha") or "?")[:7]) for r in hits) or "no"
except FileNotFoundError:
    installed = "no"
except (OSError, ValueError):
    installed = "unknown"
try:
    entry = [p for p in load(os.path.join(cfg, "plugins", "marketplaces", "stbr", ".claude-plugin", "marketplace.json"))["plugins"] if p.get("name") == "safe-ai-skill"]
    pinned = (entry[0].get("source") or {}).get("sha", "?")[:7]
except (OSError, ValueError, KeyError, IndexError):
    pinned = "unknown"
print("enabled:", enabled)
print("installed:", installed)
print("pinned:", pinned)
print("platform:", platform.system())
print("full_install:", pathlib.Path(".claude/VERSION").is_file())
PY
```
Read these in order; stop at the first that matches.
- `n/a` no `.claude/` directory: an `--agents` install. Its hooks are Claude Code only; vet add-ons with `npx @stbr/safe-ai-skill add skill|mcp <source>`.
- WARN `enabled: False`: turned off in `settings.local.json`. That is a choice: report it and offer no fix.
- WARN `platform` is neither `Darwin` nor `Linux`: it has no engine build here and fails closed, blocking every tool call (solanabr/safe-ai-skill#6). Keep it off: `"safe-ai-skill@stbr": false` under `enabledPlugins` in `.claude/settings.local.json`.
- WARN `installed: unknown`: Claude Code's install list is unreadable here (High's read fence covers `~/`). Ask the user to run `claude plugin list` in their own shell.
- FAIL `installed: no` and `enabled: True`: enabled but not installed, so none of its gates run. In the user's shell, in this directory: `claude plugin install safe-ai-skill@stbr --scope project`. If that cannot find the plugin, add the kit's marketplace first: `claude plugin marketplace add https://github.com/solanabr/ai-kit.git`.
- WARN `installed: no` and `enabled: None` and `full_install: True`: an install from before safe-ai-skill was core. The same install command enables it too.
- WARN `installed` shows a sha other than `pinned`: the plugin lags the kit's pin. `claude plugin update safe-ai-skill@stbr`.
- OK otherwise: report its scope and sha.

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
| 5 | Credentials        | WARN   | HELIUS_API_KEY empty; colosseum not signed in |
| 6 | Config version     | OK     | 2.1.0 = upstream                |
| 7 | MCP config         | OK     | 3 servers parsed                |
| 8 | Dual-install guard | OK     | full install only (no plugin)   |
| 9 | Firewall tier      | OK     | relaxed declared = enforced     |
| 10| Fetch-exec guard   | OK     | registered; reports at relaxed  |
| 11| safe-ai-skill      | FAIL   | enabled, not installed          |

### Fix-its (run in order)
1. `git submodule update --init --recursive`
2. `/setup-mcp`
3. `solana airdrop 2 --url devnet`
4. In your shell: `claude plugin install safe-ai-skill@stbr --scope project`
```

## Guardrails

- Read-only: never write, edit or delete files. Print fix-its for the user to run.
- Never print `.env` values, keypair contents or anything secret-shaped.
- Network use is limited to read-only lookups (`git ls-remote`, `solana balance`). Never airdrop, deploy or send transactions for the user.
- If a check errors unexpectedly, mark it `WARN` with the one-line error and run the remaining checks.
