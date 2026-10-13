---
description: "Write a PR title and body a reviewer can verify, from the diff, the log and real test output"
---

Write the pull request for the current branch. `$ARGUMENTS` may name an issue and the base branch (default `main`, else `master`). Every fact comes from `git diff <base>...HEAD`, `git log <base>..HEAD` or a command run in this session; a number nobody ran is left out, never estimated. Repro harnesses: [testing.md](../skills/ext/solana-dev/skills/solana-dev/references/testing.md) (LiteSVM, Mollusk, Surfpool), [surfpool/cheatcodes.md](../skills/ext/solana-dev/skills/solana-dev/references/surfpool/cheatcodes.md).

## Steps

1. **Review first.** This command writes; it does not review. If `/diff-review` has not run on this diff, run it first and fix its Critical findings.
2. **Facts:** `git diff --stat <base>...HEAD`, the full diff, `git log --format='%h %s' <base>..HEAD`; with an issue, `gh issue view <n>`.
3. **Title:** `type(scope): summary` as `/quick-commit` writes it, under 72 characters, from the diff rather than the branch name.
4. **Body**, in this order. Drop a section that does not apply; never leave a placeholder.
   - **Summary:** old behaviour and new behaviour, one line each.
   - **Problem:** what broke or was missing, plus one line on how it was found (failing test, user report, audit, `/debug-user-tx`).
   - **Repro without funds:** the smallest repro on a Surfpool fork, LiteSVM, Mollusk, devnet or a local mock, with its output on the base branch and on this branch. Never one that needs mainnet SOL.
   - **Test plan:** the exact commands and the counts they printed. Show a new test failing on the base, or with the fix reverted (`git stash`, or `git checkout <base> -- <file>` and restore). Name what was not run and why (needs mainnet, a key, a submodule).
   - **Risk:** what does not change, then what to check before merging: upgrade authority, mainnet deploy, account layout or migration, IDL and client regeneration, CU (`/profile-cu`).
   - `Closes #<n>` only when an issue exists.
5. **Review findings** on an open PR: answer each with the commit that fixes it and how the fix was proven (command and result), or why it was not changed. "Done" alone is not an answer.

## Rules

- About 1,500 characters of body. Facts over adjectives. No secrets, keypair paths or RPC URLs carrying a key.
- No AI attribution or `Co-Authored-By` trailer, as in `/quick-commit`.
- Run `gh pr create --title "<title>" --body-file <file>` only when the user asks in this session, after they have pushed. Never push and never merge: `egress-guard.sh` makes `gh pr merge` an approval prompt at Medium and a deny at High.

## Output

The title, the body in a fenced block, then one line per number in the body naming the command that printed it.
