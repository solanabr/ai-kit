---
description: "Update solana-ai-kit to latest version from upstream"
disable-model-invocation: true
---

Pull the agents, commands, skills and `bin/` tooling of the latest kit release (the newest `vX.Y.Z` tag, the one `install.sh` installs) with the bundled update script.

1. Resolve the config dir and run: `BIN=$( [ -d .claude/bin ] && echo .claude/bin || echo .agents/bin ); SOLANA_AI_KIT_BRANCH="$(bash "$BIN/kit-ref.sh" 2>/dev/null)" bash "$BIN/update.sh"` (append `--dry-run` to preview without writing). `kit-ref.sh` prints the release tag, or `main` when there is none yet; a ref the user set in `SOLANA_AI_KIT_BRANCH` passes through unchanged.
2. Review the script's change list.
3. Firewall: the update re-applies the tier declared in `.claude/security.json`, replacing the generated `permissions` + `sandbox` block wholesale, so any hand-edit to that block is gone and the change list names the rules added and removed. Restart Claude Code before relying on the new rules — permission rules are read at session start.
4. If `CLAUDE.md.upstream` (or `AGENTS.md.upstream` in `--agents` installs) was created, diff it against the instruction file and merge the relevant changes.
5. If the kit config is versioned (`/commit-claude-config`), review `git diff` before committing.
