#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_cross_references] Ripple Map enforcer — cross-reference validation"
echo ""

# The README keeps the counts; the per-agent and per-command tables live in
# docs/agents-and-commands.md, which install.sh does not copy into a project.
AGENTS_DOC="$REPO_ROOT/docs/agents-and-commands.md"

# --- Agent count cross-references ---
echo "[agents]"
AGENT_COUNT=$(find "$REPO_ROOT/.claude/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Actual agent count is 15"
assert_file_contains "$REPO_ROOT/README.md" "15 specialized agents" "README.md references 15 specialized agents"
assert_file_contains "$REPO_ROOT/QUICK-START.md" "15 Specialized Agents" "QUICK-START.md references 15 Specialized Agents"

# --- Command count cross-references ---
echo "[commands]"
CMD_COUNT=$(find "$REPO_ROOT/.claude/commands" -name "*.md" | wc -l | tr -d ' ')
assert_eq "32" "$CMD_COUNT" "Actual command count is 32"
assert_file_contains "$REPO_ROOT/README.md" "32 workflow commands" "README.md references 32 workflow commands"
assert_file_contains "$REPO_ROOT/QUICK-START.md" "32 Slash Commands" "QUICK-START.md references 32 Slash Commands"

# --- MCP server count cross-references ---
echo "[mcp]"
MCP_COUNT=$(python3 -c "import json; print(len(json.load(open('$REPO_ROOT/.mcp.json'))['mcpServers']))" 2>/dev/null)
assert_eq "4" "$MCP_COUNT" "MCP server count in mcp.json is 4"
assert_file_contains "$REPO_ROOT/README.md" "4 MCP server" "README.md references 4 MCP servers"

# --- MCP servers appear in CLAUDE-solana.md ---
echo "[mcp-in-claude-solana]"
MCP_KEYS=$(python3 -c "import json; [print(k) for k in json.load(open('$REPO_ROOT/.mcp.json'))['mcpServers'].keys()]" 2>/dev/null)
while IFS= read -r key; do
  [ -z "$key" ] && continue
  # Map mcp.json keys to names used in CLAUDE-solana.md
  case "$key" in
    context7) SEARCH_NAME="Context7" ;;
    helius) SEARCH_NAME="Helius" ;;
    solana-dev) SEARCH_NAME="solana-dev" ;;
    playwright) SEARCH_NAME="Playwright" ;;
    context-mode) SEARCH_NAME="context-mode" ;;
    memsearch) SEARCH_NAME="memsearch" ;;
    surfpool) SEARCH_NAME="Surfpool" ;;
    *) SEARCH_NAME="$key" ;;
  esac
  assert_file_contains "$REPO_ROOT/CLAUDE-solana.md" "$SEARCH_NAME" "CLAUDE-solana.md mentions MCP server: $SEARCH_NAME"
done <<< "$MCP_KEYS"

# --- Agent names appear in the agents reference ---
echo "[agent-names]"
for agent_file in "$REPO_ROOT/.claude/agents/"*.md; do
  AGENT_NAME=$(awk '/^---$/{c++;next} c==1 && /^name:/{print $2; exit}' "$agent_file" 2>/dev/null | tr -d '"' | tr -d "'")
  [ -z "$AGENT_NAME" ] && continue
  assert_file_contains "$AGENTS_DOC" "$AGENT_NAME" "docs/agents-and-commands.md contains agent: $AGENT_NAME"
done

# --- Command names appear in the commands reference ---
echo "[command-names-doc]"
for cmd_file in "$REPO_ROOT/.claude/commands/"*.md; do
  CMD_BASENAME=$(basename "$cmd_file" .md)
  assert_file_contains "$AGENTS_DOC" "/$CMD_BASENAME" "docs/agents-and-commands.md contains command: /$CMD_BASENAME"
done

# --- Command names appear in QUICK-START.md ---
echo "[command-names]"
for cmd_file in "$REPO_ROOT/.claude/commands/"*.md; do
  CMD_BASENAME=$(basename "$cmd_file" .md)
  assert_file_contains "$REPO_ROOT/QUICK-START.md" "/$CMD_BASENAME" "QUICK-START.md contains command: /$CMD_BASENAME"
done

# --- README version badge matches .claude/VERSION ---
echo "[versioning]"
KIT_VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/.claude/VERSION" | head -1)
assert_file_contains "$REPO_ROOT/README.md" "version-$KIT_VERSION-blue" "README.md version badge matches .claude/VERSION ($KIT_VERSION)"

