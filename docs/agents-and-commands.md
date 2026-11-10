# Agents and commands

The complete reference: 15 agents with the model each one runs on, 54 workflow commands (five of them short names for others), how the agent-workflow commands chain from intake to merge, and how to compose agents into a team. Nothing here loads up front — Claude Code lists only each agent's and command's one-line description, and reads a body when a task needs it.

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| **solana-architect** | System design, PDA schemes, token economics, multi-program architecture | Opus |
| **anchor-engineer** | Anchor development, IDL generation, account constraints | Opus |
| **pinocchio-engineer** | CU optimization (80-95% savings), zero-copy, minimal binary | Opus |
| **defi-engineer** | DeFi integrations: Jupiter, Kamino, Raydium, Orca, Meteora | Opus |
| **token-engineer** | Token-2022 extensions, token economics, launch mechanics | Opus |
| **solana-frontend-engineer** | React/Next.js, wallet UX, transaction flows, accessibility | Opus |
| **mobile-engineer** | React Native/Expo, mobile wallet adapter, deep linking | Opus |
| **rust-backend-engineer** | Axum APIs, indexers, WebSocket services | Opus |
| **devops-engineer** | CI/CD, monitoring, RPC infrastructure, Cloudflare Workers | Opus |
| **solana-qa-engineer** | Testing (Mollusk/LiteSVM/Trident), CU profiling, code quality | Opus |
| **tech-docs-writer** | READMEs, API docs, integration guides | Opus |
| **game-architect** | Solana game design, Unity architecture, on-chain game state, PlaySolana | Opus |
| **unity-engineer** | Unity/C# implementation, Solana.Unity-SDK, wallet integration, NFT display | Opus |
| **solana-guide** | Learning, tutorials, concept explanations, progressive learning paths | Opus |
| **solana-researcher** | Ecosystem research, protocol investigation, SDK analysis | Opus |

**Model routing:** every agent pins `model: opus`, because Opus 5.5 is currently the best value for this work — implementation, docs and research included, not only deep reasoning. The trade accepted: a pinned agent ignores your session model, so a Fable session's subagents run on Opus. The kit never pins `fable`. Commands inherit your session model, except `/doctor`, `/setup-mcp` and `/scaffold`, which run on Sonnet for that turn: they are mechanical and you run them at the start of a session, where a model switch costs no cached prompt. The triage in `/explore`, `/research`, `/decide`, `/plan-work` and `/review-round` runs in a Sonnet subagent, which leaves your session model alone. Since no agent inherits, `CLAUDE_CODE_SUBAGENT_MODEL` in your settings `env` changes none of them on its own; add `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` to apply it to every agent.

## Agent Teams

Each agent loads its own specialized context on invocation:

```
"Use solana-architect to design the vault program"
"Use anchor-engineer to implement the deposit instruction"
"Use defi-engineer to integrate Jupiter swaps"
"Use solana-qa-engineer to write comprehensive tests"
```

Claude will spawn each specialized agent by itself based on context. Agent teams, where several Claude sessions share a task list and message each other, are an experimental Claude Code feature that is off by default, and the kit leaves it off: while it is on, a subagent Claude names can launch as a teammate, which costs more tokens. To opt in, add this to `.claude/settings.local.json`:

