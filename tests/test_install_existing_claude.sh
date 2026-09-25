#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install_existing_claude] Testing install into directory with existing .claude/"
echo ""

# Initialize git repo
(cd "$TEMP_DIR" && git init -q)

# Setup: create target with existing .claude/ and user content
mkdir -p "$TEMP_DIR/.claude/memory"
echo '{"custom": true}' > "$TEMP_DIR/.claude/settings.json"
echo '{"mcpServers": {"my-server": {}}}' > "$TEMP_DIR/.mcp.json"
echo "# User memories" > "$TEMP_DIR/.claude/MEMORY.md"
echo "mem1" > "$TEMP_DIR/.claude/memory/user_prefs.md"

# Install over existing .claude/
echo "[install over existing .claude/]"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" >/dev/null 2>&1

# Assert: no nesting
assert_dir_not_exists "$TEMP_DIR/.claude/.claude" "No .claude/.claude nesting"

# Assert: upstream content installed
assert_dir_exists "$TEMP_DIR/.claude/agents" "agents/ installed"
assert_count "$TEMP_DIR/.claude/agents" "*.md" "15" "Agent count correct"
assert_dir_exists "$TEMP_DIR/.claude/commands" "commands/ installed"
assert_count "$TEMP_DIR/.claude/commands" "*.md" "31" "Command count correct"
assert_dir_not_exists "$TEMP_DIR/.claude/rules" "no rules/ installed (kit ships none)"
assert_dir_exists "$TEMP_DIR/.claude/skills" "skills/ installed"

# Assert: user files preserved
assert_file_contains "$TEMP_DIR/.claude/settings.json" '"custom"' "User settings.json preserved"
assert_file_contains "$TEMP_DIR/.mcp.json" '"my-server"' "User .mcp.json preserved at root"
assert_file_contains "$TEMP_DIR/.claude/MEMORY.md" "User memories" "User MEMORY.md preserved"
assert_file_exists "$TEMP_DIR/.claude/memory/user_prefs.md" "User memory/ dir preserved"

# Assert: VERSION file installed
assert_file_exists "$TEMP_DIR/.claude/VERSION" "VERSION file installed"

print_summary
