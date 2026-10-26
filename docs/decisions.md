# The decision record

What the record holds, where it lives and who writes it, the `decisions.sh` helper, how the decisions in force reach your session and every subagent, the check on what the kit's agents report back, the guard that keeps the record your main session's, and what each firewall tier and install route gets.

## Why it exists

A decision you make in conversation reaches an agent only if someone copies it into that agent's brief, and a brief is frozen when it is written: a decision left out of it, or made after it, never arrives. A subagent loads the project's instructions, not your conversation. So agents re-ask what you settled, or quietly decide it the other way.

The record keeps the decisions you made, the principles you set and the standing orders you gave, one small file per entry, and three hooks hand the entries in force to your session and to every subagent, and again whenever the list changes. Nothing depends on an agent remembering to look.

## Where it lives, and who can see it

**Under the clone's git directory:** `$(git rev-parse --git-common-dir)/decisions/`, which is `.git/decisions/` in a plain checkout. Every linked worktree of a clone shares that directory, so an entry recorded in one worktree is live in all of them at once: parallel agents in worktrees of their own, or several panes on one repository. A tracked file would be stale in every branch cut before the change. It is the record of the repository the command runs in, found the way git finds it; a second clone of the same repository keeps its own.

**Private by construction.** Nothing under `.git/` is cloned, committed or pushed, so the record never appears in a public repository, and no clone, fork or pull request can carry an entry into it. The helper creates the directory `0700` and its files `0600`.

**The cost is that teammates don't see it.** `decisions.sh export --handoff` prints a readable digest to hand to a co-maintainer or a later session, and a decision your team has to review belongs in the pull request or a design document as well.