```json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

Then ask for a team:

```
"Create an agent team: solana-architect for design, anchor-engineer for implementation, solana-qa-engineer for testing"
```

Recommended team patterns:

| Pattern | Flow | Use Case |
|---------|------|----------|
| **program-ship** | architect → anchor/pinocchio → qa | Build program from spec to tested |
| **full-stack** | architect → anchor → frontend → qa | End-to-end feature |
| **audit-and-fix** | qa → auditor-skill context → anchor | Audit and remediate |
| **game-ship** | game-architect → unity → qa | Game feature |
| **research-and-build** | researcher → architect → anchor/pinocchio | Investigate a protocol or pattern, then design and implement |
| **defi-compose** | researcher → defi-engineer → qa | DeFi integration |
| **token-launch** | token-engineer → frontend → qa | Token creation + launch UI |

## Commands

### Building
| Command | Purpose |
|---------|---------|
| `/build-program` | Build Anchor or native Solana program |
| `/build-app` | Build Next.js/Vite web client |
| `/build-unity` | Build Unity project (WebGL, Desktop, PSG1) |
| `/scaffold` | Generate project scaffolding (program + frontend + tests + CI) |

### Testing & Quality
| Command | Purpose |
|---------|---------|
| `/test-rust` | Run Mollusk, LiteSVM, Surfpool, Trident tests |
| `/test-ts` | Run TypeScript tests (Anchor, Vitest, Playwright) |
| `/test-dotnet` | Run .NET/C# tests (Unity Test Framework, NUnit) |
| `/test-and-fix` | Run tests and auto-fix common issues |
| `/audit-solana` | Comprehensive security audit |
| `/audit-infra` | Infra-first security audit: secrets, supply chain, CI/CD, LLM/skill security, OWASP, STRIDE |
| `/product-review` | Product quality review — UX walkthrough, 8-dimension scorecard (`--harsh` for the roast variant) |
| `/diff-review` | AI-powered diff review for Solana-specific issues |
| `/profile-cu` | CU profiling per instruction with optimization suggestions |
| `/benchmark` | CU benchmarks with before/after comparison |
| `/debug-user-tx` | Replay a user's failing tx against forked state, map error to source |
| `/inspect-mint` | Decode a mint from raw bytes (RPC `jsonParsed` drops extensions), list live authorities, flag integration risks |

### Deployment & Migration
| Command | Purpose |
|---------|---------|
| `/deploy` | Deploy to devnet (always first) or mainnet |
| `/migrate-web3` | Migrate from @solana/web3.js to @solana/kit |
| `/generate-idl-client` | Generate typed clients from IDL (Codama/Shank) |

### Workflow & Setup
| Command | Purpose |
|---------|---------|
| `/quick-commit` | Create branch, format, lint, conventional commit |
| `/pr-description` | Write a PR title and body a reviewer can verify: repro without funds, test plan with real counts, risk |
| `/commit-claude-config` | Version the kit config in git (un-ignores `.claude/`, `.mcp.json`, `.gitmodules` and commits them with `CLAUDE.md`) |
| `/setup-ci-cd` | Configure GitHub Actions pipeline |
| `/firewall` | Show or switch the firewall tier (Off / Relaxed / Medium / High) |
| `/setup-mcp` | Configure MCP server API keys and connections |
| `/resync` | Resync external skill submodules to latest |
| `/add-skill` | Install a pinned skill extension on demand, or list core packs and extensions |
| `/write-docs` | Generate documentation for programs, APIs, components |
| `/explain-code` | Explain complex code with visual diagrams |
| `/plan-feature` | Plan feature implementation with specifications |
| `/update` | Update config to latest version from upstream |
| `/cleanup` | Initialize forked template — setup CLAUDE.md, remove scaffolding |
| `/doctor` | Health check for dev environment + config — read-only, one fix-it command per failure |
| `/dream` | Memory consolidation — dedupe, prune, re-rank MEMORY.md and Project Learnings |

### Agent workflow

A command per step of taking work from a backlog to a merge, two modifiers and `/explore`, which picks the mode for each task, two for picking work back up, `/report` for a page of results, and five short names. [How the agent workflow chains](#how-the-agent-workflow-chains) shows how they fit together.

| Command | Purpose |
|---------|---------|
| `/intake` | Step 1. PRs, issues, a board or a goal into a numbered work list and the questions only you can answer; flags work an open PR or another worktree already covers |
| `/research` | Step 2. Researchers by angle, then an adversary on the claims the triage labels adversarial; dated, sourced claims with re-verify-by dates, written to a file |
| `/decide` | Step 3. Settle a question: a Sonnet triage sends it to a verified panel only where being wrong is costly, the clear calls are decided and recorded, and yours come to you as numbered briefs plus a decision page you answer in the browser; every run writes a new page (`--no-sheet` skips it). With no argument, or when you ask what you need to decide or what unblocks the work, lists every open decision |
| `/plan-work` | Step 4. Owned tasks in waves (files, interfaces, dependencies, a review gate each) in a plan file `/implement` executes |
| `/implement` | Step 5. Run an approved plan: implementers in worktrees from a pinned commit, one integrator, cherry-picks, no merges |
| `/review-round` | Step 6. Review a PR, branch, range or `since <date>` by lens, reproduce High and Critical findings before reporting them, and write a numbered sheet bound to the head commit (`--candidates`, `--clear-wins`) |
| `/fix-wave` | Step 7. Apply the fixes you approved on that sheet and re-verify each |
| `/ship` | Step 8, yours to type. Merge PRs inside a standing order you gave, after green checks and a review of the head commit; closes their issues |
| `/crew` | Steps 1–7 in one run, stopping at your gates; ends by asking you to type `/ship` |
| `/parallel` | Modifier, yours to type. Run every task you give it with parallel agents, each its own lane: file-owned lanes, a worktree per writer, one integrator, verified reports; no triage and no adversary |
| `/adversarial` | Modifier, yours to type. Run every task you give it adversarially, with no triage: its load-bearing claims and decisions through a proposer and an adversary, with proof per premise |
| `/explore` | Yours to type. A Sonnet triage labels each task adversarial, parallel, serial or yours, with a reason you see, then each runs that way; only the tasks labelled yours wait for you |
| `/proceed` | Yours to type. Resume interrupted work from what is on disk, relaunching only what is unfinished |
| `/rundown` | Status for a returning user: decided while you were away, needs your call, in flight, blocked, next. `--handoff` also writes it to a file |
| `/report` | Put results on a local HTML page with every PR, issue, commit and file linked: the runs you name, the inline `/name(...)` calls in its arguments, or else the latest runs. Every page in `.claude/reports/` shares one navigation bar |
| `/adv`, `/par`, `/rep`, `/res`, `/exp` | Yours to type. Short for `/adversarial`, `/parallel`, `/report`, `/research` and `/explore` |

## How the agent workflow chains

The steps split one cycle — read the backlog, settle the open questions, plan, build, review, fix, merge — so you can run any step alone, hand its output to the next, or let `/crew` run steps 1 to 7:

```text
/intake → /research → /decide → /plan-work → /implement → /review-round → /fix-wave → /ship
   gate 1 if questions        gate 2 always             gate 3 if anything open    you type it
