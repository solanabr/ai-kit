#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
PLUGIN_DIR="$REPO_ROOT/plugin"
PLUGIN_MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
PLUGIN_HUB="$PLUGIN_DIR/skills/solana-ai-kit/SKILL.md"

echo "[test_plugin] Claude Code plugin packaging (marketplace + core plugin)..."

# --- Manifests exist and are valid JSON ---
assert_file_exists "$MARKETPLACE" "marketplace.json exists at .claude-plugin/"
assert_json_valid "$MARKETPLACE" "marketplace.json is valid JSON"
assert_file_exists "$PLUGIN_MANIFEST" "plugin.json exists at plugin/.claude-plugin/"
assert_json_valid "$PLUGIN_MANIFEST" "plugin.json is valid JSON"

# Marketplace points the kit plugin at ./plugin (NOT ./ — avoids caching tests/install.sh/ext)
MARKET_CONTENT="$(cat "$MARKETPLACE")"
assert_contains "$MARKET_CONTENT" '"source": "./plugin"' "marketplace plugin source is ./plugin"
# Marketplace renamed to stbr (installs as solana-ai-kit@stbr); plugin entry keeps name solana-ai-kit
MARKET_NAME="$(python3 -c "import json; print(json.load(open('$MARKETPLACE'))['name'])" 2>/dev/null)"
assert_eq "$MARKET_NAME" "stbr" "marketplace name is stbr"
PLUGIN_ENTRY_NAME="$(python3 -c "import json; print(json.load(open('$MARKETPLACE'))['plugins'][0]['name'])" 2>/dev/null)"
assert_eq "$PLUGIN_ENTRY_NAME" "solana-ai-kit" "marketplace plugin entry name is solana-ai-kit"
# The entry mirrors plugin.json's license, homepage and keywords, and its description
# names no agent/command/MCP counts (nothing would keep them in sync)
KIT_ENTRY="$(python3 -c "
import json, re
m = json.load(open('$MARKETPLACE'))['plugins'][0]
p = json.load(open('$PLUGIN_MANIFEST'))
bad = [k for k in ('license', 'homepage', 'keywords') if m.get(k) != p.get(k)]
if re.search(r'\d+\s+(agents|commands|MCP)', m.get('description', '')):
    bad.append('description counts')
print(' '.join(bad) or 'ok')
" 2>/dev/null)"
assert_eq "ok" "$KIT_ENTRY" "marketplace solana-ai-kit entry mirrors plugin.json license/homepage/keywords and hardcodes no counts"

# safe-ai-skill is core: a second entry fetched from its own repo (git-subdir, pinned to a
# full commit SHA, not vendored) that the kit plugin declares as a dependency
SAFE_ENTRY="$(python3 -c "
import json, re
m = json.load(open('$MARKETPLACE'))
e = next((p for p in m['plugins'] if p['name'] == 'safe-ai-skill'), {})
s = e.get('source', {})
ok = (s.get('source') == 'git-subdir' and 'solanabr/safe-ai-skill' in s.get('url', '')
      and s.get('path') == 'plugins/safe-ai-skill' and re.fullmatch('[0-9a-f]{40}', s.get('sha', '')))
print('ok' if ok else 'bad')
" 2>/dev/null)"
assert_eq "$SAFE_ENTRY" "ok" "marketplace lists safe-ai-skill (git-subdir from solanabr/safe-ai-skill, SHA-pinned)"
PLUGIN_DEPS="$(python3 -c "import json; print(json.dumps(json.load(open('$PLUGIN_MANIFEST')).get('dependencies', [])))" 2>/dev/null)"
assert_contains "$PLUGIN_DEPS" '"safe-ai-skill"' "plugin.json declares safe-ai-skill as a dependency"

