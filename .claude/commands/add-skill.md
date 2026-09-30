---
description: "Install a pinned skill extension on demand (/add-skill <id>), or list core packs and extensions"
disable-model-invocation: true
---

Install the skill extensions named in $ARGUMENTS, or list them when no id is given.

1. Resolve the kit's `bin/`: `BIN=$( [ -d .claude/bin ] && echo .claude/bin || echo .agents/bin )`. If `$BIN/skills.sh` is missing, this is a plugin install or a kit older than the core/extension split: say that extensions come with the full install (`install.sh`, then `/update`) and stop.
2. No id: run `bash "$BIN/skills.sh" list` and point out the extensions whose INSTALL WHEN column fits the user's work.
3. With ids: run `bash "$BIN/skills.sh" add <id>...`. It copies each pack at the commit the kit pins, skips packs already installed, and records them in `skills/extensions.txt`, so `/update` keeps them.
4. Open the pack's rows in `skills/SKILL.md` and continue the task from there.