```

**Your gates.** `/crew` stops after `/intake` when it has questions for you, always at the plan (nothing is built before you approve it), after `/review-round` when the sheet holds anything to answer or approve, and always before shipping, where it asks you to push the branch, open the PR and type `/ship`. It runs at most two fix waves. A scope you name is a hard stop: plan-only ends at the plan, investigate-only after `/decide`, candidates-only at `/review-round --candidates`'s sheet, and clear-wins-only runs `/review-round --clear-wins`.

**Your calls come as briefs.** Each one is numbered so you answer by number: the question, a recommendation and the best case against it, its premises marked verified or assumed, whether it is reversible, and what it blocks, restated in full until you answer or drop it. Always yours: product intent, a material change of scope or architecture, contradicting a decision you made or a fact you stated, operational approvals (merge, push, publish, deploy, authority changes, anything on another repository), deleting what you did not name, claims in documents others will read, and keys, funds and mainnet. A clear call — every premise verified, the panel agrees or the proof settles it, and it is reversible — is decided, recorded and reported under Done; a cloudy one, and every taste or wording call, comes to you.

**Report pages.** `/report` and `/decide` put what you need to read or answer on a local HTML page in `.claude/reports/`, a new one each time. `/report` shows a TL;DR, sections of findings marked PASS, NEEDS-FIX, REFUTED or UNVERIFIED, and numbered Done / Warnings / Open. `/decide` shows a card per decision, with its options as buttons, the context folded away, a notes box and a Copy answers button, and below the cards the calls the run decided; a run with no call for you writes a report of what it decided instead (`--no-sheet` skips the page). Every page carries a navigation bar listing every page in the folder, in the order they were made, and making a page refreshes the bar on every earlier one. Only https URLs and paths in the project become links, never a dotfile such as `.env` or a path into `.git`; a path opens the file from the folder, and a GitHub pull request, issue or commit is named from its own URL. The agent gives you the line to open a page, `! open <path>` (`! xdg-open <path>` on Linux): the sandbox keeps the agent from opening it, a command you type at the `!` prompt runs outside the sandbox, and `.claude/bin/report-page.sh`, which renders the pages, never opens anything. On a decision page, pick, add notes, press Copy answers and paste the text back. `/decide` takes that text only from a message you send, checks each line against the page's saved JSON, records each answered line word for word as your answer to the proposal it names, and leaves a line marked `not answered` open. In that text an arrow, `|`, `[` or `]` from the page's data reads `->`, `/`, `(` or `)`, so nothing the data holds can pass for your answer. The numbered list still comes in the reply, so a page is never the only way to answer. The folder keeps each page's JSON beside it and an `index.json` of them all. Git ignores it, since a page can hold private decisions: installs list it in the `.gitignore` local-only block, which `/commit-claude-config` leaves in place; `/update` adds that line to existing installs; the folder carries a `.gitignore` of its own; and the script warns when git would still see a page. Where the folder cannot be written, the page goes to `$TMPDIR/kit-reports/`, which every project shares and where paths stay text, or to a private folder beside it when others can write in that one, and the script says so. Pages make no network request, and a decision page's drafts stay in that browser. The folder is never pruned, and each new page rewrites every earlier one to refresh its bar, so a run slows as the folder grows (about 13 seconds at 1,000 pages; the script says so past 500): delete old pages, with their JSON, to trim it. A worktree keeps its own folder, and where `.claude` is a symbolic link, the folder is wherever it points.

**The decision record.** The commands read the decisions in force with `.claude/bin/decisions.sh` and paste them into every agent's brief, and they write to the record from the main session only: your answers and standing orders in your own words, a panel's clear calls, and calls made while recovering from an interruption, which stay provisional until you ratify them. It lives in the git common directory, shared by every worktree of the clone and never committed. Where the helper is missing or fails, a command says so and works from the conversation. [decisions.md](decisions.md) covers the record in full.

**Hand-offs are files.** Results go to `.claude/context/`, which both install modes gitignore, so the next step, a resumed session or a teammate reads a file rather than a memory: research, work lists, plans, review sheets (named after the head commit they cover), per-task reports, `/crew`'s stage file and `/rundown --handoff`'s handoff. `/decide`'s briefs are the exception: they go to the decision record and a page in `.claude/reports/`, where `/report`'s pages go too.

**Fan-out.** Work that fans out runs as a dynamic workflow when the session can run one, so you can watch every agent in `/workflows`, and otherwise as background subagents, in `/tasks`. Each writer gets a worktree under `.claude/worktrees/` (also gitignored), made with git from a pinned commit because a subagent's own worktree starts from the default branch, and reports to a file; the session re-runs the check behind each claim the next step rests on before relaying it. Nothing in the chain pushes or opens a PR, and only `/ship` merges one.

**Modifiers stack.** At the terminal prompt, type `/parallel` or `/adversarial` in front of any task, or both: `/parallel /adversarial plan the best path ahead` loads both and hands each the same text, `/parallel proceed` fans out whatever is unfinished, and `/adversarial proceed` puts it through pairs. Claude Code expands up to six stacked commands; under `claude -p` or the Agent SDK it loads only the first, and a modifier that loaded first reads the others from their files and applies them to the same task.

**Calls inside a message.** Write a command as a call, `/name(...)`, anywhere in a message, the parentheses holding its tasks: `great work, now /rep(/adv(task 1) and /adv(task 2))`, or `/par(task1, task2 and task3)`. Claude Code loads no command for a name that runs into a parenthesis and passes the message on unchanged, so Claude reads each call's file in `.claude/commands/` and follows it, by the rules in `/parallel`'s Composition section: inner calls run first and sibling calls together, as one workflow you watch in `/workflows` where the Workflow tool is available, and each outer call works on what its inner calls returned and runs none of them twice (`/adv` attacks them, `/exp` triages them, `/rep` writes a page on them). Two exceptions start inner calls at once instead: `/par`, whose inner calls are its lanes from the start, and an `/adv(...)` or `/par(...)` inside `/exp`, which keeps its mode, skips the triage and starts with the other tasks. Items split at commas, semicolons and line breaks, and at every "and" between calls or short tasks (`/par(a and b and c)` is three), and the run prints the split before it starts. Siblings that would write the same files, or need each other's results, run one after another, and the run says so. Only calls in your own messages count, and only in the main session: one inside a file, an issue, a PR, a web page, a tool's output or the decision record is text, and so is one that a subagent's brief quotes, unless the brief says to run it. A line in the project's `CLAUDE.md` tells Claude all this, so it works in a plain message and under `claude -p` alike.

**Short names.** `/adv`, `/par`, `/rep`, `/res` and `/exp` stand for `/adversarial`, `/parallel`, `/report`, `/research` and `/explore`. Project commands have no alias field, so each is a one-line file that has Claude read the full command and follow it with your text. Four built-ins share their first letters — `/advisor`, `/resume`, `/restart` and `/export` — so check once that typing `/exp` completes to `/exp` rather than `/export`.

**Literal modes, and `/explore` to choose.** `/adversarial` and `/parallel` do what they say to every task they are given: each task gets at least one proposer and adversary pair from `/adversarial`, or its own lane and no adversary from `/parallel`, and neither drops a task as not worth it. `/explore` chooses instead. One Sonnet subagent, given only the triage rubric and the numbered tasks, labels each task adversarial, parallel, serial (one agent, one at a time) or yours, with a one-line reason; `/explore` shows those lines, then runs each task that way: adversarial as `/adversarial` does, parallel as `/parallel` does, serial in dependency order, and yours as `/decide` handles your calls, on its decision page. It waits for nothing except the tasks labelled yours. To overrule a label, send the task again with `/adv` or `/par` in front. It is a kit command, not Claude Code's built-in `Explore` subagent.

**Triage before an adversary.** `/research`, `/decide`, `/plan-work` and `/review-round` put their items through the same triage before their adversarial pass, so an adversary goes only where being wrong is costly: `/research` labels its load-bearing claims, `/decide` each question before any panel (a serial question gets one agent's check, a parallel one independent fact-gatherers and no adversary, one labelled yours a brief), `/plan-work` the plan's premises, design calls and gates, and `/review-round` its findings. Every High or Critical finding is still reproduced before it is reported, and so is every finding labelled adversarial, which then goes to the peer that confirms, disputes or downgrades it. An item the triage leaves unlabelled counts as adversarial, the labels appear in each step's output, and `/adversarial` or `/adv` in front of the step sends every item to the adversary instead of starting pairs of its own.

**Each step has a default mode.** A modifier typed in front of a step adds the mode it lacks, for that run only: `/adversarial /intake 41 42` puts the work list's claims to an adversary as well. `/crew` runs every step in its default. In front of `/research`, `/decide`, `/plan-work` or `/review-round`, `/adversarial` (or `/adv`) also skips their triage and sends every item to the adversary.

| Step | Runs by default |
|------|-----------------|
| `/intake` | Parallel: one reader per input when there are several |
| `/research` | Both: a researcher per angle at once, then an adversary on the claims the triage labels adversarial |
| `/decide` | Adversarial where the triage says so: a proposer and an adversary, and a verifier per premise; one agent's check, or independent fact-gatherers, for the rest |
| `/plan-work` | Adversarial: an adversary attacks the premises, design calls and gates the triage labels adversarial, before you see the plan |
| `/implement` | Parallel: a wave's tasks at once, one owner per file |
| `/review-round` | Both: a reviewer per lens at once; every High and Critical finding and every finding the triage labels adversarial reproduced, and the adversarial ones confirmed, disputed or downgraded by a peer |
| `/fix-wave` | Parallel: approved fixes grouped by the files they touch, each fix re-checked |
| `/ship` | Neither: one PR at a time |

**`/ship`'s limits.** It merges one PR at a time, only inside a standing order you gave (PR numbers typed with `/ship` are one), once every check has passed and a review covers the PR's head commit: a `/review-round` sheet naming that SHA, or a GitHub review of it by the reviewer your order named. With no reviewer named, the sheet must have nothing open at Critical or High. Before the first PR it settles the merge method, so the train never stops partway for it: the method your order names, else a merge-method principle in force, else the default GitHub reports for you (`gh repo view --json viewerDefaultMergeMethod`). `gh repo view` does not leave the sandbox, so where it cannot authenticate, `/ship` asks you once and records your answer as a principle, and no later run asks again. Two merge-method principles in force that disagree are a conflict: it reports them and asks you rather than pick one, and your answer supersedes both. It merges with `--match-head-commit`, so GitHub refuses if the head moved; never uses `--admin`, `--auto` or `--delete-branch`; never pushes to a PR branch; re-checks the files that changed on the base since the PR branched; closes the linked issues left open; and stops the train at the first failure. No standing order covers mainnet, program upgrades, authority changes, keys, funds, deletions or another repository. The firewall lets `gh pr merge` through at Relaxed and asks at Medium, an ask a bypassed permission mode skips, so below High these rules are what holds; High denies it, and `/ship` hands you the merge commands to run.

**Resuming and catching up.** `/proceed` takes stock from disk — git, the worktrees, and the files in `.claude/context/` — re-reads the decisions and relaunches only what is unfinished, never two writers on one lane; a call it makes without you is recorded as provisional. `/rundown` reports from the record, git and `gh`: what was decided while you were away (one-way calls and calls against a recommendation first), what needs your call, what is in flight, what is blocked and what is next.

**Cost.** Ten of the twenty are model-invocable, so Claude can run one when your request matches it ("another review round", "give me the rundown", "report on what you found"); their descriptions join every session's listing, about 960 characters (roughly 220 tokens) in all. `/ship`, `/parallel`, `/adversarial`, `/proceed`, `/explore` and the five short names set `disable-model-invocation: true`: Claude does not start them on its own judgement. They run when you type them or write them as calls in your message, and `/adversarial`, `/parallel` and `/explore` also when you ask for that mode in words ("adversarially", "in parallel"); until then they cost no context. The triage adds one Sonnet subagent to each run of `/explore`, `/research`, `/decide`, `/plan-work` and `/review-round`.

**Other installs.** A plugin install namespaces them (`/solana-ai-kit:crew`) and has no `.claude/bin/`, so the record and the report pages are absent and each command works from the conversation; [plugin.md](plugin.md) has what else to set up. An `--agents` install copies them to `.agents/commands/` as reference prompts an agent can follow when you point it at one; workflows, stacking and `/crew`'s chaining through the Skill tool are Claude Code features and do not carry over. A plugin install also has no project `CLAUDE.md`, so a call written into a plain message is not resolved there: start the message with a command (`/solana-ai-kit:parallel /adv(task 1) and /adv(task 2)`), whose Composition rules then apply; the short names read the plugin's own copy of their command. An existing install gets the composition line only once you merge `CLAUDE.md.upstream` (`AGENTS.md.upstream` after `--agents`), which `/update` leaves beside your own file. A new `--agents` install gets the line in `AGENTS.md`, its paths pointing at `.agents/commands/`.