# --- claude plugin validate (skip-with-note if CLI unavailable in CI) ---
if command -v claude >/dev/null 2>&1; then
  assert_cmd_success "claude plugin validate '$REPO_ROOT'" "claude plugin validate (marketplace) exits 0"
  assert_cmd_success "claude plugin validate '$PLUGIN_DIR'" "claude plugin validate (plugin) exits 0"

  # The validator does not follow symlinks, so the run above (the tree the marketplace serves)
  # reads none of the linked agents, commands, skills or .mcp.json, which a session does load.
  # Validate a dereferenced copy as well. --strict (Claude Code v2.1.145+) because a missing or
  # unterminated frontmatter block is only a warning.
  DEREF_DIR="$(mktemp -d)"
  trap 'rm -rf "$DEREF_DIR"' EXIT
  DEREF_OUT="$(cp -RL "$PLUGIN_DIR" "$DEREF_DIR/plugin" 2>&1 && claude plugin validate --strict "$DEREF_DIR/plugin" 2>&1)" && RC=0 || RC=$?
  assert_eq "0" "$RC" "claude plugin validate --strict (plugin, symlinks dereferenced) exits 0"
  [ "$RC" -eq 0 ] || echo "$DEREF_OUT" | sed -e '/^[[:space:]]*$/d' -e 's/^/    /'
  # Control: with a malformed agent in the copy the same run must fail, or it isn't reading them either
  printf -- '---\nname: zz-malformed\ndescription: "unterminated\n---\n' > "$DEREF_DIR/plugin/agents/zz-malformed.md"
  claude plugin validate --strict "$DEREF_DIR/plugin" >/dev/null 2>&1 && RC=0 || RC=$?
  assert_eq "1" "$RC" "claude plugin validate --strict fails on a malformed agent in the dereferenced copy"
else
  echo "  NOTE: 'claude' CLI not on PATH — skipping 'claude plugin validate' checks"
fi

# --- Each plugin symlink target resolves on disk (-e follows symlinks) ---
echo "[plugin symlinks]"
for link in agents commands .mcp.json VERSION \
            skills/token-extensions \
            skills/skill-registry.json; do
  target="$PLUGIN_DIR/$link"
  TOTAL=$((TOTAL + 1))
  if [ -L "$target" ] && [ -e "$target" ]; then
    echo "  PASS: plugin symlink resolves: $link -> $(readlink "$target")"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: plugin symlink missing or dangling: $link"
    FAIL=$((FAIL + 1))
  fi
done

# --- Skills layout: every plugin skill is skills/<name>/SKILL.md (issue #83) ---
# A SKILL.md directly in skills/ makes Claude Code load that directory as one skill and stop
# there, so the skills in its subdirectories never register. The hub needs its own directory.
echo "[plugin skills layout]"
assert_file_not_exists "$PLUGIN_DIR/skills/SKILL.md" "no SKILL.md directly in plugin/skills/ (it would hide the bundled skills)"
for skill in solana-ai-kit token-extensions; do
  assert_file_exists "$PLUGIN_DIR/skills/$skill/SKILL.md" "plugin skill is discoverable: skills/$skill/SKILL.md"
done
HUB_NAME="$(sed -n 's/^name:[[:space:]]*//p' "$PLUGIN_HUB" 2>/dev/null | head -1 || true)"
assert_eq "solana-ai-kit" "$HUB_NAME" "plugin hub frontmatter name matches its directory"
# The hub's links are relative to its own directory, so each one must resolve from there
HUB_LINKS=0
while IFS= read -r link; do
  HUB_LINKS=$((HUB_LINKS + 1))
  TOTAL=$((TOTAL + 1))
  if [ -e "$(dirname "$PLUGIN_HUB")/$link" ]; then
    echo "  PASS: plugin hub link resolves: $link"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: plugin hub link does not resolve from skills/solana-ai-kit/: $link"
    FAIL=$((FAIL + 1))
  fi
done < <(grep -oE '\]\([^)]+\)' "$PLUGIN_HUB" 2>/dev/null | sed 's/^](//; s/)$//; s/#.*$//' | grep -vE '^(https?:|$)' | sort -u)
assert_cmd_success "[ $HUB_LINKS -gt 0 ]" "plugin hub has relative links to check"

