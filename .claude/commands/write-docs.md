---
description: "Write docs for a Solana program, SDK or component from its code and IDL"
---

Document the code in `$ARGUMENTS`. Take facts from the source and the IDL (`target/idl/<name>.json`) rather than from memory. For a full documentation set (guides, architecture, runbooks), hand off to the `tech-docs-writer` agent.

## What each doc type needs

| Type | Include |
|------|---------|
| Program | Program IDs per cluster. Per instruction: accounts (signer, writable, PDA seeds), arguments with valid ranges, errors with codes, who may call it, CU estimate. Per account: fields with sizes, total size including the discriminator, rent, and which instructions create, mutate and close it |
| SDK/API | Functions with parameters, return values, thrown errors, and a working example |
| Unity/C# component | Serialized fields, events, usage; patterns in [solana-game SKILL.md](../skills/ext/solana-game/skill/SKILL.md) (install first: `bash .claude/bin/skills.sh add solana-game`) |
| README | What it is, program IDs, install, quick start, instruction summary, test and deploy commands, audit status |

## Rules

- Examples must run against the current IDL and generated client; mark any you could not run.
- State the security assumptions: who can call what, which accounts must be trusted, what the upgrade authority can change.
- Explain why a non-obvious choice was made; skip what the code already says plainly.
