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

**Self-protection** — at bypass, protected-path writes are *allowed* and allow rules do not pre-approve them, so only an explicit deny stops the agent rewriting its own tier. Use `Edit(...)`, not `Read(...)`: a Read deny also blocks Edit/Write but leaves `NotebookEdit` open and would block the kit's own tooling from reading its config.

```
Edit(/.claude/settings.json), Edit(/.claude/settings.local.json),
Edit(/.claude/settings.*.json), Edit(/.claude/security.json),
Edit(/.claude/hooks/**), Edit(/.mcp.json),
Edit(~/.claude/settings.json), Edit(~/.claude/**),
Edit(//**/managed-settings.json)
```

**Policy re-roll:** `Bash(claude *)` and `Bash(claude)`. A nested `claude -p --dangerously-skip-permissions` re-rolls the whole policy in a child process, and `npm`/`npx`/`node` are allowed. Un-closable residuals to document: `--settings`, `--permission-mode`, `CLAUDE_CONFIG_DIR`, `--setting-sources` (excluding a source drops its Read denies, Edit rules *and* sandbox entries).

**Matcher-evading wrappers** — rules cannot see past these, so deny the wrappers themselves: `Bash(env *)`, `Bash(sh -c *)`, `Bash(bash -c *)`, `Bash(bash -lc *)`, `Bash(zsh -c *)`, `Bash(git -c *)`, `Bash(git -C *)`, `Bash(flock *)`, `Bash(watch *)`, `Bash(setsid *)`, `Bash(ionice *)`, `Bash(devbox run *)`, `Bash(direnv exec *)`, `Bash(mise exec *)`, `Bash(docker exec *)`. `git -c core.fsmonitor=/tmp/x.sh status` is arbitrary code execution that evades every `git <subcmd>` rule.

**Whole-binary denies** where subcommand granularity is defeated: `Bash(security *)` (`security -i` reads subcommands from stdin), `Bash(crontab*)`, `Bash(launchctl *)`, `Bash(defaults *)`, `Bash(gh alias *)` (aliases expand inside gh, invisible to the matcher).

**NOT evasions** — do not add rules for these, the matcher already handles them: leading env assignments, subshells, command substitutions, control-flow bodies, and the `timeout`/`time`/`nice`/`nohup`/`stdbuf`/`command`/`builtin`/`noglob` wrappers plus bare `xargs`. (`env` and flagged `xargs` *are* evasions — hence the list above.)

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
| force push | **`git push origin +main`**, `+refs/heads/main:...`, `git push origin -f` | glob cannot express `+refspec` → hook |
| `solana config set --keypair` | **`-k /path`** | add `*-k*` |
| `npm publish` | **`npm run release`** where the script is `npm publish` | `Bash(npm run *publish*)`, `release*`, `deploy*`, `npm exec *`, plus yarn/pnpm/bun |
| `gh repo delete` | `gh api -X DELETE /repos/O/R` | `Bash(gh api *)` deny at Medium+ |
| `gh secret set` | `gh variable set`, `gh api --method PUT .../secrets/NAME` | add `gh variable set`; reconsider leaving PUT open |

Long-option abbreviation works in **git** but not in the **solana** CLI (clap v2, no `InferLongArgs`) — verified. `git push --fo…` is ambiguous, so abbreviation cannot force-push.

### 3.6 Rules that protect nothing

- **`Read(**/Local Extension Settings/**)`** — relative `**/` is cwd-bounded; browser profiles live under `~/Library`. Shipped today and in the approved set. Needs `~/`-anchored forms.
- **Medium's "project `.env` allow + external `.env` deny" is unexpressible.** `Read(**/.env)` ≡ `Read(.env)` and cannot reach a sibling project; `Read(//**/.env)` kills the project's own and allow cannot carve out; `Read(~/**/.env)` kills it too whenever the repo is under `$HOME`. Move it to `blockReadsOutsideWorkingDirectories` + sandbox `denyRead`/`allowRead`.
- **Mainnet denies must anchor to the verb, never the cluster string** — otherwise `anchor verify --provider.cluster mainnet` and `solana program dump --url mainnet-beta`, both read-only, get blocked.
- **Two deny rules silently kill two ask rules today**: `git clean -fd *` and `git push --force *` appear in both lists; deny wins. Add a test forbidding a pattern in both.