# --- Plugin hooks (real file, mirrors .claude/settings.json hooks) ---
echo "[plugin hooks]"
PLUGIN_HOOKS="$PLUGIN_DIR/hooks/hooks.json"
assert_file_exists "$PLUGIN_HOOKS" "plugin hooks.json exists"
assert_json_valid "$PLUGIN_HOOKS" "plugin hooks.json is valid JSON"
# The guards are scripts now, symlinked into the plugin tree the same way agents, commands
# and skills are. A plugin install has no .claude/, so hooks.json must reach them through
# ${CLAUDE_PLUGIN_ROOT} -- a .claude/hooks path here would silently load nothing.
assert_file_contains "$PLUGIN_HOOKS" 'CLAUDE_PLUGIN_ROOT' "plugin hooks reach their scripts through CLAUDE_PLUGIN_ROOT"
assert_file_not_contains "$PLUGIN_HOOKS" '.claude/hooks/' "plugin hooks reference no .claude/ path (absent in a plugin install)"
for guard in lib-headless.sh secrets-guard.sh onchain-guard.sh egress-guard.sh egress-guard.awk; do
  assert_cmd_success "[ -e '$PLUGIN_DIR/hooks/$guard' ]" "plugin hooks/$guard resolves (symlink into .claude/hooks)"
done
assert_file_contains "$PLUGIN_DIR/hooks/secrets-guard.sh" "exit 2" "plugin secrets gate blocks with exit 2"
for legacy in '"when"' command_matches CLAUDE_FILE_PATH CLAUDE_TOOL_EXIT_CODE CLAUDE_SUBAGENT_NAME; do
  assert_file_not_contains "$PLUGIN_HOOKS" "$legacy" "plugin hooks.json has no unsupported '$legacy'"
done
# Plugin installs get no permissions or sandbox policy, so the hooks carry the gates and must
# match .claude/settings.json. SessionStart is the one variant: it stays quiet when a full
# install is present, so the banner doesn't print twice.
MIRROR="$(python3 -c "
import json
s = json.load(open('$REPO_ROOT/.claude/settings.json'))['hooks']
p = json.load(open('$PLUGIN_HOOKS'))['hooks']
import re
# The plugin reaches its scripts through CLAUDE_PLUGIN_ROOT and the full install through
# CLAUDE_PROJECT_DIR/.claude. Normalize that one difference, then demand equality: any
# other divergence means a guard shipped to one install path and not the other.
norm = lambda c: re.sub(r'\\$\\{CLAUDE_(?:PLUGIN_ROOT\\}|PROJECT_DIR[^}]*\\}/\\.claude)/hooks/',
                        'HOOKS/', c)
def shape(hooks):
    return [[norm(h.get('command', '')) for h in e.get('hooks', [])]
            for k, evs in sorted(hooks.items()) if k != 'SessionStart' for e in evs]
print('same' if shape(s) == shape(p) and 'SessionStart' in p else 'differ')
" 2>/dev/null)"
assert_eq "same" "$MIRROR" "plugin hooks.json matches settings.json hooks apart from SessionStart"
assert_file_contains "$PLUGIN_HOOKS" '.claude/VERSION' "plugin SessionStart skips projects that have the full install"

# --- plugin.json must not redeclare the auto-discovered default hooks path (issue #50: duplicate load error) ---
# Claude Code auto-loads hooks/hooks.json from the plugin root; a manifest "hooks" entry
# pointing at that same default path registers it twice and plugin installs fail with
# "1 error during load". The manifest field is only for additional/custom-path hook files.
MANIFEST_HOOKS_FIELD="$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST')).get('hooks', ''))" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [ "$MANIFEST_HOOKS_FIELD" != "./hooks/hooks.json" ]; then
  echo "  PASS: plugin.json does not redeclare the default ./hooks/hooks.json path"
  PASS=$((PASS + 1))
else
  echo "  FAIL: plugin.json 'hooks' field redeclares the auto-discovered ./hooks/hooks.json path (duplicate load error)"
  FAIL=$((FAIL + 1))
fi

# --- Plugin-variant hub must not link into ext/ (submodules absent in plugin installs) ---
echo "[variant hub]"
assert_file_exists "$PLUGIN_HUB" "plugin-variant skills hub exists"
assert_file_not_contains "$PLUGIN_HUB" "ext/" "plugin-variant hub contains no 'ext/' links"

