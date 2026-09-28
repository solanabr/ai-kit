---
description: "Update solana-ai-kit to latest version from upstream"
model: sonnet
disable-model-invocation: true
---

Pull the latest agents, commands, skills and `bin/` tooling from upstream with the bundled update script.

1. Run `bash .claude/bin/update.sh` (append `--dry-run` to preview without writing).
2. Review the script's change list.
3. If `CLAUDE.md.upstream` was created, diff it against `CLAUDE.md` and merge the relevant changes. Same for `AGENTS.md.upstream` when the project has the `--agents` bridge.
4. If the kit config is versioned (`/commit-claude-config`), review `git diff` before committing.