---

## 4. Egress — the kit cannot enforce it, and must say so

**Two reviews conflict and this needs resolution (test T1).** One verified `sandbox.network.strictAllowlist` in the 2.1.267 binary and proposed it as the primary control. The other found the docs state it **has no effect** when set in `.claude/settings.json` or `.claude/settings.local.json` — the only scopes the kit writes — and that at `bypassPermissions` the allowlist is inert entirely unless `strictAllowlist` or `allowManagedDomainsOnly` is on.

If the docs are right, **High has no egress control the kit can ship.** What remains:

- **`sandbox.network.deniedDomains`** — refused in every mode. Ship a known-exfil denylist: request-bin and tunnel services, paste sites, file drops.
- **Document `strictAllowlist` as a line the user adds to `~/.claude/settings.json`**, not something the kit installs.
- **Command rules** for the three primitives that survive a destination layer anyway, because their destination is legitimately allowlisted: `npm publish`, `cargo publish`, `git push` to an arbitrary remote (`git remote add` is allowed).
- **A position-anchored hook** for data-carrying `curl`/`wget`. A working prototype exists (262-line awk, 231 assertions green across three tiers, 4.5 ms/call) with a #111 regression corpus.

**Correcting the approved decision:** do **not** ask on `curl -d` at Relaxed. `curl -X POST -d '{"jsonrpc":"2.0",...}' https://api.devnet.solana.com` is the most common curl in Solana development, and an ask there prompts constantly *and* breaks the kit's own shipped `claude.yml` Action. Relaxed gates only the `@file` and `--upload-file` forms; inline bodies become ask at Medium, deny at High.

**MCP is ungateable.** Rules are tool-name-only with no path or argument specifier, and local servers run outside the sandbox with full user access. `playwright.browser_network_request` is an arbitrary HTTP client; `context-mode.ctx_execute` runs commands entirely outside the Bash tool, so outside every rule and hook. Mitigating fact: only `helius`, `solana-dev` and `context7` ship by default. The honest line is that attaching the others removes the egress guarantee.

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
| **T1** | Does `sandbox.network.strictAllowlist` work from project settings? | Decides whether the kit can ship egress enforcement at all (§4) |
| **T2** | Does `permissions.ask` prompt in **default** (non-bypass) mode with the sandbox on? | Decides whether rule-ask works for anyone, or is dead everywhere (§1.1) |
| **T3** | Does `sandbox.filesystem.allowRead` outrank a `Read`-deny projected into `denyRead`? | Decides the High keypair design; if it loses, `anchor test` breaks (§3.2) |
| **T4** | Does `blockReadsOutsideWorkingDirectories` also block `cat` in Bash? | Two reviews disagree; the README claim depends on it |

---

## 7. Open calls for the maintainer

1. **`excludedCommands` vs Surfpool.** Deleting all six closes the whole-command-line read bypass (reproduced: `git push -h >/dev/null 2>&1; <read>` → exit 0 where the bare read → EPERM). But Surfpool needs to run outside the sandbox and `excludedCommands` is the only lever. Recommendation: keep a **two-entry** list for `surfpool *` and `anchor test*`, drop the six git/gh entries — a test-runner escape is a far narrower surface than `git push -h;` prefixing anything.
2. **`gh api --method PUT/POST` left open** means `gh secret set` is reachable by API at every tier. Narrow it or accept it.
3. **Relaxed is not CI-safe** and `.github/workflows/claude.yml` runs the action inside this repo. Document that CI runs Relaxed or Off, and that Medium/High hard-fail headless by design.
4. **Relaxed's honest guarantee** is "your secrets won't additionally reach a third party", not confidentiality — it deliberately makes project `.env` readable, and once read a value is in the transcript and has been sent to the provider. Saying more oversells it.
