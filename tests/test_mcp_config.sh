#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

MCP_FILE="$REPO_ROOT/.mcp.json"
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"

echo "[test_mcp_config] Checking MCP configuration..."

# .mcp.json must be at project root (Claude Code only reads this path)
assert_file_exists "$MCP_FILE" ".mcp.json exists at project root"
assert_json_valid "$MCP_FILE" ".mcp.json is valid JSON"

# Ensure old location doesn't exist
if [ -f "$REPO_ROOT/.claude/mcp.json" ]; then
  assert_eq "0" "1" ".claude/mcp.json should not exist (wrong path — use .mcp.json at root)"
fi

# Check for mcpServers key
MCP_CONTENT="$(cat "$MCP_FILE")"
assert_contains "$MCP_CONTENT" '"mcpServers"' ".mcp.json has mcpServers key"

# Default servers: the ones that work in any Solana project with no key and no extra install
SERVERS="$(python3 -c "import json; print(' '.join(sorted(json.load(open('$MCP_FILE'))['mcpServers'])))" 2>/dev/null)"
assert_eq "context-mode context7 helius solana-dev" "$SERVERS" ".mcp.json ships helius, solana-dev, context7 and context-mode"
# Opt-in (README "Optional MCP servers"): playwright needs browser binaries, surfpool the
# surfpool CLI, chainstack and nansen a key for most or all of their tools. phantom is
# documented but not even offered by /setup-mcp — 29 tools that sign, transfer and trade,
# with no key once logged in. memsearch-mcp is not a published npm package.
for opt in playwright surfpool chainstack phantom nansen memsearch; do
  assert_file_not_contains "$MCP_FILE" "\"$opt\"" ".mcp.json leaves $opt opt-in"
done
# Nothing a default server needs is missing on a fresh machine: npx or a remote URL
LAUNCHERS="$(python3 -c "import json; print(' '.join(sorted({s.get('command') or s.get('type') for s in json.load(open('$MCP_FILE'))['mcpServers'].values()})))" 2>/dev/null)"
assert_eq "http npx" "$LAUNCHERS" "default servers start via npx or remote HTTP only"
# solana-dev is remote: native HTTP transport, no mcp-remote bridge process
assert_contains "$MCP_CONTENT" '"url": "https://mcp.solana.com/mcp"' "solana-dev connects over native HTTP"
assert_file_not_contains "$MCP_FILE" "mcp-remote" "no mcp-remote bridge"
# An unset ${VAR} reaches the server as literal text; :- makes it empty so helius-mcp
# falls back to its stored key instead of using "${HELIUS_API_KEY}" as the key
assert_contains "$MCP_CONTENT" '"HELIUS_API_KEY": "${HELIUS_API_KEY:-}"' "helius key defaults to empty when unset"

# Every session runs these with npx -y, so they are pinned like the kit's other dependencies
assert_file_not_contains "$MCP_FILE" "@latest" "default MCP servers are not on @latest"
assert_contains "$MCP_CONTENT" '"helius-mcp@' "helius-mcp has a pinned version"
assert_contains "$MCP_CONTENT" '"@upstash/context7-mcp@' "context7-mcp has a pinned version"
assert_contains "$MCP_CONTENT" '"context-mode@' "context-mode has a pinned version"

# Project servers keep Claude Code's approval prompt (headless runs load them anyway)
assert_file_not_contains "$SETTINGS_FILE" "enableAllProjectMcpServers" "settings.json does not auto-approve project MCP servers"

# Check .env.example exists
ENV_EXAMPLE="$REPO_ROOT/.env.example"
assert_file_exists "$ENV_EXAMPLE" ".env.example exists"

print_summary
