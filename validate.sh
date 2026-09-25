#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit Validator
# Run from repo root to check config integrity.

PASS=0
FAIL=0

check() {
  local description="$1"
  local result="$2"
  if [ "$result" -eq 0 ]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    FAIL=$((FAIL + 1))
  fi
}

echo "Validating Solana AI Kit..."
echo ""

# --- Agent frontmatter ---
echo "[Agents]"
for f in .claude/agents/*.md; do
  name="$(basename "$f")"
  has_name=1; has_desc=1; model_ok=1

  # Check for frontmatter block
  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(awk '/^---$/{c++;next} c==1{print; if(NR>22)exit}' "$f")"
    echo "$frontmatter" | grep -q "^name:" && has_name=0
    echo "$frontmatter" | grep -q "^description:" && has_desc=0
    # model: is optional (omitted = inherit the session model); never hardcode fable
    echo "$frontmatter" | grep -q "^model:" || model_ok=0
    echo "$frontmatter" | grep -qE "^model:[[:space:]]*(opus|sonnet|haiku|inherit)[[:space:]]*$" && model_ok=0
  fi

  check "$name has name:" $has_name
  check "$name has description:" $has_desc
  check "$name model: omitted or opus|sonnet|haiku|inherit" $model_ok
done
echo ""

# --- Command frontmatter ---
echo "[Commands]"
for f in .claude/commands/*.md; do
  name="$(basename "$f")"
  has_desc=1

  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(awk '/^---$/{c++;next} c==1{print; if(NR>22)exit}' "$f")"
    echo "$frontmatter" | grep -q "^description:" && has_desc=0
  fi

  check "$name has description:" $has_desc
done
echo ""

# --- Description budget ---
# Agent and command descriptions are listed to the model in every session, so keep
# them to routing essentials. Bodies load only when used.
echo "[Descriptions]"
long_desc=0
while IFS=$'\t' read -r len limit file; do
  if [ "$len" -gt "$limit" ]; then
    echo "  FAIL: $file description is $len chars (limit $limit)"
    FAIL=$((FAIL + 1))
    long_desc=$((long_desc + 1))
  fi
done < <(python3 - <<'PY'
import glob, re
for pattern, limit in ((".claude/agents/*.md", 250), (".claude/commands/*.md", 100)):
    for path in sorted(glob.glob(pattern)):
        text = open(path, encoding="utf-8").read()
        front = text.split("\n---", 1)[0] if text.startswith("---") else ""
        m = re.search(r"^description:\s*(.*)$", front, re.M)
        desc = m.group(1).strip().strip("\"'") if m else ""
        print(f"{len(desc)}\t{limit}\t{path}")
PY
)
if [ "$long_desc" -eq 0 ]; then
  check "Agent descriptions <= 250 chars, command descriptions <= 100 chars" 0
fi
echo ""

# --- Skill references ---
echo "[Skills]"
if [ -f .claude/skills/SKILL.md ]; then
  check "SKILL.md exists" 0

  # Extract markdown links and check targets
  broken=0
  while IFS= read -r link; do
    # Remove leading/trailing whitespace
    link="$(echo "$link" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [ -z "$link" ] && continue

    target=".claude/skills/$link"
    if [ ! -e "$target" ] && [ ! -d "$target" ]; then
      echo "  FAIL: Broken link -> $link"
      FAIL=$((FAIL + 1))
      broken=$((broken + 1))
    fi
  done < <(grep -oE '\]\([^)]+\)' .claude/skills/SKILL.md | sed 's/\](//' | sed 's/)//' | grep -v '^http')

  if [ "$broken" -eq 0 ]; then
    check "All SKILL.md links resolve" 0
  fi
else
  check "SKILL.md exists" 1
fi
echo ""

# --- ext/ links in agents, commands and local skills ---
# Dependabot bumps the ext/ pins; a path an upstream pack moved must fail here, in CI,
# not in a user's session. Anchors (#...) are stripped; the hub is checked above.
echo "[ext/ links]"
broken=0
while IFS= read -r f; do
  while IFS= read -r link; do
    link="${link%%#*}"
    [ -z "$link" ] && continue
    if [ ! -e "$(dirname "$f")/$link" ]; then
      echo "  FAIL: $f -> $link"
      FAIL=$((FAIL + 1))
      broken=$((broken + 1))
    fi
  done < <(grep -oE '\]\([^)[:space:]]*ext/[^)[:space:]]*\)' "$f" | sed 's/^](//; s/)$//' | grep -v '^http' || true)
done < <(find .claude/agents .claude/commands -name '*.md'; find .claude/skills -path .claude/skills/ext -prune -o -name '*.md' ! -path .claude/skills/SKILL.md -print)
if [ "$broken" -eq 0 ]; then
  check "Every ext/ link in agents, commands and local skills resolves" 0
fi
echo ""

# --- Submodules ---
echo "[Submodules]"
for dir in .claude/skills/ext/*/; do
  name="$(basename "$dir")"
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    check "ext/$name is initialized (non-empty)" 1
  else
    check "ext/$name is initialized (non-empty)" 0
  fi
