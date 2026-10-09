# Agentic firewall — finished spec

Four tiers (**Off / Relaxed / Medium / High**, default **Relaxed**) gating file access, destructive commands and egress. Policy approved by the maintainer 2026-10-02. Produced from four adversarial reviews plus direct verification in-session.

---

## 1. Three findings that reshape the approved matrix

### 1.1 Prompts belong in the hooks, because `ask` cannot be CI-safe

Verified in-session, twice:

- `git clean -n` matches `Bash(git clean *)` in the **ask** list → **ran silently, no prompt**.
- `sudo -n true` matches `Bash(sudo *)` in **deny** → **blocked**.

**Correction (T2, settled after this section was written): both candidate causes above are wrong, and the heading overstates it.** A *content-scoped* ask rule like `Bash(git push *)` does fire, in default mode **and** under bypass, with `autoAllowBashIfSandboxed` at its default `true`. What the sandbox voids is only a **bare `Bash` or `Bash(*)`** ask. The published documentation even uses `Bash(git clean *)` as its worked example of an ask that fires — so the `git clean -n` observation above remains unexplained, and is consistent only with the live rule having been bare or not matching. It stays UNVERIFIED as to cause.

The design is unchanged, for a reason that has nothing to do with reliability: **an `ask` is a hard failure under `claude -p`, and a hook can decide not to prompt when there is no interactive user.** That is what makes Relaxed CI-safe, and no permission rule can express it. So prompts stay in the hooks — not because `ask` does not work, but because `ask` cannot be made CI-safe. `validate.sh` now rejects a bare `Bash` entry in `permissions.ask`, which is the real defect this section was circling.

> **Every prompt is expressed as a hook returning `permissionDecision: "ask"`. Every hard block is hook `exit 2` or a `permissions.deny` rule. No tier distinction rests on `permissions.ask`.**

Hooks demonstrably work here — the secrets hook blocked three of my own commands, and the on-chain gate blocked `--final` via exit 2.

### 1.2 A mid-pattern `*` does not match an empty string

`Bash(anchor * --final*)` is in deny. `anchor --final` **executed**. So every two-wildcard rule is inert when the gap is empty. Live instances:

| Rule | Escapes as | Actually protected by |
|---|---|---|
| `Bash(anchor * --final*)` | `anchor --final` | nothing (harmless in that form) |
| `Bash(solana program deploy *--final*)` | `solana program deploy --final ./p.so` | **the on-chain hook**, verified exit 2 |
| `Bash(spl-token authorize *--disable*)` | `spl-token authorize --disable …` | the on-chain hook |
| `Bash(git push * -f *)` | `git push origin -f` | nothing |
| `Bash(solana-keygen new * -f*)` | `solana-keygen new -f` | its zero-gap twin, already present |

Fix: add the zero-gap twin of every two-wildcard rule. Cheap, do it regardless. Corollary: `Bash(gh auth token *)` **does** match the bare `gh auth token` — a trailing `*` with a space before it matches bare, but only when it is the rule's *only* wildcard.

### 1.3 Descending tiers require whole-block regeneration, and only the sandbox can carve out

Lists merge across settings sources and never override; precedence is deny → ask → allow with no un-deny and no un-ask primitive. Effective policy over N sources is `deny = ∪denies`, `ask = ∪asks − deny`, `allow = ∪allows − deny − ask` — monotonically tightening. A layered tier system therefore collapses to the strictest tier any layer ever wrote, permanently.

`!` negation carves only from `path`/`./path` deny entries listed earlier **in the same file**, never from `~/`, `/` or `//`, and cannot reopen a file inside a wholly-denied directory.

**`sandbox.filesystem` is the only layer in Claude Code with a genuine carve-out:** `denyRead: ["~/"]` plus `allowRead: ["~/projects"]` re-opens the narrower region, and narrowness decides rather than source order — so it survives merging. That is the mechanism for descending tiers.

Resulting shape:

