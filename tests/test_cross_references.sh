#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_cross_references] Ripple Map enforcer — cross-reference validation"
echo ""

# --- Agent count cross-references ---
echo "[agents]"
AGENT_COUNT=$(find "$REPO_ROOT/.claude/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Actual agent count is 15"
assert_file_contains "$REPO_ROOT/README.md" "15 specialized agents" "README.md references 15 specialized agents"
assert_file_contains "$REPO_ROOT/QUICK-START.md" "15 Specialized Agents" "QUICK-START.md references 15 Specialized Agents"

# --- Command count cross-references ---
echo "[commands]"
CMD_COUNT=$(find "$REPO_ROOT/.claude/commands" -name "*.md" | wc -l | tr -d ' ')
assert_eq "31" "$CMD_COUNT" "Actual command count is 31"
assert_file_contains "$REPO_ROOT/README.md" "31 workflow commands" "README.md references 31 workflow commands"
assert_file_contains "$REPO_ROOT/QUICK-START.md" "31 Slash Commands" "QUICK-START.md references 31 Slash Commands"

# --- MCP server count cross-references ---
echo "[mcp]"
MCP_COUNT=$(python3 -c "import json; print(len(json.load(open('$REPO_ROOT/.mcp.json'))['mcpServers']))" 2>/dev/null)
assert_eq "3" "$MCP_COUNT" "MCP server count in mcp.json is 3"
assert_file_contains "$REPO_ROOT/README.md" "3 MCP server" "README.md references 3 MCP servers"

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

# --- Agent names appear in README.md ---
echo "[agent-names]"
for agent_file in "$REPO_ROOT/.claude/agents/"*.md; do
  AGENT_NAME=$(awk '/^---$/{c++;next} c==1 && /^name:/{print $2; exit}' "$agent_file" 2>/dev/null | tr -d '"' | tr -d "'")
  [ -z "$AGENT_NAME" ] && continue
  assert_file_contains "$REPO_ROOT/README.md" "$AGENT_NAME" "README.md contains agent: $AGENT_NAME"
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

print_summary
