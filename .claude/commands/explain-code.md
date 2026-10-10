---
description: "Explain Solana code with a diagram and a step-by-step walkthrough"
---

Explain the code in `$ARGUMENTS` (a path, symbol, or pasted snippet). Match depth to the code and the asker: a helper gets a paragraph; an instruction handler or a whole program gets the structure below.

For concept background, open the matching entry in the kit skill hub: `.claude/skills/SKILL.md`, or the `solana-ai-kit` skill in a plugin install. For tutorials or learning paths, hand off to the `solana-guide` agent.

## Output

1. **Overview**: what it does and why it exists, in two or three sentences.
2. **Diagram**: Mermaid. A sequence diagram or flowchart for instruction and CPI flow, a graph for account and PDA relationships.
3. **Walkthrough**: the significant sections in order, with the reasons behind non-obvious choices (seed layout, account order, bump handling, `remaining_accounts`).
4. **Solana concepts used**: PDAs, CPIs and signer seeds, rent, account ownership, Token vs Token-2022; a sentence or two each on how this code uses them.
5. **Security notes**: the checks the code performs and any it appears to miss (signer, owner, PDA, CPI target, arithmetic). For a real review, suggest `/audit-solana`.
6. **Check questions** (for learners only): two or three "what happens if..." questions.
