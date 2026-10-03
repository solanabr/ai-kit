# Solana AI Kit — full documentation

This directory is the kit's full spec: everything the [README](../README.md) links out to rather than carry. It lives in the kit repository only — `install.sh` copies named `.claude/` subdirectories plus a few root files, so `docs/` never lands in your project. The same files are served at `https://aikit.superteam.codes/docs/<file>`.

| Document | What it covers |
|----------|----------------|
| [install.md](install.md) | Every install route in full: installer variants, pinning a release from a clone, `--agents` for Codex and opencode, the no-install route, GitHub template, updating |
| [plugin.md](plugin.md) | The Claude Code plugin route, why it is not recommended, and how to keep the exposure small if you use it |
| [firewall.md](firewall.md) | The permission and safety gates, how a tier is generated, and — at length — what the tiers do not do |
| [agents-and-commands.md](agents-and-commands.md) | All 15 agents with the model each runs on, all 32 commands, agent teams and team patterns |
| [skill-packs.md](skill-packs.md) | The pinned `ext/` packs, core vs extension, the opt-in add-on registry, Anthropic's skills |
| [other-agents.md](other-agents.md) | Codex, Grok Build, Cursor, Copilot, Gemini CLI, opencode: what each actually enforces |
| [configuration.md](configuration.md) | MCP servers including the opt-in ones, and the settings the kit deliberately leaves to you |
| [design.md](design.md) | Why the always-on context is small, how progressive loading works, the 2026 stack |
| [repo-structure.md](repo-structure.md) | Repository layout, which parts reach a project, DX scripts, the GitHub Action, branch and review workflow |
| [../FIREWALL-SPEC.md](../FIREWALL-SPEC.md) | The verified spec the firewall tiers were built from, with the evidence behind each rule |
| [../QUICK-START.md](../QUICK-START.md) | Two-minute setup plus usage examples per task |
