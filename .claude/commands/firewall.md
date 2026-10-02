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
   Write it through Bash, not the Edit tool: `Edit(/.claude/security.json)` is denied at every tier so an agent cannot rewrite its own policy.
3. Report the script's change list (rules added, rules removed) and tell the user to restart Claude Code.

## Guardrails

- Only `firewall.sh apply` owns the generated block. Never hand-merge rules into `.claude/settings.json`: the block is replaced on the next apply, and permission lists merge without an un-deny primitive, so a hand-added deny cannot be lifted later.
- `off` disables the sandbox and generates no rules. Switch to it only on the user's explicit ask, and say what it turns off.
- `medium` and `high` hard-fail headless by design. CI runs `relaxed` or `off`.
- The kit cannot enforce egress at any tier: a local MCP server runs outside the sandbox, and the network allowlist has no effect from project settings. State that rather than implying `high` closes egress.
