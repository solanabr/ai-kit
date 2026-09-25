---
description: "Turn a solana-ai-kit fork into a project: set up CLAUDE.md, remove kit files"
model: sonnet
disable-model-invocation: true
---

Turn a fork or clone of the solana-ai-kit repo into a working project: install the project `CLAUDE.md` and delete the files that only serve maintaining or publishing the kit.

## Steps

1. **CLAUDE.md.** If it is missing, or is the maintainer version (contains "Meta Configuration"), copy `CLAUDE-solana.md` to `CLAUDE.md`, create a starter `CLAUDE.local.md` for private notes if absent, and add `CLAUDE.local.md` to `.gitignore`. Leave an existing project `CLAUDE.md` alone.
2. **.env.** If `.env` is missing and `.env.example` exists, copy `.env.example` to `.env` before anything is removed.
3. **Plan the removals**, each only if present (a missing path is not an error):
   - Maintenance: `install.sh`, `update.sh` (deprecation wrapper), `validate.sh`, `tests/`, `CLAUDE-solana.md`, `QUICK-START.md`, `README.md` (the kit's; the user writes their own), `.claude/CHANGELOG.md` (the kit's changelog), `.github/workflows/ci.yml` (keep `.github/templates/claude-code.yml`)
   - Distribution infra, only needed to publish the kit: `.claude-plugin/` (plugin marketplace manifest), `plugin/` (symlinked plugin subtree), `vercel.json` (install-endpoint redirect)
   - Keep: the rest of `.claude/` (agents, commands, skills, settings, `bin/` self-update tooling), `CLAUDE.md`, `CLAUDE.local.md`, `.mcp.json`, `.env`, `.env.example` (the tracked list of keys that `/setup-mcp` and `/doctor` read), `.gitmodules`, `.github/dependabot.yml` (keeps the `ext/` skill pins current), `.gitignore`, `LICENSE` (unless the user wants another), and anything the user created. If another file looks kit-specific, flag it instead of deleting it.
4. **Confirm.** Show the CLAUDE.md action and the exact removal list, and wait for the user's go-ahead.
5. **Execute**, print a summary of what was done, and suggest `git add -A && git commit -m "chore: initialize project from solana-ai-kit template"`.