# --- plugin.json version matches .claude/VERSION semver ---
echo "[version coherence]"
KIT_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/.claude/VERSION" | head -1)"
PLUGIN_VERSION="$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST'))['version'])" 2>/dev/null)"
assert_eq "$KIT_VERSION" "$PLUGIN_VERSION" "plugin.json version ($PLUGIN_VERSION) matches .claude/VERSION ($KIT_VERSION)"
MARKETPLACE_VERSION="$(python3 -c "import json; print(json.load(open('$MARKETPLACE'))['metadata']['version'])" 2>/dev/null)"
assert_eq "$KIT_VERSION" "$MARKETPLACE_VERSION" "marketplace.json metadata.version ($MARKETPLACE_VERSION) matches .claude/VERSION ($KIT_VERSION)"

# --- Links into ext/ have a documented next step in plugin installs (issue #84) ---
# plugin/agents, plugin/commands and the bundled skills are the full install's files, so they
# link into .claude/skills/ext/ and name `bash .claude/bin/skills.sh add <id>`. A plugin
# install has neither. The hub carries the next step: its description (listed in every
# session and subagent) says when to read it, and its missing-link section names each
# fallback. Every pack those files point at needs the registry `source` that section uses.
echo "[ext fallback]"
assert_dir_not_exists "$PLUGIN_DIR/skills/ext" "plugin carries no ext/ packs"
HUB_FALLBACK="$(python3 - "$PLUGIN_HUB" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
out = []
front = text.split("---", 2)[1] if text.startswith("---") else ""
desc = re.search(r"^description:\s*(.*)$", front, re.M)
desc = desc.group(1) if desc else ""
if not (re.search(r"\bext\b", desc) and "missing" in desc):
    out.append("description does not say to use the hub for a missing ext link")
section = re.search(r"^## [^\n]*\bext\b[^\n]*\bmissing\b[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if not section:
    out.append("no ext missing-link section (a ## heading naming ext and missing)")
else:
    # \x60 is a backtick; a literal one breaks how older bash parses this heredoc
    for needle in ("solana-dev MCP", "https://aikit.superteam.codes/.claude/skills/ext",
                   "skill-registry.json", "\x60source\x60", "skills.sh", "full install"):
        if needle not in section.group(1):
            out.append(f"missing-link section does not name {needle}")
print("\n".join(out) or "OK")
PY
)"
assert_eq "OK" "$HUB_FALLBACK" "plugin hub gives the next step for a missing ext/ link (description, solana-dev MCP, kit site, registry source, skills.sh, full install)"
assert_file_contains "$REPO_ROOT/docs/install.md" "https://aikit.superteam.codes/.claude/skills/ext/" "docs/install.md's no-install route serves the ext/ paths the hub falls back to"
EXT_REFS="$(python3 - "$PLUGIN_DIR" <<'PY'
import glob, json, os, re, sys
plugin = sys.argv[1]
reg = json.load(open(os.path.join(plugin, "skills", "skill-registry.json"), encoding="utf-8"))
source = {e["id"]: e.get("source") or "" for e in reg["entries"] if "tier" in e}
counts, bad = [], []
for group, pattern in (("agents", "agents/*.md"), ("commands", "commands/*.md"), ("skills", "skills/*/**/*.md")):
    links = 0
    for f in sorted(glob.glob(os.path.join(plugin, pattern), recursive=True)):
        for n, line in enumerate(open(f, encoding="utf-8"), 1):
            packs = []
            for link in re.findall(r"\]\(([^)\s]+)\)", line):
                if not link.startswith("http"):
                    packs += re.findall(r"(?:^|/)ext/([a-z0-9-]+)", link)
            links += len(packs)
            for ids in re.findall(r"skills\.sh add ((?:[a-z0-9-]+ ?)+)\x60", line):
                packs += ids.split()
            for pack in sorted(set(packs)):
                if not source.get(pack, "").startswith("https://"):
                    bad.append(f"{os.path.relpath(f, plugin)}:{n} points at ext pack {pack}, which has no registry entry with a source")
    counts.append(f"{group} {links}")
print(", ".join(counts))
print("\n".join(bad) or "OK")
PY
)"
assert_eq "OK" "$(printf '%s\n' "$EXT_REFS" | tail -n +2)" "every ext/ link and skills.sh hint in plugin agents, commands and skills names a pack with a registry source (links: $(printf '%s\n' "$EXT_REFS" | head -1))"

print_summary
