#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install_idempotent] Testing double-install safety"
echo ""

# Initialize git repo
(cd "$TEMP_DIR" && git init -q)

# --- First install ---
echo "[first install]"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" >/dev/null 2>&1

assert_dir_exists "$TEMP_DIR/.claude" ".claude/ exists after 1st install"
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md exists after 1st install"
assert_file_not_exists "$TEMP_DIR/CLAUDE.md.bak" "No CLAUDE.md.bak after 1st install"

# Write custom user files to verify they survive reinstall
echo '{"user_custom": true}' > "$TEMP_DIR/.claude/settings.json"
echo '{"mcpServers": {"my-server": {}}}' > "$TEMP_DIR/.mcp.json"

# Customize CLAUDE.md to verify it gets backed up
echo "# my custom rule" >> "$TEMP_DIR/CLAUDE.md"

# --- Second install ---
echo "[second install]"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" >/dev/null 2>&1

# Verify NO nesting (.claude/.claude should not exist)
assert_dir_not_exists "$TEMP_DIR/.claude/.claude" "No .claude/.claude nesting on 2nd install"

assert_file_contains "$TEMP_DIR/CLAUDE.md.bak" "my custom rule" "Customized CLAUDE.md backed up to CLAUDE.md.bak on 2nd install"
assert_dir_exists "$TEMP_DIR/.claude" ".claude/ still valid after 2nd install"
assert_dir_exists "$TEMP_DIR/.claude/agents" "agents/ preserved after 2nd install"
assert_dir_exists "$TEMP_DIR/.claude/commands" "commands/ preserved after 2nd install"
assert_count "$TEMP_DIR/.claude/agents" "*.md" "15" "Agent count correct after 2nd install"
assert_count "$TEMP_DIR/.claude/commands" "*.md" "31" "Command count correct after 2nd install"

# Verify specific files have content (not empty from bad copy)
assert_file_exists "$TEMP_DIR/.claude/agents/anchor-engineer.md" "Specific agent exists after 2nd install"
assert_file_exists "$TEMP_DIR/.claude/skills/SKILL.md" "Skills hub exists after 2nd install"

# Verify user files were NOT overwritten (protected on reinstall)
assert_file_contains "$TEMP_DIR/.claude/settings.json" "user_custom" "User settings.json preserved on 2nd install"
assert_file_contains "$TEMP_DIR/.mcp.json" "my-server" "User .mcp.json preserved on 2nd install"

# .gitignore should not have duplicate entries
EXT_DUPES=$(grep -c "skills/ext/" "$TEMP_DIR/.gitignore" | tr -d ' ')
assert_eq "1" "$EXT_DUPES" "No duplicate ext/ entries in .gitignore"

LOCAL_DUPES=$(grep -c "CLAUDE.local.md" "$TEMP_DIR/.gitignore" | tr -d ' ')
assert_eq "1" "$LOCAL_DUPES" "No duplicate CLAUDE.local.md entries in .gitignore"

# --- Third install: CLAUDE.md now matches the kit's, so the backup of the user's copy must survive ---
echo "[third install]"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" >/dev/null 2>&1
assert_file_contains "$TEMP_DIR/CLAUDE.md.bak" "my custom rule" "CLAUDE.md.bak still holds the user's copy after a 3rd install"

print_summary