**Never secrets.** A field that looks like a credential (a PEM block, a keypair's bytes as a JSON array or as any list of 64 numbers from 0 to 255, a base58 secret key of 80 to 90 characters, an API token in a common format, a URL carrying a password) is refused, nothing is written, and no message prints the value. The check reads shapes, not secrets. A Solana transaction signature has a secret key's shape and is refused too, so shorten one you cite. A seed phrase passes, because refusing a run of ordinary words would refuse ordinary prose. A key written out in hex nearly always passes as well, since it looks like a digest. Keep keys out of what you record: whatever the list holds is shown to every agent.

## Who writes it

**Your main session, through `.claude/bin/decisions.sh`.** Subagents propose instead: they list what they decided and what they need from you in their reports ([below](#the-report-check)), and the main session records what you confirm. Entries go through the helper rather than the file tools because Claude Code treats a `Write` or `Edit` into `.git/` as a sensitive-file write and asks before any allow rule applies. "Main session only" is enforced: [the write guard](#the-write-guard) refuses a subagent's write to the record.

What the helper enforces:

- **Authority comes only from you.** An entry you decided (`decided-by: you`, the default) is superseded only by another of yours, given `--by you` and in force. A panel's call, an agent's or a provisional one cannot replace it.
- **Your words are quoted, never paraphrased,** in `--words`, with the day in `--date` rather than inside the quote.
- **A decision needs its question** (`--question`). **A standing order needs `--covers` and `--expires`:** what it covers and nothing else, and when it lapses.
- **`enforced-by` defaults to `none yet`,** marking a decision that no test or hook proves yet.
- **Every field is checked before anything is written:** at most 4,000 bytes, no control characters, nothing credential-shaped.

Change your mind with `supersede`, not by editing: the old entry stays, marked superseded with a pointer to its replacement, so the history survives. You can still edit or delete an entry file by hand; `decisions.sh in-force` then regenerates the list the hooks read.

## Entries

One markdown file per entry, named `<D|P|S>-<date>-<slug>.md` for a decision, a principle or a standing order. Each holds YAML front matter with every key present, in this order:

```yaml
---
id: D-2026-10-20-test-cluster
kind: decision
status: in-force
decided-by: you
date: 2026-10-20
question: "Which cluster do the integration tests run against?"
decision: "A Surfpool mainnet fork, never devnet"
your-words: "run them on the fork, devnet is too flaky"
premises: "surfpool is pinned in CI [verified]"
enforced-by: "tests/integration.sh"
supersedes: —
covers: —
requires: —
expires: —
---
```

| Field | Values |
|-------|--------|
| `kind` | `decision`, `principle`, `standing-order` |
| `status` | `in-force`; `provisional`, a call taken without you that waits for your confirmation; `proposed`; `superseded`. Only `in-force` reaches agents |
| `decided-by` | `you`, `panel`, `agent` |
| `premises` | What the decision rests on, each marked `[verified]` or `[assumed]` |
| `covers`, `requires`, `expires` | A standing order's bounds: what it covers, what it needs first (such as CI green on the head SHA), and when it lapses |

**In force** means `status: in-force` and not superseded by another entry in force. `in-force.md` holds one line per such entry, oldest first, with `[panel]` or `[agent]` after the id when you did not decide it yourself:

```text
- P-2026-10-20-devnet-first-mainnet-only-explicit-go [panel]: Devnet first; mainnet only on an explicit go-ahead — "never touch mainnet without asking me" (2026-10-20)
- S-2026-10-20-merge-two-dependency-prs-once-ci: Merge the two dependency PRs once CI is green — "merge both bumps when green" (2026-10-20) [covers: PRs #12 and #13, nothing else; requires: CI green on the head SHA; expires: when both are merged]
- D-2026-10-21-test-cluster: Surfpool's mainnet fork locally; devnet in the nightly job — "keep the fork for local runs, but the nightly can hit devnet" (2026-10-21)
```

The helper keeps that list near 1.5K tokens. It cuts the decision, the words and a standing order's bounds at 200, 240 and 80 bytes, tighter once the list passes 6,000 bytes, always at a character boundary and marked `…`, and adds a closing line saying `decisions.sh export` has the full entries. `add`, `supersede` and `in-force` warn on stderr once the list passes 6,000 bytes, and more sharply past 9,000, near the cap a hook's context collapses at. `in-force.sha` holds the list's git blob id, which is the version the hooks compare. A list without a usable one, after a hand edit or a deletion, is still handed to each agent once, under a single fixed version, since working one out would read the whole list on every tool call; a change to it reaches agents already at work once the helper writes the version again, as `decisions.sh in-force` does.

## The helper: decisions.sh

Run it from the project root (`.agents/bin/decisions.sh` in an `--agents` install).

| Command | What it does |
|---------|--------------|
| `add --kind K --decision D --words W [--question Q] [options]` | Records an entry and prints its id |
| `supersede <id> --decision D --words W [options]` | Marks `<id>` superseded, records its replacement and prints the new id. `--kind`, `--question` and the slug default to the old entry's |
| `in-force` | Regenerates `in-force.md` and prints it |
| `hash` | Prints the list's version from `in-force.sha`, regenerating first when an entry changed since |
| `export [--handoff]` | Prints every entry, oldest first; `--handoff` prints a digest grouped *In force*, *Provisional*, *Proposed* and *Superseded*, with back-links |
| `path` | Prints the record directory |

The other options for `add` and `supersede` are `--premises`, `--enforced-by`, `--covers`, `--requires`, `--expires`, `--by you|panel|agent` (default `you`), `--status in-force|provisional|proposed` (default `in-force`), `--slug` for the name part of the id, `--date YYYY-MM-DD` (default today) and `--stdin`; `decisions.sh help` lists them all. Exit status is 0 when done, 1 when refused or failed, 2 on bad usage. Outside a git repository, or before the first entry, the readers print nothing, exit 0 and create nothing.

**`--stdin` reads the fields as `name: value` lines,** an indented line continuing the value above it. Use it through a quoted heredoc for words that span lines or carry quotes, and for any text that names a credential path, which a guard hook can read on the command line as a file the call opens, and block. Values are taken as written, so leave them unquoted:

```bash
bash .claude/bin/decisions.sh supersede D-2026-10-20-test-cluster --stdin <<'DECISION_END'
decision: Surfpool's mainnet fork locally; devnet in the nightly job
words: keep the fork for local runs, but the nightly can hit devnet
DECISION_END
```

A field given on both the command line and stdin is refused.

## How it reaches agents

Three pushes from two hooks, each reading `in-force.md` straight from the record:

| Event | Hook | Fires | What the agent gets |
|-------|------|-------|---------------------|
| `SessionStart` | `decisions-inject.sh` | At start, resume, `/clear`, compaction and a fork | Your main session gets the list |
| `SubagentStart` | `decisions-inject.sh` | At every spawn, resume and teammate message | The subagent gets the list: a workflow's agents too, and Explore and Plan, which load no `CLAUDE.md` |
| `PreToolUse`, every tool | `decisions-push.sh` | Before each tool call | The list again, once, when it changed since that agent last saw it |

Every copy opens with the same line:

> The user's decisions in force, from this clone's decision record: never contradict one; report a conflict instead

It does not outrank you: your newest explicit instruction beats any entry, and `CLAUDE-solana.md` tells the session to follow it and supersede the entry it overrides.

**The tool-call push is what makes the list live.** A subagent gets the list when it is spawned, but a decision made while it works, in this session or in another worktree, reaches it only at its next tool call. The push is keyed on the agent's `agent_id`, or the session's id for your main session, and on the list's version, with an empty marker directory for each pair under `<record>/seen/`. The marker is claimed before anything is printed, so parallel tool calls push once between them. Injection marks the agent too, so its first tool call does not repeat the list, and markers untouched for a week are removed.

What keeps them cheap and safe:

- **No record, no output.** In a repository without an `in-force.md`, neither hook prints anything.
- **Nothing they do can stop a tool call.** The two record hooks and the report check are each registered behind a wrapper that exits 0 whatever the script does; the most any of them does is the report check's one extra turn, below. Only [the write guard](#the-write-guard) refuses a call, and only a subagent's write to the record.
- **No model call, and no git command in a normal checkout or worktree.** The record is found by reading `.git` directly. When nothing changed, the push reads its input, checks one marker and exits.
- **Under the context cap.** Claude Code turns `additionalContext` past 10,000 characters into a file path and a short preview. The hooks cut the list at a line under 9,000 bytes instead and name the file that holds the rest.
- **A linked record is refused.** A symlink in place of `decisions/` or `in-force.md` is ignored, so a tracked file can never speak as you.

## The report check

`decisions-report-check.sh` runs when a subagent stops. When the agent is one of the kit's own, bare or as `solana-ai-kit:<name>`, and its report leaves out any of five labelled lines, the hook sends it back once, naming what is missing:

```text
Verified: anchor test, 14 passing
Decisions made: kept the existing PDA seeds
Decisions needed: none
Assumptions: the devnet program id is unchanged since the last deploy
Next owner: solana-qa-engineer, for the fuzz pass
```

`none` is a fine answer. Decoration doesn't matter (bold, headings, bullets, numbering), and common variants count, such as "What I verified", "Open questions", "Premises" or "Next steps". So do up to eight words between a label and its colon, as in "Assumptions made:", "Decisions needed from you:" or "Verified by running anchor test:", and a heading or a line wholly in bold needs no colon. A sentence that merely opens with one of the words, such as "Verified the build works.", is not a label. The project's `CLAUDE.md` asks every subagent for these five lines, so a kit agent that follows it passes first time; one that doesn't costs one extra turn.

It holds no other agent to the contract: not general-purpose, Explore, Plan or agents you wrote, nor Claude Code's internal ones. It reads the report as delivered, including one handed back through the `SubagentHandback` tool, skips a report that is JSON (a workflow agent's structured output) or empty, and sends an agent back at most once: the stop that follows goes through whatever it holds. It checks that the labels are there, not that what follows them is true, and it reads English labels only. It runs in every project, with a record or without one.

## The write guard

Whatever the record holds reaches every agent as your decision, so only your main session writes it. `decisions-guard.sh` runs before Bash, `Write`, `Edit`, `MultiEdit`, `NotebookEdit` and context-mode's tools, and refuses the call (exit 2) when it comes from a subagent and either:

- **runs `decisions.sh add` or `supersede`**, from whatever path and however wrapped: behind `env` or `timeout`, inside `sh -c` or `eval`, or in a heredoc that a shell or an interpreter runs; or
- **points a file tool inside the record directory**, at an entry, `in-force.md` or the hooks' `seen/` markers, after resolving `..`, links and letter case, so another spelling of the path is the same path, and a link into the record is the record whatever the link is named.

Claude Code adds an `agent_id` to the payload of a hook that fires inside a subagent, a workflow's agents included, or an in-process teammate, and never to your main session's, so your session passes before anything else is read. Every agent can still read the record and run the helper's readers (`in-force`, `hash`, `export`, `path`), and a command that only names the helper, such as a grep, an echo or a commit message, is not a call. The refusal tells the agent to list the decision in its report under Decisions made or Decisions needed, which your main session records once you confirm it.

It runs at every firewall tier, Off included: who may speak for you does not vary with the firewall. A call that never names the helper passes on the payload alone, and a file path that does not resolve into a directory named like the record's passes on the shell's own builtins, with no `jq` or `awk` spent.

## Firewall tiers

| Tier | The helper writes the record | The hooks read it |
|------|------------------------------|-------------------|
| Off, Relaxed, Medium | Yes. Rule set 10 puts `Bash(bash .claude/bin/decisions.sh *)` in the allow list, so it runs without a prompt; under an earlier rule set it may prompt | Yes |
| High | **Not yet.** High's sandbox fences reads under your home directory, and the helper is not yet supported inside that fence; on Claude Code 2.1.304 the fence is expected to stop it reading its own script. Record decisions from a session at a lower tier until it is | Yes: hooks run outside the sandbox |

The write guard refuses a subagent's write at every tier.

## Which installs get what

| Install | The helper | The pushes, the report check and the write guard |
|---------|------------|--------------------------------------------------|
| Full install | `.claude/bin/decisions.sh` | All four hooks, registered in `.claude/settings.json` |
| Existing install, after `/update` | Copied in | Registered by `/update`'s hook migration (`HOOK_SET_VERSION` 4), which appends a kit hook a project lacks and never rewrites an entry you edited |
| Plugin | None: a plugin carries no `bin/` | All four, from the plugin's `hooks/hooks.json`. Next to a full install, the plugin's copies of the three context hooks step aside; both copies of the guard run, to the same verdict |
| `--agents` (Codex, opencode and other tools) | `.agents/bin/decisions.sh` | None: an `--agents` install writes no settings file, so the scripts sit in `.agents/hooks/` unregistered, and nothing hands agents the list, checks their reports or refuses their writes |

`/doctor` reports whether the hooks are wired (check 12) and whether the record is in a state they can read (check 13).

## Limits

- **The write guard covers the expected routes, not every route.** It reads the helper's two write commands and the file tools' target paths. It is not a sandbox, and a write that reaches the directory by other means is outside what it reads.
- **It knows a subagent by its `agent_id`.** An agent whose hook payload carries none passes as a main session: a separate session, such as another pane or a headless `claude -p` run, is one, and so is an agent under a harness whose hook payloads name no agent. The guard reads Claude Code's `agent_id` and Grok's `agentId`, and an `--agents` install registers no hooks at all. A workflow's agents carry one. In Claude Code 2.1.304's source, a tool call's hook payload takes `agent_id` from the id of the agent making the call, and each workflow agent is started under an id of its own. A workflow agent's transcript carries that id and records its `PreToolUse` and `SubagentStart` hooks running. No payload has been captured live.
- **Recording is a choice the session makes.** An answer you give in chat reaches the record only when the session records it.
- **A subagent's compaction drops the list it was handed.** Auto-compaction discards the copy injected at spawn, and Claude Code injects the hook's list again only at that agent's next resume or teammate message. The push stays quiet meanwhile, since the agent has already seen this version, so until the list changes it works from whatever its summary kept. Your main session is unaffected: its compaction fires `SessionStart`, which hands it the list again.
- **In a session started as `claude --agent <kit agent>`,** Claude Code's internal agents carry that agent's name, so the report check can send one back once.
