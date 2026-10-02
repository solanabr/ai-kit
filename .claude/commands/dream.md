---
description: "Consolidate MEMORY.md and Project Learnings: dedupe, resolve conflicts, prune"
---

<!-- Schema adapted from the learn skill (gstack via sendaifun/solana-new), MIT © 2026 SendAI and Superteam. Local-only — no sync, no telemetry. -->

Consolidate project memory. This pass adds no new knowledge: it merges duplicates, resolves contradictions, drops what is stale and strengthens what is proven. Edit only `MEMORY.md` and, after the user confirms, the `## Project Learnings` section of the project instruction file — `CLAUDE.md`, or `AGENTS.md` in `--agents` installs; "the instruction file" below means whichever this project has. Never touch project code.

## Entry schema

`MEMORY.md` sections: `## Patterns`, `## Pitfalls`, `## Preferences`, `## Architecture`, `## Tools`. Work with each entry in this typed form (step 6 covers how it is written back):

```markdown
### kebab-case-key
- **Insight:** One clear sentence
- **Confidence:** N/10
- **Source:** command/agent/session that produced it (e.g. debug-user-tx, manual)
- **Files:** relative/path.rs, other/path.ts   (optional)
- **Date:** YYYY-MM-DD
```

Backfill missing fields: unknown source `legacy`, missing date today, missing confidence 5/10.

## Pipeline

1. **Collect.** Read `MEMORY.md`; if it is missing, create it with the five section headers, report "fresh memory initialized" and skip to step 6. Read the `## Project Learnings` section of the instruction file, with its `### Recurring Issues`, `### Fix Patterns` and `### Config Conventions` subsections (bullets directly under the bare header, from older installs, count as unsorted): it is always loaded and is the authoritative set for contradiction checks. Count entries per section and malformed entries.
2. **Merge.** Same key more than once: keep the latest-dated entry, fold extra detail from the older ones into its Insight, take the max confidence and delete the older ones (consolidation is the one place append-only history gets compacted). Different keys with the same meaning (compare the insights, not the strings): merge under the clearer key, noting the alias if useful.
3. **Resolve contradictions** ("use X" vs "avoid X", inside MEMORY.md or against Project Learnings). Higher confidence plus newer date wins; if the referenced files show which one is true today, check the code; if it is still ambiguous, ask the user and show both entries. Delete the loser and add "supersedes: <old-key>" to the winner.
4. **Prune.** Auto-remove dead references (every listed file is gone, checked with Glob; if some survive, trim the Files list), transient leftovers (in-progress work, old branch state, one-off incidents that can't recur) and verbatim restatements of README or the instruction file. For stale entries (confidence 4 or lower, older than 90 days, never re-confirmed) ask the user: remove, keep and re-date to today, or update the insight.
5. **Re-rank** each section by confidence, then date, both descending.
6. **Write back under the cap.** `MEMORY.md` loads at every session start, so it has a hard cap of 200 lines / 25KB and stays index-pointer style: one-line insights pointing at files, not essays. The typed fields are processing-only for steps 2-5; that metadata lives in the linked detail files, not in the index. If it is over the cap, compress insights to one line, drop obvious Files, then remove the lowest-confidence entries and tell the user what was cut. Show a before/after diff summary, not the whole file.
7. **Export to the instruction file** (optional; confirm first). Promote an entry only when its confidence is 8/10 or higher, it survived an earlier consolidation (30+ days old or re-confirmed), it applies to the whole project rather than one file's quirk, and it fits one bullet: `- **key:** insight (N/10)`. On confirmation, append it under the matching one of those three subsections, adding that `###` heading under `## Project Learnings` if it is missing (never a differently named one), and delete it from MEMORY.md; the instruction file is always loaded, so keeping both wastes tokens.

## What to write

Worth keeping: reusable patterns, pitfalls that cost more than 10 minutes, user preferences, architecture decisions with their trade-offs, and tool choices with reasons, as one-line, dated insights with file pointers.

Never written: secrets, keys, tokens, wallet addresses tied to the user or anything resembling credentials; file contents, code blocks over 3 lines or command transcripts; transient state (current branch, in-flight tasks, TODO lists, session context); anything already stated in README or the instruction file. Strip such content or drop the entry; there is no exception path.

## Output

```
## Dream Report - <date>

| Stage | Result |
|-------|--------|
| Collected | N entries (P pat / Q pit / R pref / S arch / T tool), M malformed fixed |
| Merged | N duplicates folded |
| Contradictions | N resolved (list keys), N escalated to user |
| Pruned | N removed (dead refs: n, stale: n, transient: n) |
| Exported | N promoted to the instruction file (or "none proposed") |
| Size | X lines / Y KB (cap: 200 / 25KB) |
```

No other files are modified.
