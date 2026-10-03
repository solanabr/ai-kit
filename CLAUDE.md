# Solana AI Kit - Meta Configuration
<!-- This is the config-repo maintainer file (NOT shipped to user projects).
     CLAUDE-solana.md is the one that ships as CLAUDE.md to target projects. -->

This repository contains Claude Code configuration for Solana development projects. The actual Solana builder configuration lives in `CLAUDE-solana.md` and should be copied to target projects as their `CLAUDE.md`.

**Install docs**: See README.md (install + orientation), QUICK-START.md and `docs/` (the full spec; `install.sh` does not copy it into a project).

---

## This Repo's Purpose

You are maintaining the **solana-ai-kit** repository - a template/library of Claude Code configurations for Solana development. Your role is to improve, test, and maintain the agents, skills, commands, and MCP servers that other projects will use.

## Token Loading Model
<!-- WHY: Understanding when each file loads determines your token budget.
     CLAUDE.md is a user message (not system prompt) — shorter = better adherence.
     Claude Code reads only `paths:` from a rule; `globs:` is ignored, so such a rule
     loads at session start and in every subagent (the kit's former rules did: ~17K tokens). -->

| File | When loaded | Budget guidance |
|------|-------------|-----------------|
| `CLAUDE.md` | Session start and every subagent; user message (uncached) | Keep <200 lines; costs every turn |
| `CLAUDE-solana.md` | Session start and every subagent (user projects) | Keep <60 lines; only what a strong model can't infer; HTML comments stripped (free) |
| `MEMORY.md` (user projects: Claude Code auto-memory; this repo has none) | Session start | 200-line / 25KB cap; index pointers only |
| `.claude/rules/*.md` | `paths:` → when Claude reads a matching file; no `paths:` → every session and subagent | Kit ships none; `validate.sh` fails on an unscoped rule |
| Agent `description` | Every session (Agent tool list) | Routing only, ≤250 chars (`validate.sh`) |
| Command `description` | Every session (skill listing) unless `disable-model-invocation: true` | One line, ≤100 chars (`validate.sh`); user-only side-effect commands set `disable-model-invocation: true` |
| `.claude/agents/*.md` body | On agent spawn | Only what the model wouldn't know; link ext/ skills |
| `.claude/commands/*.md` body | On invocation | Terse steps with the exact non-obvious commands |
| `.claude/skills/<name>/SKILL.md` `description` (token-extensions, hackathon, idea-sprint, pitch-deck) | Every session and every subagent (skill listing); body on invocation | Routing only, ≤1024 chars (`tests/test_local_skills.sh`); detail goes in `references/` |
| `.claude/skills/SKILL.md` | When read (not auto-listed: not in a `<name>/` dir; CLAUDE.md points to it) | Routing table; HTML comments NOT stripped |
| `.claude/skills/*.md` | On-demand via links | Can be detailed; don't duplicate ext/ |
| Subdirectory `CLAUDE.md` | Lazy — when Claude reads files in that dir | Monorepo module configs |

## Communication Style

- No filler phrases ("I get it", "Awesome, here's what I'll do", "Great question")
- Direct, efficient responses — code/config first, explanations when needed
- Admit uncertainty rather than guess
- Consider token efficiency in all additions

## Common Mistakes

**DON'T**:
- Edit CLAUDE-solana.md without considering it ships to user projects (different audience than this repo)
- Add agent/skill content that duplicates what's already in external submodules
- Reference files by line number in CLAUDE.md — line numbers shift constantly
- Forget .env.example when adding/removing MCP servers
- Leave stale counts (e.g., "15 agents", "22 commands") — grep to verify before committing

**DO**:
- Run `bash validate.sh && bash tests/run_all.sh` before every commit
- Check README.md, QUICK-START.md and `docs/` after any structural change
- Test install.sh in a temp dir after modifying it
- Keep CLAUDE-solana.md under 60 lines — it loads in every user session and subagent
- Write for a strong model: add only what it wouldn't know or would get wrong, link ext/ references instead of pasting patterns, and state rules calmly (no NEVER/ALWAYS/CRITICAL; give the reason)

## Ripple Map
<!-- CRITICAL: This is the #1 cause of stale docs. When adding/removing
     any component, walk through every row before committing. -->

When X changes, also update Y:

| Changed | Also update |
|---------|-------------|
| Add/remove **agent** | `docs/agents-and-commands.md` agent table, README.md count in "What This Is", `docs/plugin.md` + `docs/repo-structure.md` tree counts, QUICK-START.md heading + tree count, tests/test_agents.sh + test_cross_references.sh counts (its per-agent check reads `docs/agents-and-commands.md`) |
| Add/remove **command** | `docs/agents-and-commands.md` commands tables, README.md count in "What This Is", `docs/plugin.md` + `docs/repo-structure.md` tree counts, QUICK-START.md heading + tree count, tests/test_commands.sh + test_cross_references.sh counts (its per-command check reads `docs/agents-and-commands.md`) |
| Change an agent/command **`model:`** | `docs/agents-and-commands.md` Agents table Model column + routing note (`tests/test_model_routing.sh` enforces allowed values, no Fable, and drift against that doc's `## Agents` section) |
| Add/remove **MCP server** | `docs/configuration.md` MCP tables, README.md count in "What This Is", CLAUDE-solana.md MCP list, QUICK-START.md MCP list, .env.example, .claude/commands/setup-mcp.md, tests/test_mcp_config.sh server list + test_cross_references.sh count |
| Add/remove **.env.example key** | `.claude/commands/setup-mcp.md` |
| Add/remove **submodule** | .gitmodules, `.claude/skills/skill-registry.json` entry (`tier` core/extension, `path`, `commit`, `triggers`, install command), `docs/skill-packs.md` submodules table (`tests/test_cross_references.sh` checks its rows and tiers against `.gitmodules` and the registry), .claude/skills/SKILL.md routing. The `docs/repo-structure.md` and QUICK-START trees list `ext/` as one line, so they don't change. For an extension, every line that links into it names `bash .claude/bin/skills.sh add <id>`, and the hub's Extensions table gets a row (`tests/test_skill_extensions.sh` enforces both). Add the pin with `bash .claude/bin/skills.sh pins --write`, never by hand |
| Move a pack between **core and extension** | `tier` + `default_installed` in the registry (they must agree), the hub's intro sentence and its Extensions table (core packs are not in it), the `docs/skill-packs.md` submodules table Tier column, the QUICK-START core list and tree, `CORE=` in `tests/test_install_packs.sh`. A pack leaving core keeps working only if every line that links into it also gains its install command |
| Change a pack's **pinned commit** | The gitlink and the registry `commit` move together, or `validate.sh` fails: `bash .claude/bin/skills.sh pins --write` after the bump. Dependabot's weekly PR gets that push from `.github/workflows/sync-skill-pins.yml`. A pack's *own* submodules are recorded in `vendored` and are deliberately not auto-synced — a third party moving a pin inside a pack we ship should fail CI until someone reads the diff. The installers do not fetch them (`--recursive` is off for pack paths), so nothing nested reaches a user project |
| Re-pin or change **anthropic-skills** (pinned by `commit` in its registry entry, not a submodule) | Review the upstream diff of each folder in its `skills` list first; never list docx, pdf, pptx, xlsx or doc-coauthoring (`DENIED_SKILLS` in `.claude/bin/skills.sh` refuses them); `docs/skill-packs.md` "Anthropic's skills in any agent"; hub rows; `tests/test_anthropic_skills.sh` re-checks licenses and frontmatter at the pin |
| Re-pin or change **safe-ai-skill** (core plugin from its own repo, not a submodule) | `.claude-plugin/marketplace.json` entry `sha` (a commit whose `plugins/safe-ai-skill/bin/` has every platform binary), `plugin.json` `dependencies`, `.claude/settings.json` `enabledPlugins` + `extraKnownMarketplaces`, README "Security firewall" section, `tests/test_plugin.sh` + `tests/test_settings_deep.sh` |
| Change a **firewall tier's rule set** (`.claude/bin/firewall.sh`) | The tier is **regenerated wholesale**, never layered — permission lists merge across settings files and a `deny` from any scope wins, so a looser tier cannot be written as a stricter one plus exceptions. **Bump `RULE_SET_VERSION`**: `update.sh` compares it against `enforced.ruleSetVersion` and re-applies the declared tier when it is behind, and that is the ONLY route by which a rule change reaches a project that already has a `security.json` (the pre-firewall migration exits early on those). Then re-apply so the repo's own `security.json` records the new version and sha — and do it from a **clean non-worktree copy**, or `git_common_write()` writes this machine's absolute `.git` path into the committed `settings.json`. Update: the `enforced.ruleIds` the tier writes into `.claude/security.json`, the tier migration in `.claude/bin/update.sh` (below line 93, or existing installs never receive it), `/doctor`'s declared-vs-enforced check, `.claude/commands/firewall.md`, the firewall assertions in `tests/` + `validate.sh`, README's "Firewall tiers" tier table, `docs/firewall.md`'s gate table and honesty paragraphs, and `docs/other-agents.md`'s cross-harness table. Never express a tier with `defaultMode` (`validate.sh`'s retired-keys check rejects it; session mode is the user's call) or `disableBypassPermissionsMode` — a real schema key, but it restricts the *user's* mode choice, not the agent's reach, so it buys High nothing |
| Modify **install.sh** | Test: `bash tests/test_install.sh` in temp dir. It also asserts that `docs/` and `QUICK-START.md` stay out of a project: the copy loop takes named `.claude/` subdirectories plus named root files, so kit-only documentation is excluded by construction |
| Move a section between **README.md and `docs/`** | The README is for getting installed and oriented; everything else lives in `docs/` behind a link. Update the `docs/README.md` index, both link tables in README.md, any QUICK-START.md pointer, and the test that reads the moved text — `tests/test_cross_references.sh` targets `docs/agents-and-commands.md` (agent + command names), `docs/skill-packs.md` (submodule rows), `docs/install.md` (the from-a-clone steps) and checks every relative link and anchor in README, QUICK-START and `docs/`; `tests/test_model_routing.sh` reads `docs/agents-and-commands.md`. Retarget an assertion, never drop it. `docs/` is also on `/cleanup`'s removal list |
| Change the **repo URL** | Update everywhere EXCEPT `.claude/bin/update.sh:16` — that line is inside the frozen 1-93 region (see the NOTE at line 94) and editing it breaks self-update for every existing install. GitHub's rename redirect covers it. |
| Bump the **pinned agent CLIs** (`opencode-ai`, `@openai/codex` in `.github/workflows/ci.yml`) | Re-check that `opencode debug skill` and `codex debug prompt-input` still emit the shape the `agents-mode-clients` job greps — both subcommands are undocumented |
| Add a **Claude-Code-only** command (describes the kit repo, `/plugin`, or anything `--agents` installs can't do) | Add it to `AGENTS_SKIP_FILES` in `install.sh` + `.claude/bin/update.sh` so it isn't installed there; `tests/test_install_agents_only.sh` asserts the two lists match |
| Modify **CLAUDE-solana.md** | This ships to ALL user projects — different audience than this repo |
| Bump **`.claude/VERSION`** | Also bump `plugin/.claude-plugin/plugin.json` `version` and `.claude-plugin/marketplace.json` `metadata.version` (both must match VERSION semver — `tests/test_plugin.sh` enforces), and the README.md version badge (`tests/test_cross_references.sh` enforces). The plugin is pinned by `plugin.json` `version` + the semver `vX.Y.Z` git tag; do NOT run `claude plugin tag` (it creates a redundant `{name}--vX.Y.Z` tag that duplicates the semver tag). |

## Submodule Pitfalls

- **Never** `git add .claude/skills/ext/<dir>` — commits as tree, not submodule. Use `git submodule add <url> .claude/skills/ext/<name>` then `git add .gitmodules .claude/skills/ext/<name>`.
- Path renames in upstream submodules ripple into all agents + commands that reference skill files. Grep for old path before committing.
- install.sh silently skips submodule init if target isn't a git repo — intentional, not a bug.

## When Editing This Repo

| Component | Location | Key Rule |
|-----------|----------|----------|
| **Agents** | `.claude/agents/` | Non-overlapping responsibilities; spawn other agents for cross-domain work; description ≤ 2 sentences |
| **Skills** | `.claude/skills/` | Progressive loading; reference from `SKILL.md`; prefer code over prose |
| **Commands** | `.claude/commands/` | Atomic (one command, one purpose); document inputs/outputs; one-line description |
| **Rules** | `.claude/rules/` | The kit ships none. A project rule needs `paths:` frontmatter (`globs:` is ignored, so the rule loads every session) |
| **MCP Servers** | `.mcp.json` | Document env vars; test connectivity; update setup-mcp command |
| **Plugin** | `.claude-plugin/marketplace.json` + `plugin/` | In-repo marketplace + symlinked core-plugin subtree (agents/commands/.mcp.json/local skills are **symlinks** into `.claude/`; only `hooks/hooks.json` + plugin-variant `skills/solana-ai-kit/SKILL.md` are real files). Keep `plugin.json` version = `.claude/VERSION`. Every plugin skill is `plugin/skills/<name>/SKILL.md`; a `SKILL.md` directly in `plugin/skills/` loads as the only skill and hides the rest. `plugin/skills/solana-ai-kit/SKILL.md` must have NO `ext/` links (submodules absent in plugin installs). Validate: `claude plugin validate .` + `./plugin`. `install.sh` stays the full install (CLAUDE.md/permissions/submodules) |

## Agent Teams

Teams are dynamic — created via natural language, not static config. They are an experimental Claude Code feature the kit leaves off; users opt in with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.local.json`. See `docs/agents-and-commands.md` for recommended team patterns.

## Branch Workflow

All changes on feature branches: `git checkout -b <type>/<scope>-<description>-<DD-MM-YYYY>`

## Pre-Merge Checklist

- [ ] `bash validate.sh && bash tests/run_all.sh` passes
- [ ] No duplicate functionality or AI slop (run `/diff-review`)
- [ ] Ripple map checked — all cross-references updated
- [ ] Manual test: `bash install.sh /tmp/test-project` → verify in Claude Code

## Testing Local Changes

- **Local install test**: `SOLANA_AI_KIT_LOCAL_SRC=. bash install.sh /tmp/test-project` — uses local repo instead of cloning from GitHub (legacy `SOLANA_CLAUDE_LOCAL_SRC` still works).
- **Agents-only mode**: `bash install.sh --agents /path` — installs to `.agents/` instead of `.claude/`. Test both modes when modifying install.sh.

## Release Management
<!-- Workflow: bump .claude/VERSION → update .claude/CHANGELOG.md → validate → tag -->

- `.claude/VERSION` contains current semver (e.g. `1.1.0`). Bump **patch** for bug fixes, **minor** for new agents/skills/commands, **major** for breaking install.sh changes.
- When bumping VERSION, also prepend a new entry to `.claude/CHANGELOG.md` with date and categorized changes (Added/Changed/Fixed/Removed).
- After bumping, run `bash validate.sh && bash tests/run_all.sh` and tag: `git tag v$(cat .claude/VERSION)`.

## Project Learnings
<!-- Append 1-2 line entries after non-obvious bugs, stale-doc incidents,
     or config changes that had unexpected side effects.
     Don't duplicate existing entries. Check before appending. -->

### Recurring Issues

### Fix Patterns

- When submodule paths change upstream: `grep -r "old/path" .claude/` → update all references → `bash validate.sh`
- When adding a component: follow Ripple Map above, then `bash validate.sh && bash tests/run_all.sh` to catch anything missed

### Config Conventions

- `.claude/VERSION` follows semver; bump on every release. `.claude/CHANGELOG.md` tracks what changed.
- `/dream` triggers memory consolidation (merges, prunes, deduplicates MEMORY.md). Run after major refactors.
- `settings.json` ships only security policy (sandbox, permissions, hooks), attribution, and the `stbr` marketplace (`extraKnownMarketplaces`) with `safe-ai-skill@stbr` enabled. Don't pin session behavior (effort, env toggles, LSP plugins, MCP auto-approval); `validate.sh` rejects the retired keys, and a key you retire needs a matching entry in update.sh's retired-defaults migration. Default MCP servers must start with no key and no extra install; the rest are opt-in in `docs/configuration.md`.
- Model routing: `model: opus` = deep reasoning, `model: sonnet` = implementation/mechanical/docs, no `model:` line = inherit the session model (strongest-model work). Commands get `model: sonnet` only when mechanical and run at session start (a mid-session switch drops the prompt cache). Never hardcode `fable`/`claude-fable-*`; `modelDefaults` is not a Claude Code setting.

---

**Main config**: `CLAUDE-solana.md` | **Docs**: `docs/` | **Agents**: `.claude/agents/` | **Skills**: `.claude/skills/` | **Commands**: `.claude/commands/` | **MCP**: `.mcp.json`
