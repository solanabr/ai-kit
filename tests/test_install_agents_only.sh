#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install_agents_only] Installing --agents to temp directory: $TEMP_DIR"

# Initialize a git repo so submodule commands work
(cd "$TEMP_DIR" && git init -q)

# Run install.sh in agents-only mode
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$TEMP_DIR"

echo ""
echo "[test_install_agents_only] Verifying --agents installation..."

# .agents/ directory should exist (NOT .claude/)
assert_dir_exists "$TEMP_DIR/.agents" ".agents/ directory exists"

# .claude/ should NOT exist
TOTAL=$((TOTAL + 1))
if [ ! -d "$TEMP_DIR/.claude" ]; then
  echo "  PASS: .claude/ does NOT exist (--agents mode installs to .agents/)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: .claude/ should NOT exist in --agents mode"
  FAIL=$((FAIL + 1))
fi

# All subdirectories should exist in .agents/
assert_dir_exists "$TEMP_DIR/.agents/agents" ".agents/agents/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/commands" ".agents/commands/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/skills" ".agents/skills/ directory exists"
assert_dir_not_exists "$TEMP_DIR/.agents/rules" ".agents/rules/ not installed (kit ships none)"
assert_dir_exists "$TEMP_DIR/.agents/bin" ".agents/bin/ directory exists"
assert_file_exists "$TEMP_DIR/.agents/skills/SKILL.md" "SKILL.md exists in .agents/"

# settings.json should exist in .agents/
assert_json_valid "$TEMP_DIR/.agents/settings.json" ".agents/settings.json is valid JSON"

# Count agents (should match full install)
AGENT_COUNT=$(find "$TEMP_DIR/.agents/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Agent count is 15"

# Count commands (should match full install)
CMD_COUNT=$(find "$TEMP_DIR/.agents/commands" -name "*.md" | wc -l | tr -d ' ')
assert_eq "31" "$CMD_COUNT" "Command count is 31"

# CLAUDE.md should exist at project root
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md exists at project root"

# .gitignore should have .agents/skills/ext/ entry
assert_file_exists "$TEMP_DIR/.gitignore" ".gitignore exists"
GITIGNORE_CONTENT="$(cat "$TEMP_DIR/.gitignore")"
assert_contains "$GITIGNORE_CONTENT" ".agents/skills/ext/" ".gitignore contains .agents/skills/ext/ entry"
assert_contains "$GITIGNORE_CONTENT" ".gitmodules" ".gitignore contains .gitmodules (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "solana-ai-kit config" ".gitignore has config markers for /commit-claude-config"

print_summary
