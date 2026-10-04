---
description: "Show or switch the agentic firewall tier (off, relaxed, medium, high)"
disable-model-invocation: true
---

Show or change the agentic firewall tier. `off`, `relaxed` (default), `medium`, `high`.

**A switch takes effect in the next session.** Permission rules are read once, at session start, so editing `.claude/security.json` mid-session does not loosen — or tighten — the session you are in: the rules it started with stay in force until Claude Code restarts. Say this when you report a switch; do not imply the new tier is live.

## Show — bare `/firewall`

```bash
python3 - <<'PY'
import json, pathlib
def load(p):
    f = pathlib.Path(p)
    return json.loads(f.read_text()) if f.is_file() else {}
sec, cfg = load(".claude/security.json"), load(".claude/settings.json")
perms = cfg.get("permissions") or {}
live = {r for k in ("deny", "ask", "allow") for r in (perms.get(k) or [])}
enf = sec.get("enforced") or {}
rec = set(enf.get("ruleIds") or [])
print("declared:", sec.get("tier") or "none")
print("enforced:", enf.get("tier") or "none")
print("live:", len(live), "recorded:", len(rec), "delta:", len(live) - len(rec))
print("recorded_but_absent:", len(rec - live))
PY
```

Report the declared tier, the enforced tier, whether they agree, and the rule-count delta. `recorded_but_absent > 0` means `settings.json` lost rules the last apply wrote — re-apply. For local overrides, the sandbox state and the plugin case, run `/doctor` (check 9).

## Switch — `/firewall <tier>`

1. `bash .claude/bin/firewall.sh apply <tier>` — it records the tier in `.claude/security.json` and replaces the generated `permissions` + `sandbox` block in `.claude/settings.json` wholesale.
2. If the script takes no tier argument, set it first, then apply with no argument:
   ```bash
   python3 -c "import json;p='.claude/security.json';d=json.load(open(p));d.setdefault('declared',{})['tier']='<tier>';json.dump(d,open(p,'w'),indent=2)"
   bash .claude/bin/firewall.sh apply
   ```
   Write it through Bash, not the Edit tool: at `high`, `Edit(/.claude/security.json)` is denied so an agent cannot rewrite its own policy. The Bash form works at every tier.
3. Report the script's change list (rules added, rules removed) and tell the user to restart Claude Code.

## Guardrails

- Only `firewall.sh apply` owns the generated block. Never hand-merge rules into `.claude/settings.json`: the block is replaced on the next apply, and permission lists merge without an un-deny primitive, so a hand-added deny cannot be lifted later.
- `high` is the only tier that denies the agent edits to `.claude/settings.json`, `.claude/security.json`, `.mcp.json` and the user-scope config under `~/.claude/`; `off`, `relaxed` and `medium` allow them, because customizing your own installation is the user's call. Say this when switching **down** from `high`, and name what it opens — and what it does not: `.claude/hooks/**` and `~/.claude/hooks/**` are denied at **every** tier, Off included, because those are the executable scripts implementing the mainnet, secrets and on-chain gates, and `/firewall` changes every tier knob without touching them. Below `high` the user owns their `.claude/` configuration, not the guards. A nested `claude --dangerously-skip-permissions`, managed settings and `.safe-ai-skill/**` are also denied at every tier.
- `off` disables the sandbox and generates no rules. Switch to it only on the user's explicit ask, and say what it turns off.
- `medium` and `high` hard-fail headless by design. CI runs `relaxed` or `off`.
- The kit cannot enforce egress at any tier: the network allowlist has no effect from project settings, and a local MCP server runs outside the sandbox entirely. State that rather than implying `high` closes egress.
- `medium` and `high` also deny `context-mode`'s `ctx_execute`, `ctx_execute_file`, `ctx_batch_execute`, `ctx_fetch_and_index` and `ctx_index` by name, because it is a default server with a code executor and no sandbox under it. Mention this when switching up to either: the context-compression tools (`ctx_search`, `ctx_stats`, `ctx_doctor`) keep working, running code through it does not. At `off` and `relaxed` every tool stays callable and the three hooks gate its payloads instead.
- `high` alone also denies `mcp__cloudflare__execute`, if the user has attached the opt-in Cloudflare server. Say so when switching to `high`: `docs` and `search` keep working, so documentation lookup is unaffected, but deploying a Worker or editing DNS through the agent is not. `medium` leaves it callable on purpose — Cloudflare is opt-in behind a token the user scoped, so attaching it is their decision, whereas `context-mode` is a default they never chose. Below `high` nothing gates it, hooks included, so the token's scopes are the boundary.
