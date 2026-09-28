---
name: solana-ai-kit
description: Solana development reference hub — Anchor 1.x, Pinocchio, @solana/kit, LiteSVM/Mollusk/Surfpool testing, program security, Token-2022, and protocol SDKs (Jupiter, Helius, Metaplex, Raydium, Kamino, Pyth). Use before writing or reviewing any Solana program, client, or test.
---

# Solana AI Kit

The kit's routing hub is `.claude/skills/SKILL.md` at the project root. Read that
file now, find the row matching the task, and read the file it links to.

Link targets there are relative to `.claude/skills/`, so prefix them with that
path: a link to `ext/solana-dev/.../anchor.md` is
`.claude/skills/ext/solana-dev/.../anchor.md` from the project root.

The hub and the files under it are written for Claude Code. Ignore the parts that
do not apply here: `/slash-command` names are Claude Code commands (the prose
around them still describes a real workflow you can run by hand), and
`.claude/agents/*.md` are Claude Code subagent definitions, readable as role
briefs but not launchable. Everything else — the references, house rules and
protocol SDK docs — applies as written.

Mainnet deploys: the project ships a `PreToolUse` hook in `.codex/hooks.json`
that blocks them unless the command is prefixed with `CONFIRM_MAINNET=1`. It only
runs once the user has trusted it (`/hooks`), so treat it as a backstop, not a
guarantee — ask for explicit confirmation before any mainnet command either way.
