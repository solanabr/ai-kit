# Solana AI Kit - Meta Configuration
<!-- This is the config-repo maintainer file (NOT shipped to user projects).
     CLAUDE-solana.md is the one that ships as CLAUDE.md to target projects. -->

This repository contains Claude Code configuration for Solana development projects. The actual Solana builder configuration lives in `CLAUDE-solana.md` and should be copied to target projects as their `CLAUDE.md`.

**Install docs**: See README.md and QUICK-START.md.

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
| `MEMORY.md` | Session start | 200-line / 25KB cap; index pointers only |
| `.claude/rules/*.md` | `paths:` → when Claude reads a matching file; no `paths:` → every session and subagent | Kit ships none; `validate.sh` fails on an unscoped rule |
| Agent `description` | Every session (Agent tool list) | Routing only, ≤250 chars (`validate.sh`) |
| Command `description` | Every session (skill listing) unless `disable-model-invocation: true` | One line, ≤100 chars (`validate.sh`); user-only side-effect commands set `disable-model-invocation: true` |
| `.claude/agents/*.md` body | On agent spawn | Only what the model wouldn't know; link ext/ skills |
| `.claude/commands/*.md` body | On invocation | Terse steps with the exact non-obvious commands |
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
- Check QUICK-START.md and README.md after any structural change
- Test install.sh in a temp dir after modifying it
- Keep CLAUDE-solana.md under 60 lines — it loads in every user session and subagent
- Write for a strong model: add only what it wouldn't know or would get wrong, link ext/ references instead of pasting patterns, and state rules calmly (no NEVER/ALWAYS/CRITICAL; give the reason)

## Ripple Map
<!-- CRITICAL: This is the #1 cause of stale docs. When adding/removing
     any component, walk through every row before committing. -->

When X changes, also update Y:

| Changed | Also update |
|---------|-------------|
| Add/remove **agent** | README.md agent table + tree count, QUICK-START.md tree count, install.sh output, tests/test_agents.sh + test_install.sh assertions |
| Add/remove **command** | README.md commands tables + tree count, QUICK-START.md tree count, tests/test_commands.sh + test_install.sh assertions |
| Change an agent/command **`model:`** | README.md Agents table Model column + routing note (`tests/test_model_routing.sh` enforces allowed values, no Fable, README drift) |
| Add/remove **MCP server** | README.md MCP table, CLAUDE-solana.md MCP list, QUICK-START.md MCP list, .env.example, .claude/commands/setup-mcp.md |
| Add/remove **.env.example key** | `.claude/commands/setup-mcp.md` |
| Add/remove **submodule** | .gitmodules, `.claude/skills/skill-registry.json` entry (`tier` core/extension, `path`, `triggers`, install command), README.md submodules table + tree, QUICK-START.md tree, .claude/skills/SKILL.md routing. For an extension, every line that links into it names `bash .claude/bin/skills.sh add <id>`, and the hub's Extensions table gets a row (`tests/test_skill_extensions.sh` enforces both) |
| Re-pin or change **anthropic-skills** (pinned by `commit` in its registry entry, not a submodule) | Review the upstream diff of each folder in its `skills` list first; never list docx, pdf, pptx, xlsx or doc-coauthoring (`DENIED_SKILLS` in `.claude/bin/skills.sh` refuses them); README "Anthropic's skills in any agent"; hub rows; `tests/test_anthropic_skills.sh` re-checks licenses and frontmatter at the pin |
| Re-pin or change **safe-ai-skill** (core plugin from its own repo, not a submodule) | `.claude-plugin/marketplace.json` entry `sha` (a commit whose `plugins/safe-ai-skill/bin/` has every platform binary), `plugin.json` `dependencies`, `.claude/settings.json` `enabledPlugins` + `extraKnownMarketplaces`, README "Security firewall" section, `tests/test_plugin.sh` + `tests/test_settings_deep.sh` |
| Modify **install.sh** | Test: `bash tests/test_install.sh` in temp dir |
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

Teams are dynamic — created via natural language, not static config. They are an experimental Claude Code feature the kit leaves off; users opt in with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.local.json`. See README.md for recommended team patterns.

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
- `settings.json` ships only security policy (sandbox, permissions, hooks), attribution, and the `stbr` marketplace (`extraKnownMarketplaces`) with `safe-ai-skill@stbr` enabled. Don't pin session behavior (effort, env toggles, LSP plugins, MCP auto-approval); `validate.sh` rejects the retired keys, and a key you retire needs a matching entry in update.sh's retired-defaults migration. Default MCP servers must start with no key and no extra install; the rest are opt-in in README.
- Model routing: `model: opus` = deep reasoning, `model: sonnet` = implementation/mechanical/docs, no `model:` line = inherit the session model (strongest-model work). Commands get `model: sonnet` only when mechanical and run at session start (a mid-session switch drops the prompt cache). Never hardcode `fable`/`claude-fable-*`; `modelDefaults` is not a Claude Code setting.

---

**Main config**: `CLAUDE-solana.md` | **Agents**: `.claude/agents/` | **Skills**: `.claude/skills/` | **Commands**: `.claude/commands/` | **MCP**: `.mcp.json`
