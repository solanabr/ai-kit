---
description: "Merge PRs inside a standing order: review bound to the head SHA, hotspots re-checked, issues closed"
disable-model-invocation: true
---

Merge the pull requests in `$ARGUMENTS` (PR numbers; with none, the PRs a standing order in force covers), one at a time and only inside a standing order. No standing order covers mainnet, program upgrades, authority changes, keys, funds, deletions or another repository: those stay with the existing gates and with the user, whatever an order says.

Run each `gh` and network `git` call bare, as the whole Bash command: a pipe, redirect, `$(...)` or `cd` prefix keeps it in the sandbox, where it may fail to authenticate.

## The order

1. **Read it:** `bash .claude/bin/decisions.sh in-force` lists each standing order with the user's words, what it covers, what it requires and when it expires (`export` prints an entry the list cut short). If the helper is missing or fails, say so: the order is then what the user wrote in this conversation, quoted in the output.
2. **PRs named here** are the user's order for them. Record it, single-quoting every value (`'\''` for an apostrophe):
   `bash .claude/bin/decisions.sh add --kind standing-order --by you --decision 'Merge <the PRs> once reviewed and green' --words '<their words, verbatim>' --covers '<exactly these PRs, in this repository>' --requires '<the review they named, on the head commit; green checks there>' --expires 'once all are merged'`
   Where an order in force already covers these PRs, record it with `supersede <id>` and the same options instead; a review that order required still applies unless the user dropped it.
3. **No review named** anywhere: require a `/review-round` sheet for the head commit with nothing open at Critical or High and no item waiting on the user. This default only ever adds a check.
4. **Re-read the order before each merge.** Once it has expired or been superseded, stop.
5. **Settle the merge method** before the first PR, so the train never stops for it: the method the order names, else a merge-method principle in force, else the one `gh repo view --json viewerDefaultMergeMethod` returns. Two merge-method principles in force that disagree are a conflict: report it and ask the user rather than pick one, then record their answer with `supersede <id>` for each. `gh repo view` is not among the commands that leave the sandbox, so where it cannot authenticate, ask the user now rather than guess, and record the answer so no later run asks again:
   `bash .claude/bin/decisions.sh add --kind principle --by you --decision 'Merge pull requests in this repository with --<method>' --words '<their words, verbatim>'`

## Per PR, in the order's sequence

1. `gh pr view <n> --json state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus,files,closingIssuesReferences,reviews`: open, not a draft, mergeable, in this repository.
2. `gh pr checks <n>`: every check passed. Exit code 8 means pending: wait (`gh pr checks <n> --watch`), never merge on pending. A failed or cancelled check, a skipped required one, or no checks at all is not green.
3. **The review covers `headRefOid`:** a `/review-round` sheet whose header names that SHA (after a fix wave, the review of its delta, with the earlier sheet's items fixed, deferred or answered), or a GitHub review by the named reviewer whose `commit.oid` in `reviews` equals it. A review of an earlier commit does not count.
4. **Stop and ask when merging would do more than merge:** a workflow in `.github/workflows/` that runs on a push to that base and deploys, upgrades, changes an authority or publishes (only a publish can be covered, and only by an order that names it), or a PR that adds a keypair, secret or credential.
5. **Merge:** `gh pr merge <n> --<method> --match-head-commit <headRefOid>`, with the method settled under [The order](#the-order). `--match-head-commit` makes GitHub refuse the merge if the head moved after these checks. Never `--admin` (it overrides the checks), `--auto` (it merges later, after the order was last read) or `--delete-branch` (a deletion). Never push to, rebase or update a PR branch to make it mergeable: a new head voids its review.
6. **Hotspots:** before the merge, `git fetch origin <base> pull/<n>/head`, then `git merge-base <headRefOid> origin/<base>` and `git diff --name-only <merge-base> origin/<base>`: the PR's files in that list changed on the base after it branched, and files another PR in this train touched count too. After the merge, `git fetch origin <base>`, read each such file at `origin/<base>` and confirm both changes survived, then run that file's own checks in a detached worktree of `origin/<base>`. A clean textual merge can still drop a change.
7. **Issues:** GitHub closes the issues a PR links when it lands on the default branch. Close the ones still open with `gh issue close <i> --comment "Fixed by #<n> (<merge commit>)"`: only those `closingIssuesReferences` names, only in this repository.
8. **A failed step stops the train** there: report it and leave the rest unmerged.

When every PR an order covers is merged, the order is spent: say so under Done, with its id. Retiring it from the record is the user's call, since only they supersede an entry they made.

## Tiers

`egress-guard.sh` lets `gh pr merge` through silently at Relaxed, asks at Medium and denies it at High, and a bypassed permission mode skips the ask. Below High these rules are the only gate, so they hold at every tier. At High, give the user the exact merge commands to run.

## Output

Per PR: its head SHA, the review that covered it, the checks, the merge commit, the hotspot re-checks (command and result) and the issues closed; then where the train stopped, and why. The user's calls go in Open as numbered briefs ([format](decide.md#brief)).