1. One generated `permissions` + `sandbox` block in `.claude/settings.json`, **replaced wholesale** per tier, never appended. Tier recorded in `.claude/security.json` with the exact rule strings written (`enforced.ruleIds`) and a hash.
2. **`permissions.deny` is identical across all four tiers** — the never-allowed set. Deny is the one axis where merge-monotonicity is harmless because every tier agrees.
3. Tier-varying path decisions live in `sandbox.filesystem.denyRead`/`allowRead`.
4. The two scalars — `blockReadsOutsideWorkingDirectories` and `defaultMode` — take the highest-precedence source, and project settings outrank user settings, so they are the only tier knobs the kit can guarantee. (`defaultMode` is on `validate.sh`'s retired-keys denylist and stays unused.)

Sandbox paths use different conventions from permission rules: `.` is relative to the settings file's directory, so a `.` entry means the project root only in project settings.

---

## 2. The never-allowed set — identical at every tier

Expressed as `permissions.deny` plus a matching `sandbox.filesystem.denyRead`/`denyWrite` entry. Ship **both** the bare and `/**` form for every directory (`"~/.aws"` and `"~/.aws/**"`) — a `/**` pattern does not match the directory entry itself.

**Credentials and vaults:** `~/.ssh` (incl. `~/.ssh/config` — `ProxyCommand` is RCE), the GPG dir, macOS keychains, Linux keyrings, browser profile stores, extension settings stores, password-manager vaults, `~/.claude/.credentials.json`.

**Code-execution-on-next-build files** — the highest-value omissions from every earlier draft:
- `~/.cargo/config.toml` — `[target.*.runner]` and `rustflags` execute on the next `cargo test`
- `~/.zshenv` — the only zsh file sourced for **non-interactive** shells
- `~/.gitconfig`, `~/.config/git/config` — `core.hooksPath`, `core.editor`, `alias.*`, `credential.helper`
- in-project `**/.cargo/config.toml`
- `~/.cargo/credentials` (legacy, no extension) alongside `credentials.toml`

**Persistence:** `~/.zshenv`, `~/.zshrc`, `~/.zprofile`, `~/.zlogin`, `~/.bashrc`, `~/.bash_profile`, `~/.profile`, `~/.config/fish/config.fish`, `~/Library/LaunchAgents`, `/Library/LaunchDaemons`, `~/.config/autostart`. Deny at **every** tier, not ask — no Solana task edits a login shell file, and it removes a headless hard-fail.

**Shell and REPL history:** `~/.zsh_history`, `~/.zhistory`, `~/.bash_history`, fish history, `~/.python_history`, `~/.node_repl_history`, `~/.psql_history`, `~/.sqlite_history`, `~/.lesshst`.

**Self-protection — High only.** At bypass, protected-path writes are *allowed* and allow rules do not pre-approve them, so only an explicit deny stops the agent rewriting its own tier. Use `Edit(...)`, not `Read(...)`: a Read deny also blocks Edit/Write but leaves `NotebookEdit` open and would block the kit's own tooling from reading its config.

Off, Relaxed and Medium do **not** carry this group: below High the kit defers to a user who chose to customize their own installation, which is the same split that makes High the only tier to refuse Cloudflare's `execute`. The **guard hooks are carved out of that and denied at every tier** (see the unconditional set below), so what the lower tiers hand back is the configuration, not the scripts enforcing it.

```
Edit(/.claude/settings.json), Edit(/.claude/settings.local.json),
Edit(/.claude/settings.*.json), Edit(/.claude/security.json),
Edit(/.mcp.json),
Edit(~/.claude/settings.json), Edit(~/.claude/settings.local.json),
Edit(~/.claude/settings.*.json), Edit(~/.claude/.credentials.json),
Edit(~/.claude/agents/**), Edit(~/.claude/commands/**),
Edit(~/.claude/skills/**), Edit(~/.claude/rules/**),
Edit(~/.claude/output-styles/**), Edit(~/.claude/plugins/**),
Edit(~/.claude/cowork_plugins/**), Edit(~/.claude/workflows/**),
Edit(~/.claude/routines/**), Edit(~/.claude/scheduled_tasks.json),
Edit(~/.claude/loop.md), Edit(~/.claude/daemon.json),
Edit(~/.claude/launch.json), Edit(~/.claude/shell-snapshots/**),
Edit(~/.claude/local/**)
```

The user-scope half is an enumeration of the **policy surface** — what Claude Code loads as configuration or executes — and not the blanket `Edit(~/.claude/**)` it replaced. `~/.claude/hooks/**` is absent from the list above only because it sits in the unconditional set instead. That glob also denied `~/.claude/projects/**/memory/**`, the harness's own file-based agent memory, and `~/.claude/CLAUDE.md`, which `CLAUDE-solana.md` tells every user project to use for cross-project preferences: the kit was forbidding a documented feature and its own shipped instruction. Because deny beats allow in every scope with no un-deny primitive and no specificity tiebreak, no allow rule could carve either back out — the glob itself had to go. Deliberately left writable: caches, logs, session state, `plans/`, `keybindings.json` (which the `keybindings-help` skill exists to edit) and the two paths above. Session transcripts are a separate rule and stay **read**-denied at Medium and High (`~/.claude/projects/**/*.jsonl`, `~/.claude/history.jsonl`), so the transcripts remain unreadable while the memory directory beside them is writable. Two of the entries are not obvious: `shell-snapshots/` is sourced into every Bash invocation, so a write there is code execution on the next shell command, and `local/` is where a local `claude` install's binary lives.

**Unconditional at every tier, Off included** — the rules that are not "customizing your installation": `Edit(/.claude/hooks/**)` and `Edit(~/.claude/hooks/**)`, because these are executable shell scripts that *implement* the mainnet gate, the keypair-read block and the egress denylist rather than config that declares them, and because `/firewall` changes every tier knob without touching them, so customizing never requires editing a guard; `Bash(claude *)` and `Bash(claude)`, because a nested `claude -p --dangerously-skip-permissions` re-rolls the whole policy in a child process and `npm`/`npx`/`node` are allowed; `Edit(//**/managed-settings.json)`, because managed settings belong to an administrator rather than to the user; and `Edit(/.safe-ai-skill/**)`, a third-party security tool's policy whose deep-merge could loosen any of its gates, spend caps included. Un-closable residuals to document: `--settings`, `--permission-mode`, `CLAUDE_CONFIG_DIR`, `--setting-sources` (excluding a source drops its Read denies, Edit rules *and* sandbox entries).

**Matcher-evading wrappers** — rules cannot see past these, so deny the wrappers themselves: `Bash(env *)`, `Bash(sh -c *)`, `Bash(bash -c *)`, `Bash(bash -lc *)`, `Bash(zsh -c *)`, `Bash(git -c *)`, `Bash(git -C *)` (both at **every** tier. `-c` is arbitrary code execution via `core.fsmonitor`. `-C` merely changes directory, but every destructive git deny is anchored on the literal subcommand, so a `-C <dir>` prefix defeats all of them — verified against the generated set: `git -C . clean -xdf` and `git -C . reflog expire --expire=now --all` both pass, and `-C .` needs no second repository so no sandbox fence is behind it. Scoping it to High was proposed in rule set 5 and reversed for exactly that reason), `Bash(flock *)`, `Bash(watch *)`, `Bash(setsid *)`, `Bash(ionice *)`, `Bash(devbox run *)`, `Bash(direnv exec *)`, `Bash(mise exec *)`, `Bash(docker exec *)`. `git -c core.fsmonitor=/tmp/x.sh status` is arbitrary code execution that evades every `git <subcmd>` rule.

**Whole-binary denies** where subcommand granularity is defeated: `Bash(security *)` (`security -i` reads subcommands from stdin), `Bash(crontab*)`, `Bash(launchctl *)`, `Bash(defaults *)`, `Bash(gh alias *)` (aliases expand inside gh, invisible to the matcher).

**Git's own alias mechanism is the same evasion, persisted** — and unlike the two above it was not in this list until rule set 6. `git config alias.z '!git clean -fdx'` is an ordinary config write; the destruction happens in a later `git z`, where no glob anchored on a subcommand and no hook classifying subcommands has a verb to match, and the alias survives into every later session. `Bash(git config *alias.*)` plus its zero-gap twin `Bash(git config alias.*)` cover `--global`, `--local`, `--file`, `--add`, `--replace-all` and the newer `git config set` form while leaving every other config key alone.

**Those two rules are half the gate, and the other half is a hook, because a glob cannot express either part of what was left.** (1) Git's section and variable names are case-insensitive and a permission glob is not, so `git config Alias.z` walks straight past both rules — verified: `git config --file f Alias.Y x` is read back by `--get alias.y`. `alias` has 32 case spellings and that is one key of seven, so there is no finite glob set to write. (2) The other code-executing keys — `core.pager`, `core.editor`, `core.hooksPath`, `sequence.editor`, `credential.helper`, `diff.external`, each of which names a program git runs later — are not aliases, and were covered only in their one-shot `git -c` form and as `Edit` denies over `~/.gitconfig`. Both are closed in `egress-guard.awk`'s `GITEXEC` pass: it anchors on subcommand position, normalises the key to lowercase before comparing, consumes `--file <f>`'s operand so the key cannot hide behind it, handles the `git config set` and `--edit` forms, and **denies at every tier** — no ladder, because what is stopped is not a destructive act whose blast radius a tier could scale but a key that makes git execute an attacker-chosen command at some later, unrelated moment, possibly in another session. The pass is deliberately narrower than the globs in one direction: it does **not** gate reads (`--get`, `--get-all`, `--get-regexp`, `--list`, `-l`) or the removers (`--unset`, `--remove-section`), which the globs caught as collateral. The rules stay in place regardless — they decide at the permission layer, before the hook runs, and a hook miss is a silent open door where a glob is a loud closed one.

**Still open, in both layers:** a shell redirect into `.git/config` is not a `git config` command at all, so neither a subcommand glob nor a subcommand-parsing hook has anything to anchor on; `.git` is in `sandbox.allowWrite` and carries no `Edit` deny the way `~/.gitconfig` does. `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` and `GIT_CONFIG_GLOBAL` in the environment are `git -c` by another name and are likewise uncovered.

**NOT evasions for PERMISSION RULES** — Claude Code's matcher strips these before matching, so no rule is needed: leading env assignments, subshells, command substitutions, control-flow bodies, and the `timeout`/`time`/`nice`/`nohup`/`stdbuf`/`command`/`builtin`/`noglob` wrappers plus bare `xargs`. (`env` and flagged `xargs` *are* evasions even there — hence the deny list above.)

**They ARE evasions for the HOOKS, and the first version of this section said otherwise.** A hook does its own matching against the raw command text; nothing strips a wrapper for it. Measured on `main`: every wrapper in that "not an evasion" list reached `onchain-guard.sh` with the wrapper attached and made it **silent** — including on `solana program-v4 finalize`, an irreversible action whose `exit 2` that hook is the *only* guard for, since the permission rule covering it has the two-wildcard shape. Worse, `Bash(command *)` and `Bash(xargs *)` sit in `allow`, so the wrapped form was pre-approved.

The error was conflating two layers that match differently. **Every guard must normalise each statement before matching** — drop the wrapper, keep `VAR=` assignments so `ANCHOR_PROVIDER_URL=` still resolves, collapse whitespace — and the matching regex itself stays unchanged. Fixed in PR #138; a reader of this section before that merge would have concluded no defence was needed.

---

## 3. Per-tier, as implementable rules

| | Off | Relaxed (default) | Medium | High |
|---|---|---|---|---|
| `sandbox.enabled` | false | true | true | true |
| `blockReadsOutsideWorkingDirectories` | absent | absent | absent | **true** |
| `sandbox.filesystem.denyRead` | — | never-allowed set only | + Solana config `*.json`, transcript `*.jsonl`, host creds | `["~/"]` + toolchain `allowRead` |
| Project `.env` | — | read+write | read; **write deny** (see §3.1) | read deny, **write allow** |
| Project keypairs | — | allow | allow (see §3.2) | allow |
| Solana config dir | — | allow | deny `*.json` only (see §3.3) | deny `*.json` only |
| Host creds | — | **allow** (maintainer's call) | deny | deny |
| Writes outside repo | — | allow | hook-ask | deny |
| Force push | — | allow | hook-ask | deny |
| Recoverable git | — | allow | allow | hook-ask |
| Unrecoverable git | — | **deny** (see §3.4) | deny | deny |
| Mainnet writes | — | hook-ask, loud | hook-ask, loud | deny |
| `npm`/`cargo publish` | — | hook-ask | deny | deny |
| Egress | — | `deniedDomains` | + narrowed | + minimal (see §4) |

### 3.1 `.env` write becomes deny, not ask

An ask on `.env` write is walked around by `python3 -c "open('.env','a').write(...)"`, `perl -pi`, `sed -i`. Nothing in a Solana build legitimately rewrites `.env` — the human writes it. Deny also removes a headless hard-fail. The three kit commands that *do* write it get the §5 rewrite.

### 3.2 Project keypairs stay allow at Medium, correcting the approved matrix

Medium asking for the one file High allows makes Medium **stricter than High** on exactly that file — an inversion that generates bug reports. Make it uniform. The intended control is deny-Read plus sandbox `allowRead`, which blocks the *model* while letting the *subprocess* read:

```jsonc
"permissions": { "deny": [
  "Read(**/*-keypair.json)", "Read(**/target/deploy/*keypair*.json)",
  "Read(**/id.json)", "Read(**/wallet.json)",
  "Read(**/authority*.json)", "Read(**/deployer*.json)"
]},
"sandbox": { "filesystem": { "allowRead": ["./target", "./.anchor"] } }
```

**T3 is settled, and this design does not work — struck.** Precedence is *narrower path wins*, not *allow wins*, which §1.3 of this very document already states. The wildcard deny `Read(**/*-keypair.json)` is narrower than the directory allow `./target`, so the deny holds — and it holds for the subprocess too, which would break `anchor build`, `anchor test` and `anchor deploy`. `allowRead: ["./target"]` was a no-op for widening in the first place. **The shipped behaviour is the plain `allow`.** If the model-versus-subprocess asymmetry is wanted later, the route is a `PreToolUse` hook on `Read`: only `Read(...)` *deny rules* project into the sandbox, so a hook blocks the model without touching the subprocess. Note `target/deploy/*-keypair.json` is multi-segment so gets no any-depth promotion — it misses `programs/x/target/deploy/` and any `CARGO_TARGET_DIR`. And `*-keypair.json` does not match `keypair.json`. Also: deny rules get any-depth promotion, **allow rules do not** — so an allow must be written `Read(**/.anchor/**)`, never `Read(.anchor/**)`.

### 3.3 The Solana config dir cannot be dir-denied

`anchor init` writes `wallet = "~/.config/solana/id.json"` into `Anchor.toml`, so the wallet `anchor` uses is outside the project. Because `Read` denies project into `sandbox.denyRead` and the sandbox covers Bash *and children*, a dir-wide read deny makes `solana`/`anchor` unable to resolve a signer at all — verified: a bogus wallet path gives `Error: Unable to read keypair file`. Deny `*.json` under it and leave `cli/config.yml` readable so `solana config get` keeps working. Never add the directory to `denyRead`.

### 3.4 Unrecoverable git is deny at every tier including Relaxed

`git reflog expire --expire=now --all` and `git gc --prune=all` are what make history truly unrecoverable; everything else is reflog-recoverable. No agent has a legitimate reason to run them.

### 3.5 Verified-live git evasions to fix

| Rule | Evades as | Corrected |
|---|---|---|
| `git clean -fd *` | `git clean -xdf`, `-dfx`, `--f -d` | `Bash(git clean *)` — git clean is never non-destructive |
| `git reset --hard *` | **`git reset --ha HEAD`** (long options abbreviate) | add `Bash(git reset *--ha*)` |
| `git checkout -- .` | **`git restore .`** | `Bash(git restore *)` — **absent from the design entirely** |
| `git branch -D` | `git branch --delete --force`, `-fd` | `*-D*`, `*--delete*`, `*-f*` |
| `git gc --prune=now` | **`git gc --prune=all`** | `Bash(git gc *--prune*)` + `Bash(git prune *)` |
| force push | **`git push origin +main`**, `+refs/heads/main:...`, `git push origin -f` | glob cannot express `+refspec` → hook. **Done** (rule set 5): `egress-guard.sh` scans the `git push` statement by word — allow at Relaxed, ask at Medium, deny at High, `--dry-run`/`-n` exempt |
| `solana config set --keypair` | **`-k /path`** | add `*-k*` |
| `npm publish` | **`npm run release`** where the script is `npm publish` | `Bash(npm run *publish*)`, `release*`, `deploy*`, `npm exec *`, plus yarn/pnpm/bun |
| `gh repo delete` | `gh api -X DELETE /repos/O/R` | `Bash(gh api *)` deny at Medium+. **Done** (rule set 5). The subcommand itself was left with no rule of its own until **rule set 6**, which denies `Bash(gh repo delete *)` and its zero-gap twin at every tier, beside `gh issue delete` |
| `gh secret set` | `gh variable set`, `gh api --method PUT .../secrets/NAME` | add `gh variable set`; reconsider leaving PUT open |

Long-option abbreviation works in **git** but not in the **solana** CLI (clap v2, no `InferLongArgs`) — verified. `git push --fo…` is ambiguous, so abbreviation cannot force-push.

### 3.6 Rules that protect nothing

- **`Read(**/Local Extension Settings/**)`** — relative `**/` is cwd-bounded; browser profiles live under `~/Library`. Shipped today and in the approved set. Needs `~/`-anchored forms.
- **Medium's "project `.env` allow + external `.env` deny" is unexpressible.** `Read(**/.env)` ≡ `Read(.env)` and cannot reach a sibling project; `Read(//**/.env)` kills the project's own and allow cannot carve out; `Read(~/**/.env)` kills it too whenever the repo is under `$HOME`. Move it to `blockReadsOutsideWorkingDirectories` + sandbox `denyRead`/`allowRead`.
- **Mainnet denies must anchor to the verb, never the cluster string** — otherwise `anchor verify --provider.cluster mainnet` and `solana program dump --url mainnet-beta`, both read-only, get blocked.
- **Two deny rules silently kill two ask rules today**: `git clean -fd *` and `git push --force *` appear in both lists; deny wins. Add a test forbidding a pattern in both.

---

## 4. Egress — the kit cannot enforce it, and must say so

**Settled (T1). Both reviews were right about different things.** `sandbox.network.strictAllowlist` does exist in the 2.1.267 binary, *and* it is scope-gated out of the only files the kit writes: it is honored from user, managed/policy and `--settings` scope, and ignored in `.claude/settings.json` and `.claude/settings.local.json`. `allowedDomains` itself *is* read from project scope, but it only ever **prompts**, and under `bypassPermissions` it is inert entirely.

So the kit cannot ship egress enforcement from project scope. `deniedDomains` is the ceiling, and it is genuinely honored — verified by a live refusal, where a denied host returns a 403 on CONNECT *with* a `sandbox_violations` block naming the reason. That block is also the discriminator between a sandbox refusal and an ordinary proxy refusal, which look identical otherwise.

Do **not** add `allowedDomains` to the shipped project `settings.json`: under `--dangerously-skip-permissions` it would read as an allowlist while permitting everything.

If the docs are right, **High has no egress control the kit can ship.** What remains:

- **`sandbox.network.deniedDomains`** — refused in every mode. Ship a known-exfil denylist: request-bin and tunnel services, paste sites, file drops.
- **Document `strictAllowlist` as a line the user adds to `~/.claude/settings.json`**, not something the kit installs.
- **Command rules** for the three primitives that survive a destination layer anyway, because their destination is legitimately allowlisted: `npm publish`, `cargo publish`, `git push` to an arbitrary remote (`git remote add` is allowed).
- **A position-anchored hook** for data-carrying `curl`/`wget`. A working prototype exists (262-line awk, 231 assertions green across three tiers, 4.5 ms/call) with a #111 regression corpus.

**Correcting the approved decision:** do **not** ask on `curl -d` at Relaxed. `curl -X POST -d '{"jsonrpc":"2.0",...}' https://api.devnet.solana.com` is the most common curl in Solana development, and an ask there prompts constantly *and* breaks the kit's own shipped `claude.yml` Action. Relaxed gates only the `@file` and `--upload-file` forms; inline bodies become ask at Medium, deny at High.

**MCP is partly gateable — and the earlier claim that it was not was wrong in one specific way.** This section used to say `context-mode.ctx_execute` runs "outside every rule and hook". The rule half is right; the hook half is not, and the correction is what the gating below is built on.

What is true, verified against the current docs rather than inferred:

- **Permission rules carry no argument specifier.** Tool-*name* globs do work after a literal server prefix — `mcp__context-mode__*` in an allow rule, `mcp__*` in deny or ask — but there is no `Bash(cmd *)` equivalent for arguments. Worse than absent: *"When Claude Code loads a settings file, it skips any `mcp__` rule that has parentheses"* ([permissions](https://code.claude.com/docs/en/permissions)), reporting it in the invalid-settings dialog and in `claude doctor`. So a rule like `mcp__context-mode__ctx_execute(language=shell)` reads as policy and is none. Argument matching exists only through the `--disallowedTools` CLI flag, which the kit cannot ship from a settings file.
- **Hooks do see MCP tools, and their arguments.** A `PreToolUse` matcher is a JavaScript regex, unanchored and case-sensitive, so `mcp__context-mode__.*` matches every tool from that server; stdin carries `tool_name` plus the **whole `tool_input` object** ([hooks](https://code.claude.com/docs/en/hooks)). `ctx_execute`'s `code`, `ctx_execute_file`'s `path` and `ctx_fetch_and_index`'s `url` are therefore all inspectable. Exit 2 blocks an MCP call exactly as it blocks Bash.
- **A local server runs outside the OS sandbox.** Now empirically confirmed, not asserted. Same machine, same session: `ls ~/.claude/ide` through the Bash tool returns `Operation not permitted`; the identical command through `ctx_execute` exits 0, and `test -w "$HOME"` succeeds there while `$HOME` is not in the Bash sandbox's write allowlist. Re-run those two to re-verify. So `ctx_execute` has strictly *more* reach than Bash, not merely different reach.

**Why that combination decides the design.** Bash sits behind three layers, and only two of them read the command string: `permissions.deny` and the hooks match patterns, and underneath them the sandbox refuses at the syscall, which no obfuscation reaches. For MCP the third layer does not exist, so a hook is a single pattern layer — and a single pattern layer is one obfuscation away from nothing. Hence two mechanisms, not one:

1. **The three guards now also run on `mcp__context-mode__.*`.** `lib-headless.sh` normalises the tool input into the same `KIT_CMD` the Bash guards read, so one copy of the corpus covers both surfaces. Shell payloads (`ctx_batch_execute`'s `commands[].command`, `ctx_execute` with `language: shell`) pass through verbatim and are gated at full fidelity. Covered: credential reads, the irreversible on-chain set, mainnet writes, and — new, because the sandbox cannot do it here — the tier's own `deniedDomains` list applied to any URL in the payload.
2. **Medium and High deny the executor and the fetcher by name**, since "there is no arbitrary executor here" is their promise and a tool that cannot be called cannot be obfuscated past: `ctx_execute`, `ctx_execute_file`, `ctx_batch_execute`, `ctx_fetch_and_index`, and `ctx_index` — whose `path` takes a *directory*, with `followSymlinks` and `respectGitignore` available, and whose results come back through `ctx_search`, making it an arbitrary-file-read primitive and the exact negation of High's read fence. Off and Relaxed keep every tool and rely on the hooks, which is what keeps Relaxed usable and CI-safe. The context-compression tools survive at every tier: `ctx_search`, `ctx_stats`, `ctx_doctor`, `ctx_purge`, `ctx_insight` (one fixed URL), `ctx_upgrade` (returns a command for Bash to run, where all three layers still apply).
3. **High, and High alone, also denies `mcp__cloudflare__execute`** — the only tool-name deny that distinguishes the two gated tiers. `cloudflare/mcp` has three tools: `docs` and `search` are read-only and stay callable at every tier, while `execute` runs JavaScript calling `cloudflare.request()` across the whole write API. The split follows from how the server arrives rather than from what it can do: `context-mode` is a **default** server, so Medium and High both have to speak for a user who never chose it, whereas Cloudflare is opt-in behind a token whose scopes the user picks, which Medium treats as an explicit choice to respect. High's claim is stronger — no arbitrary executor is reachable — so it refuses regardless. Residuals: the rule matches the local server *name* from the documented add command, and `?codemode=false` swaps the three tools for ~2,500 per-endpoint ones that the rule does not name. The hooks do **not** cover this server (their matcher is `Bash|mcp__context-mode__.*`), so below High there is no pattern layer either.

One evasion that had to be closed rather than documented: a hook that exceeds its timeout does **not** block the call, and a 75 KB non-shell payload costs ~7.3 s across the three guards against a 10 s budget — so padding alone would have walked past the whole corpus. MCP payloads over 32 KB are therefore refused rather than left uninspected (truncating would inspect the head and ignore the tail). Bash is deliberately exempt: a pattern miss there still meets the sandbox, so there is no fail-open to protect against.

**What is still open, stated rather than papered over.** A non-shell `ctx_execute` payload is foreign syntax, matched best-effort: credential paths are found by flattening the code, and a shell-out like `os.system("solana program deploy …")` is found because `(` starts a statement, but a path assembled at runtime (`"/".join(parts)`, base64, a variable) defeats the corpus, and for MCP there is no sandbox behind it to catch what the pattern misses. The domain list is matched on hostname, so an IP literal or a redirect walks past it. `permissions.deny` cannot express any of this, and the `--disallowedTools` flag that could is not reachable from a settings file. **Playwright was left opt-in and ungated at every tier, and rule set 6 closed that at the two gated ones.** `browser_network_request` is an arbitrary HTTP client, `browser_run_code_unsafe` an arbitrary code executor, and `browser_evaluate` an in-page JS evaluator this section missed when it named only the first two: Medium and High now deny the first two by name, High also the third, on the same reasoning as the context-mode group — a tool that cannot be called cannot be obfuscated past, and for this server there is no pattern layer behind the deny either, the guards' matcher being `Bash|mcp__context-mode__.*`. `browser_evaluate` waits for High because reading state out of a running dApp is ordinary testing, which is friction Medium's promise does not require. No matcher touches any of the three at Off or Relaxed. The honest summary: at Off and Relaxed, `context-mode`'s executor is gated by pattern and nothing else; at Medium and High it is refused outright, and that is the only state in which the egress and read-fence promises hold against it. Cloudflare's `execute` is refused at High only, and below that it has no pattern layer either.

**Also unusable:** `sandbox.credentials` — the purpose-built feature for this job — is not applied at all from project or local settings. And `sandbox.enabled: false` in user settings beats a project `true`, so High's OS layer is user-revocable.

---

## 5. Shippability gate — must land before any tier

Items 1-5 each break `anchor test` or `/doctor` on a default install.

1. **Never put the Solana config dir in `denyRead`** (§3.3).
2. **Carve toolchain roots out of High's outside-write deny**: `~/.cargo/**`, `~/.rustup/**`, `~/.cache/solana/**`, `~/.local/share/solana/**`, `~/.avm/**`, keeping credentials and `config.toml` denied. Verified: cargo needs *write* to the registry cache or the build dies.
3. **Allow the platform temp root at every tier.** `mktemp -d` is at `update.sh:37`, inside the frozen 1-93 byte range, and **already fails under the sandbox** — `/update` and `/add-skill` are broken today. (Same failure truncated a tracked file earlier in this session when an unguarded variable expanded to empty.)
4. **Allow writes under `git rev-parse --git-common-dir`** so submodule init survives a linked worktree.
5. **Surfpool needs unsandboxed Mach access.** `surfpool start` panics instantly under the sandbox (macOS SystemConfiguration), runs clean without it. Breaks `anchor test`'s Anchor-1.x default path, `/test-rust`, `/test-ts`, `/profile-cu`, `/debug-user-tx` — at every tier, today. `allowLocalBinding` does not cover it. **Conflicts with deleting `excludedCommands`** — see §7.
6. **Rewrite the `.env` commands**: `/setup-mcp`, `/cleanup`, `/build-app`, `/doctor`, plus `update.sh:388`. Names-and-presence helper for reads; keep writes permitted. (`/quick-commit` is **not** one — it only excludes `.env` from staging.) The same work resolves the safe-ai-skill `secret_read` hard-guard conflict.
7. **Anchor the secrets hook to argument position.** Five independent false positives this session, including blocking the writing of this spec because the text named a credential directory, and blocking two agents from writing test corpora. Two commands already document the workaround — the route-around failure is live.
8. **Add the zero-gap twin of every two-wildcard rule** (§1.2).
9. **De-duplicate `deny` vs `ask`** and add a test forbidding a pattern in both lists.
10. **Make the on-chain hook headless-aware** — it returns `ask` for every on-chain write on every cluster, an unconditional headless failure today.
11. **Honor `ANCHOR_PROVIDER_URL` and `-C/--config`** in the on-chain hook. Both currently make it resolve the wrong cluster and mislabel mainnet.
12. **Tier migration in `update.sh` below line 93**, or no existing install ever receives the firewall. `update.sh` already mutates `settings.json` in place (`retire_kit_defaults.py`), so this extends shipped behaviour.
13. **Decide the `--agents` story** — `settings.json` installs there and is inert. Skip it, or document that `--agents` is unfirewalled.
14. Scope `/audit-infra:54`, `/doctor:62`, `/build-unity:9`, `/test-dotnet:15` for High's read fence.

---

## 6. Four tests to run before shipping

| | Question | Why it gates |
|---|---|---|
| ~~T1~~ | **Settled, negative.** `strictAllowlist` is ignored in project settings; `allowedDomains` only prompts there and is inert under bypass. `deniedDomains` is honored and is the ceiling. | §4 rewritten; README hedge resolved |
| ~~T2~~ | **Settled.** A *content-scoped* ask fires in default **and** bypass mode; only a bare `Bash`/`Bash(*)` ask is voided for sandboxed commands. The axis is bare-vs-scoped, not permission mode and not `autoAllowBashIfSandboxed`. | §1.1 corrected; `validate.sh` rejects the bare form |
| ~~T3~~ | **Settled, negative.** Narrower path wins, so the wildcard deny beats the directory allow and reaches the build subprocess. `allowRead: ["./target"]` was a no-op for widening anyway. | §3.2 struck; plain `allow` is correct |
| ~~T4~~ | **Settled — three layers, and both earlier probes were right.** File tools refuse in every mode (`true` in any source wins). Bash refuses a statically resolvable outside read and **escalates to a prompt** when it cannot resolve the path, per an explicit interpreter table (`python -c`, `node -e`, `bash -c`, …). The sandbox's `denyRead` over `/Users/`, `/home/`, `/Volumes/` is the third layer, and the only one sandbox state affects. | README fence sentence names all three |

---

## 7. Open calls for the maintainer

1. **`excludedCommands` vs Surfpool.** Deleting all six closes the whole-command-line read bypass (reproduced: `git push -h >/dev/null 2>&1; <read>` → exit 0 where the bare read → EPERM). But Surfpool needs to run outside the sandbox and `excludedCommands` is the only lever. Recommendation: keep a **two-entry** list for `surfpool *` and `anchor test*`, drop the six git/gh entries — a test-runner escape is a far narrower surface than `git push -h;` prefixing anything.
2. ~~**`gh api --method PUT/POST` left open**~~ **Settled (rule set 5): narrowed at Medium and High, accepted at Off and Relaxed.** `Bash(gh api *)` is denied at the two tiers whose promise is that the agent cannot change your repository, which closes both the `gh secret set` PUT route and the `gh repo delete` DELETE route there. The whole subcommand goes rather than just the mutating methods, because a glob carries no argument form and a hook classifying the method would be one missed spelling away from a silent hole — `-X`, `--method`, the implicit POST from `-f`/`--field`/`--input`, and `gh api graphql` which is always a POST. Off and Relaxed keep it: Relaxed is the CI tier and never made that promise. This is the only `Bash` deny in the corpus that varies by tier — every other one, `Bash(git -C *)` included, is identical at all four — so it carries the hand-copy residual every tier-varying group carries.
3. **Relaxed is not CI-safe** and `.github/workflows/claude.yml` runs the action inside this repo. Document that CI runs Relaxed or Off, and that Medium/High hard-fail headless by design.
4. **Relaxed's honest guarantee** is "your secrets won't additionally reach a third party", not confidentiality — it deliberately makes project `.env` readable, and once read a value is in the transcript and has been sent to the provider. Saying more oversells it.
