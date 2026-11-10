# Install as a Claude Code plugin (not recommended)

This page is about installing **the kit itself** as a plugin. For other people's plugins — which ones earn their keep in a Solana project, and what each costs per session — see [configuration.md → Claude Code plugins worth installing](configuration.md#claude-code-plugins-worth-installing).

We recommend against installing the kit, or anything else, from a plugin marketplace. A plugin runs with your user permissions: its hooks run shell commands and its stdio MCP servers run as local processes, both outside Claude Code's sandbox, and it can add executables to the PATH of Claude's shell and instructions to Claude's context. A marketplace fetches all of it from a remote repository, and with auto-update on, a plugin changes on disk after you reviewed it. Every marketplace you add is one more publisher, and one more account that can be compromised, able to ship code to your machine. The [installer](../README.md#installer-recommended) ships hooks too, but as plain files in your project that you can read and that change only when you run `/update`.

The full install uses this mechanism for one plugin, [safe-ai-skill](../README.md#security-firewall-safe-ai-skill): its `.claude/settings.json` registers this repository's `stbr` marketplace (default branch, not pinned) for the project and enables `safe-ai-skill@stbr`. Claude Code registers the marketplace only after you trust the folder, and fetches the plugin only when someone runs `claude plugin install safe-ai-skill@stbr --scope project`, at the commit the marketplace pins. `install.sh` runs that install itself, registering the marketplace first when needed, so only a later clone of the project needs it run by hand.

If you use the plugin anyway, keep the exposure small:

1. Add the marketplace pinned to a release tag instead of the default branch. Replace `v2.1.0` with the newest tag on the [tags page](https://github.com/solanabr/ai-kit/tags):

   ```text
   /plugin marketplace add solanabr/ai-kit#v2.1.0
   ```

2. Read what it runs, at that tag: the hooks in [`plugin/hooks/hooks.json`](../plugin/hooks/hooks.json) and the MCP servers in [`.mcp.json`](../.mcp.json).
3. Install it for one project and only for you (local scope, recorded in that project's `.claude/settings.local.json`). Run it from the project's root (replace `your-project` with its path):

   ```bash
   cd your-project
   ```

   ```bash
   claude plugin install solana-ai-kit@stbr --scope local
   ```

4. List the hooks, MCP servers, agents and commands that were installed:

   ```bash
   claude plugin details solana-ai-kit
   ```

5. Keep auto-update off. It is off by default for third-party marketplaces such as `stbr`, and `/plugin` → **Marketplaces** → `stbr` shows the toggle. Update on purpose, after reading what changed upstream:

   ```bash
   claude plugin marketplace update stbr
   ```

   ```bash
   claude plugin update solana-ai-kit@stbr --scope local
   ```

The plugin ships the **core kit**: the 15 agents, 54 commands (`/firewall` included, though a plugin install has no tier for it to set, and the agent-workflow commands, which run without their decision record — see below), the local token-extensions skill and the flat reference files in `.claude/skills/` that the agents and commands link to (`deployment.md`, `backend-async.md`), the 4 default MCP servers, and the hooks: the session banner, the four firewall guards (secrets, approval for on-chain writes, egress, fetch-and-run; see [Permissions and Safety Gates](firewall.md#permissions-and-safety-gates)), and the four decision hooks, which are the two that hand agents your decisions in force, the report check and the record's write guard ([which installs get what](decisions.md#which-installs-get-what)). Installing it also installs safe-ai-skill, which it declares as a dependency. Commands and skills are namespaced — `/deploy` becomes `/solana-ai-kit:deploy`.

What the plugin **cannot** carry (Claude Code plugins are plain git clones — they can't init submodules or ship a permissions/sandbox policy), so these stay exclusive to the **full install** (`install.sh`):

- the project `CLAUDE.md` with the program-code house rules, and the line that has Claude run a `/name(...)` call written into a plain message; here, start the message with a command instead ([how the agent workflow chains](agents-and-commands.md#how-the-agent-workflow-chains))
- that file's subagent line, which asks the kit's agents to end each report with five labelled lines. The plugin's [report check](decisions.md#the-report-check) holds an agent to them only where your own instruction files carry the line, so here it steps aside, even for an agent that a `/implement`, `/parallel` or `/research` brief asked for them. To have it run, copy the line naming the five labels from [`CLAUDE-solana.md`](../CLAUDE-solana.md) into your `CLAUDE.md`
- the curated permissions allowlist + sandbox policy — and therefore the [firewall tier](../README.md#firewall-tiers): a plugin's `settings` object honors only `agent` and `subagentStatusLine`, so its `permissions` and `sandbox` keys are dropped at load. A plugin install has hooks and no tier
- the `ext/` skill packs: the core packs by default, extensions on demand (protocol, security, infra, ecosystem depth)
- the `skill-packs` skill, left out on purpose: its install routes are `bash .claude/bin/skills.sh add <id>` and `/add-skill`, its key check is `bash .claude/bin/env-keys.sh`, and the packs it offers are the `ext/` submodules — none of which a plugin install has. Pack discovery here is the hub's `skill-registry.json` route plus Option A below

The agents, commands and bundled skills are the files the full install uses, so they still link into those packs, and some name `bash .claude/bin/skills.sh add <id>`. Neither exists in a plugin install. The plugin's skill hub (the `solana-ai-kit` skill) gives the agent the next step: the solana-dev MCP, the same file from the [no-install route](install.md#no-install-read-the-kit-from-aikitsuperteamcodes), or the pack's upstream repository.

The agent-workflow commands ([how they chain](agents-and-commands.md#how-the-agent-workflow-chains)) record decisions through `bash .claude/bin/decisions.sh` ([the decision record](decisions.md)), and `/decide` and `/report` render their pages with `.claude/bin/report-page.sh`. With no `.claude/bin/` here, each one says so and works from the conversation, so nothing they decide is recorded for later sessions or for other worktrees. They also write plans, review sheets and handoffs to `.claude/context/` and worktrees to `.claude/worktrees/`, which the full install gitignores and a plugin install cannot. Add both to your `.gitignore` before you run them: a handoff can carry private decisions, and `git add -A` stages a worktree as an embedded gitlink.

For skill-pack depth, use the full install or the [no-install route](install.md#no-install-read-the-kit-from-aikitsuperteamcodes) rather than adding each pack's own marketplace (`sendaifun/skills`, `cloudflare/skills`, …): every marketplace is one more publisher to trust.

Don't enable the plugin and the full install in the same project: both load the same commands, hooks and MCP servers, and `/doctor` warns about it.
