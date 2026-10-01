# Solana project (solana-builder)

<!-- MAINTAINER: ships as CLAUDE.md to user projects via install.sh. It loads in every session
     and in every subagent, so it holds only facts and house rules a strong model would not
     infer on its own. Put detail in skills, agents or commands, which load on demand.
     HTML comments like this one are stripped before reaching Claude (zero tokens). -->

Be direct: no filler, code before explanation, say so when unsure.

## Before writing Solana code

Open the matching entry in `.claude/skills/SKILL.md`. It routes to current references for Anchor 1.x, Pinocchio, `@solana/kit`, testing (LiteSVM, Mollusk, Surfpool), security, Token-2022 and protocol SDKs, which are newer than most training data.

Only the core skill packs ship installed. A link into a missing `.claude/skills/ext/<id>/` folder is an extension the kit pins: run the `bash .claude/bin/skills.sh add <id>` command given next to it, then read the link.

## Program code

- Checked arithmetic; no `unwrap()` or `expect()` outside tests.
- Validate every account (owner, signer, PDA) and every CPI target program.
- Store canonical bumps and reuse them; `.reload()` an account after a CPI that mutates it.
- No `init_if_needed`.

## Workflow

- Branches: `<type>/<scope>-<description>-<DD-MM-YYYY>` (`/quick-commit` automates this).
- Deploy to devnet first. Mainnet needs the user's explicit go-ahead every time — get it yourself, never assume a tool gate will stop you. (Claude Code adds one: deploys, upgrades and authority changes stop for the user's approval on every cluster, and irreversible ones such as `--final` or a program close are left for the user to run. Other runtimes have no such gate.)
- Before finishing a branch: build, `cargo fmt`, clippy and tests pass, `/diff-review` is clean, and docs that describe the change are updated. For program changes also run `/audit-solana` and `/profile-cu`, and `anchor build --verifiable` before any deploy.

## MCP

Helius, solana-dev and Context7 are configured in `.mcp.json`; Playwright, Surfpool and context-mode are opt-in. Keys belong in `.env`, never in `.mcp.json`; `/setup-mcp` sets them up and adds the optional servers.

## Project Learnings

<!-- Written by the user, /diff-review and /dream. One line per entry. Add only conventions the
     user confirmed or mistakes that repeated; put scratch notes in CLAUDE.local.md (gitignored).
     Cross-project preferences belong in ~/.claude/CLAUDE.md. In a monorepo, add a CLAUDE.md per
     package; it loads when Claude works in that directory. -->