done
echo ""

# --- Versioning ---
echo "[Versioning]"
if [ -f .claude/VERSION ]; then
  if grep -qE '(^|[[:space:]])[0-9]+\.[0-9]+\.[0-9]+$' .claude/VERSION; then
    check ".claude/VERSION follows semver" 0
  else
    check ".claude/VERSION follows semver" 1
  fi
else
  check ".claude/VERSION file exists" 1
fi

if [ -f .claude/bin/update.sh ] && [ -x .claude/bin/update.sh ]; then
  check "update.sh exists and is executable" 0
else
  check "update.sh exists and is executable" 1
fi

if [ -f .claude/bin/resync.sh ] && [ -x .claude/bin/resync.sh ]; then
  check "resync.sh exists and is executable" 0
else
  check "resync.sh exists and is executable" 1
fi
echo ""

# --- .env.example ---
echo "[Environment]"
if [ -f .env.example ]; then
  check ".env.example exists" 0
else
  check ".env.example exists" 1
fi
echo ""

# --- JSON files ---
echo "[JSON]"
if [ -f .claude/settings.json ]; then
  if python3 -c "import json; json.load(open('.claude/settings.json'))" 2>/dev/null; then
    check "settings.json is valid JSON" 0
  else
    check "settings.json is valid JSON" 1
  fi
else
  check "settings.json exists" 1
fi

if [ -f .mcp.json ]; then
  if python3 -c "import json; json.load(open('.mcp.json'))" 2>/dev/null; then
    check ".mcp.json is valid JSON" 0
  else
    check ".mcp.json is valid JSON" 1
  fi
fi
echo ""

# --- Session behavior stays with the user ---
# settings.json ships the security policy and attribution. These keys pinned behavior
# for every user (effort, experimental modes, LSP plugins, MCP auto-approval) or were
# dead; update.sh strips them from older installs.
echo "[Settings]"
retired_keys="$(python3 -c 'import json
d = json.load(open(".claude/settings.json"))
env = d.get("env") or {}
plugins = d.get("enabledPlugins") or {}
keys = [k for k in ("enableAllProjectMcpServers", "defaultMode", "modelDefaults") if k in d]
keys += ["env." + k for k in ("CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_COORDINATOR_MODE",
         "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "BASH_MAX_OUTPUT_LENGTH", "MAX_MCP_OUTPUT_TOKENS") if k in env]
keys += ["enabledPlugins." + p for p in plugins if p.split("@")[0] in ("rust-analyzer-lsp", "typescript-lsp", "csharp-lsp")]
print(" ".join(keys))' 2>/dev/null || true)"
if [ -z "$retired_keys" ]; then
  check "settings.json pins no session behavior (effort, env toggles, LSP plugins, MCP auto-approval)" 0
else
  echo "  FAIL: settings.json sets $retired_keys; leave these to the user (.claude/settings.local.json)"
  FAIL=$((FAIL + 1))
fi
echo ""

# --- Rules frontmatter ---
# Claude Code reads only `paths:` from a rule. A rule without it (including one
# that uses `globs:`) loads into every session and every subagent.
echo "[Rules]"
eager_rules=0
while IFS= read -r f; do
  frontmatter=""
  if head -1 "$f" | grep -q "^---$"; then
    frontmatter="$(awk '/^---$/{c++;next} c==1{print}' "$f")"
  fi
  if ! echo "$frontmatter" | grep -q "^paths:"; then
    echo "  FAIL: $f has no paths: frontmatter, so it loads every session"
    FAIL=$((FAIL + 1))
    eager_rules=$((eager_rules + 1))
  fi
done < <(find .claude/rules -name '*.md' 2>/dev/null)
if [ "$eager_rules" -eq 0 ]; then
  check "No always-loaded rules (every rule is path-scoped with paths:)" 0
fi
echo ""

# --- Summary ---
TOTAL=$((PASS + FAIL))
echo "========================================="
echo "Results: $PASS passed, $FAIL failed (of $TOTAL checks)"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
