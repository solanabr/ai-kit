---
description: "Un-ignore and commit the kit config dir, instruction file, .mcp.json, .gitmodules, policy"
model: sonnet
disable-model-invocation: true
---

`install.sh` gitignores the kit config by default, in a marked `.gitignore` block covering the config dir (`.claude/`, or `.agents/` in `--agents` installs), the instruction file (`CLAUDE.md`, or `AGENTS.md`), `.mcp.json`, `.gitmodules` and, in Claude Code installs, `.safe-ai-skill/` (the safe-ai-skill project policy). This command opts the project in, so the config travels with the repo: a teammate who clones it gets the policy without running `install.sh`. The `ext/` skill submodules stay ignored: they are upstream content, and tracking `.gitmodules` is enough for a `--recurse-submodules` clone to repopulate them.

## Steps

1. **Preflight.** Stop unless inside a git work tree, and tell the user to run `git init` first. Resolve both names for the install mode; with neither config dir there is nothing to commit.
   ```bash
   CONFIG_DIR=$( [ -d .claude ] && echo .claude || echo .agents )
   INSTR_FILE=$( [ "$CONFIG_DIR" = .claude ] && echo CLAUDE.md || echo AGENTS.md )
   ```
2. **Un-ignore.** Remove the marked block and leave the `ext/` and local-only sections alone. Writing through a temp file keeps it portable across GNU and BSD sed. If the block is already gone, continue.
   ```bash
   if [ -f .gitignore ] && grep -qF ">>> solana-ai-kit config" .gitignore; then
     sed '/# >>> solana-ai-kit config/,/# <<< solana-ai-kit config <<</d' .gitignore > .gitignore.tmp \
       && mv .gitignore.tmp .gitignore
   fi
   ```
3. **Stage.** Since `ext/` is still ignored, this records agents, commands, skills and settings but not the submodule trees.
   ```bash
   git add .gitignore 2>/dev/null || true
   for p in .gitmodules "$INSTR_FILE" .mcp.json .safe-ai-skill "$CONFIG_DIR"; do [ -e "$p" ] && git add "$p"; done
   git diff --cached --name-status
   ```
4. **Confirm.** If nothing is staged (`git diff --cached --quiet`), report that the config is already tracked and stop. Otherwise show the staged list and wait for the user's go-ahead.
5. **Commit:** `git commit -m "chore: track Solana AI Kit config"`. Any `.git/hooks/pre-commit` runs as usual.

## Notes

- To go back to ignoring the config, re-run `install.sh` (it re-adds the block only if absent), or run `git rm --cached -r .claude CLAUDE.md .mcp.json .gitmodules .safe-ai-skill` (`.agents AGENTS.md`, without `.safe-ai-skill`, in `--agents` installs) and restore the `.gitignore` lines.
- Committing the config redistributes what it holds. `anthropic-skills` is a core pack, so `$CONFIG_DIR/skills/anthropic-skills.lock` is normally present: the skill folders it lists are Anthropic's, under Apache-2.0 rather than the kit's MIT, so name them in the confirmation and keep each folder's `LICENSE.txt` with it.
- To version the `ext/` submodules as well (rarely needed; they are large upstream trees), remove the `$CONFIG_DIR/skills/ext/` line from `.gitignore` and run `git submodule update --init` so real gitlinks exist before `git add`.
