---
description: "Update solana-ai-kit to latest version from upstream"
model: sonnet
disable-model-invocation: true
---

Pull the latest agents, commands, skills and `bin/` tooling from upstream with the bundled update script.

1. Resolve the config dir and run: `BIN=$( [ -d .claude/bin ] && echo .claude/bin || echo .agents/bin ); bash "$BIN/update.sh"` (append `--dry-run` to preview without writing).
2. Review the script's change list.
3. Firewall: the update re-applies the tier declared in `.claude/security.json`, replacing the generated `permissions` + `sandbox` block wholesale, so any hand-edit to that block is gone and the change list names the rules added and removed. Restart Claude Code before relying on the new rules — permission rules are read at session start.
4. If `CLAUDE.md.upstream` (or `AGENTS.md.upstream` in `--agents` installs) was created, diff it against the instruction file and merge the relevant changes.
5. If the kit config is versioned (`/commit-claude-config`), review `git diff` before committing.
