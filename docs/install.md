# Installing the kit

Every install route in full. The short path — the one-liner and the verify-before-you-run variant — is in the [README](../README.md#installer-recommended); this document covers the rest, including pinning a release, the `--agents` layout, using no files at all, and updating.

| Route | Use it when |
|-------|-------------|
| [Installer](#installer) | You work in Claude Code and want the full kit in a project |
| [From a clone](#from-a-clone) | You want to pin a release, or read every file before it reaches your project |
| [`--agents`](#codex-opencode-and-other-agents) | Your tool reads `AGENTS.md` and `.agents/skills/` instead of Claude Code's files |
| [No install](#no-install-read-the-kit-from-aikitsuperteamcodes) | You want the skills in any agent without adding files to your project |
| [Claude Code plugin](plugin.md) | Read [plugin.md](plugin.md) before you use it — it is not recommended |

Each code block below holds one command: `bash` blocks run in your terminal, `text` blocks are typed into Claude Code (or, for the no-install prompt, into your agent).

## Installer

The installer copies the kit into a project: `.claude/` (agents, commands, skills, a `settings.json` with the permissions, sandbox and hooks, and a `security.json` naming the [firewall tier](../README.md#firewall-tiers) those rules came from), `CLAUDE.md`, `.mcp.json` and `.env`. It downloads the kit's latest release tag from GitHub into a temporary directory, which it deletes when done. It installs into the current directory, so go to your project's root first (replace `your-project` with its path):

```bash
cd your-project
```

```bash
curl -fsSL https://aikit.superteam.codes | bash
```

`aikit.superteam.codes` and `aikit.superteam.codes/install.sh` both redirect to [`install.sh` on `main`](https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh).

**Verify before you run it.** Download the installer, read it, then run the copy you read:

```bash
curl -fsSL https://aikit.superteam.codes/install.sh -o /tmp/solana-ai-kit-install.sh
```

```bash
less /tmp/solana-ai-kit-install.sh
```

```bash
bash /tmp/solana-ai-kit-install.sh
```

The `docs/` directory you are reading is not part of an install: the installer copies named `.claude/` subdirectories plus a handful of root files, so the kit's own documentation, tests and scripts stay in the kit repository.

When the installer finishes, start Claude Code in the project:

```bash
claude
```

Installed config is gitignored by default — see [the README](../README.md#config-is-gitignored-by-default) for why, and for `/commit-claude-config` if you want it tracked.

### Install options

| Flag | Effect |
|------|--------|
| `--agents` | Install into `.agents/` with `AGENTS.md` instead of `.claude/` with `CLAUDE.md` — see [below](#codex-opencode-and-other-agents) |
| `--with <ids>` | Install skill extensions at install time, e.g. `--with sendai,jupiter`; `--with all` installs every pack. See [skill-packs.md](skill-packs.md) |
| `--tier <tier>` | Start on a [firewall tier](firewall.md) other than the default Relaxed. Ignored with `--agents`, which installs no firewall |

## From a clone

Use this to pin a release, or to review every file it installs, not just the installer, before it reaches your project. Clone the kit outside your project; to pin a release, add `--branch` with a tag from the [tags page](https://github.com/solanabr/ai-kit/tags), e.g. `--branch v2.1.0`:

```bash
git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/solanabr/ai-kit.git "$HOME/ai-kit"
```

Then run the clone's installer from your project's root. `SOLANA_AI_KIT_LOCAL_SRC` makes it copy from the clone instead of downloading:

```bash
SOLANA_AI_KIT_LOCAL_SRC="$HOME/ai-kit" bash "$HOME/ai-kit/install.sh"
```

## Codex, opencode and other agents

Use this when your tool reads `AGENTS.md` and `.agents/skills/` rather than Claude Code's `CLAUDE.md` and `.claude/`, as Codex and opencode do, or when `.claude/` is already taken. Run it from your project's root (replace `your-project` with its path):

```bash
cd your-project
```

```bash
curl -fsSL https://aikit.superteam.codes | bash -s -- --agents
```

`--agents` works with every installer variant above, e.g. `bash /tmp/solana-ai-kit-install.sh --agents`. It installs everything into `.agents/` instead of `.claude/`, with the instructions in `AGENTS.md` instead of `CLAUDE.md`, and the installed files point at `.agents/` paths. `.agents/agents/`, `.agents/commands/` and `.mcp.json` keep Claude Code's format, so other tools can use them as prompts or context. To update an `--agents` install, run this from your project's root:

```bash
bash .agents/bin/update.sh
```

What each harness actually enforces from those files differs sharply — Codex cannot gate file reads at all, and only Claude Code applies the permission rules and sandbox. See [other-agents.md](other-agents.md).

## No install: read the kit from aikit.superteam.codes

Use this when you want the kit's guidance in any agent (Claude Code, Codex, Grok Build, Cursor, …) without adding files to your project. [aikit.superteam.codes](https://aikit.superteam.codes) serves this repository's files, the `ext/` skill packs included, at `https://aikit.superteam.codes/<path>` (the bare domain and `/install.sh` redirect to the installer instead). Start from these:

| What | URL |
|------|-----|
| Project instructions (what the installer writes to `CLAUDE.md` or `AGENTS.md`) | https://aikit.superteam.codes/CLAUDE-solana.md |
| Skill hub: routes each Solana task to the file to read | https://aikit.superteam.codes/.claude/skills/SKILL.md |
| Solana Foundation dev skill, the hub's default entry point | https://aikit.superteam.codes/.claude/skills/ext/solana-dev/skills/solana-dev/SKILL.md |
| Security audit pack: checklists, known vectors, report format | https://aikit.superteam.codes/.claude/skills/ext/auditor-skill/SKILL.md |
| An agent or command as a reference prompt (any file in `.claude/agents/` or `.claude/commands/`) | https://aikit.superteam.codes/.claude/agents/anchor-engineer.md |

Paste this into your agent at the start of a session:

```text
Use the Solana AI Kit from https://aikit.superteam.codes for this session, without installing it.
1. Fetch https://aikit.superteam.codes/CLAUDE-solana.md and follow it as project instructions. Skip its HTML comments; they are maintainer notes.
2. Fetch files verbatim (for example with curl -fsSL), not through a tool that summarizes pages.
3. The kit names files by repository path, such as .claude/skills/SKILL.md. Fetch those from https://aikit.superteam.codes/<path>, and resolve relative links against the URL of the file that contains them.
4. Before Solana work, fetch https://aikit.superteam.codes/.claude/skills/SKILL.md and read only the files it routes the task to. The site has no folder listings: for a link that ends in /, fetch SKILL.md in that folder, or README.md if there is none.
5. Commands the kit names, such as /diff-review, are not installed: fetch .claude/commands/<name>.md from the site and follow it instead.
6. Skip install steps in these files (install.sh, skills.sh add, /add-skill): every linked file is already on the site.
```

Trade-offs:

- **Not pinned.** The site deploys this repository's `main` branch, so a file can change between two sessions. Pinned copies of the kit's own files are on GitHub at a release tag, e.g. https://raw.githubusercontent.com/solanabr/ai-kit/v2.1.0/CLAUDE-solana.md. That host doesn't serve the `ext/` packs (they are git submodules), so a pinned pack file comes from the pack's own repository, at the commit the kit pins.
- **A trust decision.** What the agent fetches becomes instructions it follows. Point it only at a host you trust, and read the files you rely on as you would a dependency.
- **Instructions only.** Nothing registers agents or commands, runs hooks (such as the mainnet-deploy gate), configures MCP servers or applies the permission and sandbox policy. The agent needs a web-fetch tool or network access for `curl` (Codex, for example, asks before it uses the internet), and every file costs a fetch.

## Using as a GitHub Template

1. Click "Use this template" on GitHub (or fork the repo).
2. Clone your new repository with its skill submodules (replace `your-name/your-project` with its GitHub path):

   ```bash
   git clone --recurse-submodules https://github.com/your-name/your-project.git
   ```

3. Start Claude Code in the clone:

   ```bash
   cd your-project
   ```

   ```bash
   claude
   ```

4. Run `/cleanup`. It copies `CLAUDE-solana.md` → `CLAUDE.md` and removes config repo scaffolding (tests, install scripts, docs):

   ```text
   /cleanup
   ```

5. Start building!

For monorepos, add a `CLAUDE.md` to each package/module with architecture decisions scoped to that directory. Claude Code automatically loads these when working in that subdirectory.

## Updating

Run these from your project's root (replace `your-project` with its path); in `--agents` installs, use `.agents/bin/` instead of `.claude/bin/`. Inside Claude Code, `/update` runs the same update.

```bash
cd your-project
```

Update the kit in place. It pulls the kit's `main` branch and keeps your `.env` and `CLAUDE.md`; when the kit's `CLAUDE.md` differs from yours, it writes the kit's version to `CLAUDE.md.upstream` for you to merge:

```bash
bash .claude/bin/update.sh
```

Preview the update without writing anything:

```bash
bash .claude/bin/update.sh --dry-run
```

List the skill packs, then install an extension by its id (`sendai` here; `/add-skill <id>` does the same inside Claude Code):

```bash
bash .claude/bin/skills.sh list
```

```bash
bash .claude/bin/skills.sh add sendai
```

Check that every link in the skill hub resolves:

```bash
bash .claude/bin/resync.sh
```

In a fork of this repository, where the `ext/` packs are git submodules, `resync.sh` also moves them to their latest upstream commits. An installed project holds plain copies of the packs, so there `update.sh` is what refreshes them.
