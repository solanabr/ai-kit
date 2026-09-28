---
description: "Un-ignore and commit the kit config dir, instruction file, .mcp.json and .gitmodules"
model: sonnet
disable-model-invocation: true
---

`install.sh` gitignores the kit config by default, in a marked `.gitignore` block covering `.claude/`, `CLAUDE.md`, `.mcp.json` and `.gitmodules` — plus `AGENTS.md`, `.agents/` and `.codex/` when the project was installed with `--agents`. This command opts the project in, so the config travels with the repo. The `ext/` skill submodules stay ignored: they are upstream content, and tracking `.gitmodules` is enough for a `--recurse-submodules` clone to repopulate them.

## Steps

1. **Preflight.** Stop unless inside a git work tree, and tell the user to run `git init` first. With no `.claude/` there is nothing to commit.
2. **Un-ignore.** Remove the marked block and leave the `ext/` and local-only sections alone. Writing through a temp file keeps it portable across GNU and BSD sed. If the block is already gone, continue.
   ```bash
   if [ -f .gitignore ] && grep -qF ">>> solana-ai-kit config" .gitignore; then
     sed '/# >>> solana-ai-kit config/,/# <<< solana-ai-kit config <<</d' .gitignore > .gitignore.tmp \
       && mv .gitignore.tmp .gitignore
   fi
   ```
3. **Stage.** Since `ext/` is still ignored, this records agents, commands, skills and settings but not the submodule trees. The last three exist only with the `--agents` bridge; a missing path is skipped.
   ```bash
   git add .gitignore 2>/dev/null || true
   for p in .gitmodules CLAUDE.md .mcp.json .claude AGENTS.md .agents .codex; do
     [ -e "$p" ] && git add "$p"
   done
   git diff --cached --name-status
   ```
4. **Confirm.** If nothing is staged (`git diff --cached --quiet`), report that the config is already tracked and stop. Otherwise show the staged list and wait for the user's go-ahead.
5. **Commit:** `git commit -m "chore: track Solana AI Kit config"`. The kit's commit hook and any `.git/hooks/pre-commit` run as usual.

## Notes

- To go back to ignoring the config, re-run `install.sh` (it re-adds the block only if absent), or run `git rm --cached -r .claude CLAUDE.md .mcp.json .gitmodules` (add `.agents .codex AGENTS.md` with the bridge) and restore the `.gitignore` lines.
- To version the `ext/` submodules as well (rarely needed; they are large upstream trees), remove the `.claude/skills/ext/` line from `.gitignore` and run `git submodule update --init` so real gitlinks exist before `git add`.
