---
description: "Resync external skill submodules to latest upstream versions"
disable-model-invocation: true
---

Update the ext/ skill submodules to upstream and check that the skill hub's paths still resolve.

1. Resolve the config dir and run: `BIN=$( [ -d .claude/bin ] && echo .claude/bin || echo .agents/bin ); bash "$BIN/resync.sh"`
2. Review the submodule diff and fix every `MISSING` path the script reports in `skills/SKILL.md`. An upstream rename can also break links in agents and commands, so grep for the old path.
3. If the project versions its submodules, run `git add .gitmodules .claude/skills/ext/` and commit to lock the updates.