# --- Submodule count matches ext/ directories ---
echo "[submodules]"
if [ -f "$REPO_ROOT/.gitmodules" ]; then
  GITMODULE_COUNT=$(grep -c '\[submodule' "$REPO_ROOT/.gitmodules" | tr -d ' ')
  EXT_DIR_COUNT=$(find "$REPO_ROOT/.claude/skills/ext" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  assert_eq "$GITMODULE_COUNT" "$EXT_DIR_COUNT" "Submodule count ($GITMODULE_COUNT) matches ext/ dir count ($EXT_DIR_COUNT)"
fi

# --- Install from a clone: later steps read from the directory git clone creates ---
# Without a target dir, `git clone <url>` names the directory after the repo, so a
# repo rename silently breaks every step that reads `<dir>/...` after it: a `cp`, or
# the installer run with SOLANA_AI_KIT_LOCAL_SRC=<dir>. The docs put one command per
# fenced block, so a clone covers the rest of its section, not just its own block.
# docs/install.md now carries the from-a-clone steps the README used to hold.
echo "[install from clone]"
CLONE_INSTALL="$(python3 - "$REPO_ROOT" README.md QUICK-START.md docs/install.md <<'PY'
import os, re, shlex, sys
root = sys.argv[1]
TAKES_VALUE = {"-b", "--branch", "-o", "--origin", "-c", "--config", "-j", "--jobs", "--depth"}
reads = 0
for name in sys.argv[2:]:
    clone_dir, fenced = None, False
    for line in open(os.path.join(root, name), encoding="utf-8").read().splitlines():
        if re.match(r"\s*\x60{3}", line):
            fenced = not fenced
            continue
        if not fenced:
            if re.match(r"#+ ", line):
                clone_dir = None
            continue
        try:
            words = shlex.split(line, comments=True)
        except ValueError:
            continue
        env = {}
        while words and re.match(r"[A-Za-z_]\w*=", words[0]):
            key, _, value = words.pop(0).partition("=")
            env[key] = value
        if words[:2] == ["git", "clone"]:
            args, rest = [], iter(words[2:])
            for w in rest:
                if w in TAKES_VALUE:
                    next(rest, None)
                elif not w.startswith("-"):
                    args.append(w)
            url = args[0] if args else ""
            clone_dir = args[1] if len(args) > 1 else re.sub(r"\.git$", "", url.rstrip("/").split("/")[-1])
            continue
        if not clone_dir:
            continue
        if words[:1] == ["cp"]:
            srcs = [w for w in words[1:] if not w.startswith("-")][:-1]
        elif "SOLANA_AI_KIT_LOCAL_SRC" in env:
            srcs = [env["SOLANA_AI_KIT_LOCAL_SRC"]] + [w for w in words[1:] if w.endswith(".sh")]
        else:
            continue
        reads += 1
        for src in (re.sub(r"^\./", "", s) for s in srcs):
            inside = "" if src == clone_dir else src[len(clone_dir) + 1:] if src.startswith(clone_dir + "/") else None
            if inside is None:
                print(f"{name}: {line.strip()} reads {src}, but git clone creates {clone_dir}/")
            elif not os.path.exists(os.path.join(root, inside)):
                print(f"{name}: {line.strip()} reads {src}, which the kit repo does not have")
if not reads:
    print(", ".join(sys.argv[2:]) + ": no git clone followed by a step that reads from the clone")
PY
)"
assert_eq "" "$CLONE_INSTALL" "Installs from a clone (README, QUICK-START, docs/install.md) read from the directory git clone creates"

# --- docs/skill-packs.md submodule table matches .gitmodules and the registry tiers ---
echo "[submodule-table]"
TABLE_DRIFT="$(python3 - "$REPO_ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
gitmodules = open(os.path.join(root, ".gitmodules"), encoding="utf-8").read()
packs = set(re.findall(r"^\s*path\s*=\s*\.claude/skills/ext/(\S+)", gitmodules, re.M))
registry = json.load(open(os.path.join(root, ".claude/skills/skill-registry.json"), encoding="utf-8"))
tiers = {}
for e in registry["entries"]:
    path = e.get("path", "")
    if path.startswith(".claude/skills/ext/"):
        tiers[os.path.basename(path.rstrip("/"))] = e.get("tier", "")
DOC = "docs/skill-packs.md"
doc = open(os.path.join(root, DOC), encoding="utf-8").read()
rows = dict(re.findall(r"^\| \x60ext/([^\x60]+)\x60 \| (\w+) \|", doc, re.M))  # \x60 is a backtick
for name in sorted(packs - rows.keys()):
    print(f"{DOC} submodule table lacks ext/{name}")
for name in sorted(rows.keys() - packs):
    print(f"{DOC} submodule table lists ext/{name}, which .gitmodules does not have")
for name in sorted(packs & rows.keys()):
    if rows[name].lower() != tiers.get(name, "").lower():
        print(f"{DOC} lists ext/{name} as {rows[name]}, the registry tier is {tiers.get(name) or 'missing'}")
PY
)"
assert_eq "" "$TABLE_DRIFT" "docs/skill-packs.md submodule table rows and tiers match .gitmodules and skill-registry.json"

# --- Relative links and anchors in the root docs resolve ---
# validate.sh checks links under .claude/; the README now links out to docs/ for
# everything it sheds, so a moved section or a renamed heading has to fail here.
echo "[doc links]"
LINK_DRIFT="$(python3 - "$REPO_ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
LINK = re.compile(r"\[[^\]]*\]\((?!https?:|mailto:|#)([^)\s]+)\)")
ANCHOR = re.compile(r"^#{1,6}\s+(.*?)\s*$", re.M)

def anchors(path):
    out = set()
    for title in ANCHOR.findall(open(path, encoding="utf-8").read()):
        slug = re.sub(r"[^\w\- ]", "", title.replace("\x60", "").lower()).strip()  # \x60 is a backtick
        out.add(slug.replace(" ", "-"))
    return out

cache = {}
for src in ["README.md", "QUICK-START.md"] + sorted(glob.glob(os.path.join(root, "docs/*.md"))):
    src = src if os.path.isabs(src) else os.path.join(root, src)
    rel = os.path.relpath(src, root)
    for target in LINK.findall(open(src, encoding="utf-8").read()):
        path, _, frag = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(src), path or rel))
        if not os.path.exists(dest):
            print(f"{rel}: broken link -> {target}")
            continue
        if frag and dest.endswith(".md"):
            if dest not in cache:
                cache[dest] = anchors(dest)
            if frag not in cache[dest]:
                print(f"{rel}: anchor not found -> {target}")
PY
)"
assert_eq "" "$LINK_DRIFT" "Relative links and anchors in README, QUICK-START and docs/ resolve"

print_summary
