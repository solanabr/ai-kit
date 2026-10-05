# Install as a Claude Code plugin (not recommended)

This page is about installing **the kit itself** as a plugin. For other people's plugins — which ones earn their keep in a Solana project, and what each costs per session — see [configuration.md → Claude Code plugins worth installing](configuration.md#claude-code-plugins-worth-installing).

We recommend against installing the kit, or anything else, from a plugin marketplace. A plugin runs with your user permissions: its hooks run shell commands and its stdio MCP servers run as local processes, both outside Claude Code's sandbox, and it can add executables to the PATH of Claude's shell and instructions to Claude's context. A marketplace fetches all of it from a remote repository, and with auto-update on, a plugin changes on disk after you reviewed it. Every marketplace you add is one more publisher, and one more account that can be compromised, able to ship code to your machine. The [installer](../README.md#installer-recommended) ships hooks too, but as plain files in your project that you can read and that change only when you run `/update`.

The full install uses this mechanism for one plugin, [safe-ai-skill](../README.md#security-firewall-safe-ai-skill): its `.claude/settings.json` registers this repository's `stbr` marketplace (default branch, not pinned) for the project and enables `safe-ai-skill@stbr`. Claude Code registers the marketplace only after you trust the folder, and fetches the plugin only when you run `claude plugin install safe-ai-skill@stbr --scope project`, at the commit the marketplace pins.

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

The plugin ships the **core kit**: the 15 agents, 32 commands (`/firewall` included, though a plugin install has no tier for it to set — see below), the local token-extensions and skill-packs skills, the 4 default MCP servers, and the hooks (session banner, secrets gate, approval for on-chain writes; see [Permissions and Safety Gates](firewall.md#permissions-and-safety-gates)). Installing it also installs safe-ai-skill, which it declares as a dependency. Commands and skills are namespaced — `/deploy` becomes `/solana-ai-kit:deploy`.

What the plugin **cannot** carry (Claude Code plugins are plain git clones — they can't init submodules or ship a permissions/sandbox policy), so these stay exclusive to the **full install** (`install.sh`):

- the project `CLAUDE.md` with the program-code house rules
- the curated permissions allowlist + sandbox policy — and therefore the [firewall tier](../README.md#firewall-tiers): a plugin's `settings` object honors only `agent` and `subagentStatusLine`, so its `permissions` and `sandbox` keys are dropped at load. A plugin install has hooks and no tier
- the `ext/` skill packs: the core packs by default, extensions on demand (protocol, security, infra, ecosystem depth)

The agents, commands and bundled skills are the files the full install uses, so they still link into those packs, and some name `bash .claude/bin/skills.sh add <id>`. Neither exists in a plugin install. The plugin's skill hub (the `solana-ai-kit` skill) gives the agent the next step: the solana-dev MCP, the same file from the [no-install route](install.md#no-install-read-the-kit-from-aikitsuperteamcodes), or the pack's upstream repository.

For skill-pack depth, use the full install or the [no-install route](install.md#no-install-read-the-kit-from-aikitsuperteamcodes) rather than adding each pack's own marketplace (`sendaifun/skills`, `cloudflare/skills`, …): every marketplace is one more publisher to trust.

Don't enable the plugin and the full install in the same project: both load the same commands, hooks and MCP servers, and `/doctor` warns about it.
