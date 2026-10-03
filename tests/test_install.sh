#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install] Installing to temp directory: $TEMP_DIR"

# Initialize a git repo so submodule commands work
(cd "$TEMP_DIR" && git init -q)

# Run install.sh targeting temp dir (use local source for testing)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR"

echo ""
echo "[test_install] Verifying installation..."

assert_dir_exists "$TEMP_DIR/.claude" ".claude/ directory exists"
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md exists"
assert_eq "### Recurring Issues|### Fix Patterns|### Config Conventions" \
  "$(sed -n '/^## Project Learnings/,/^## [^#]/p' "$TEMP_DIR/CLAUDE.md" 2>/dev/null | grep '^### ' | paste -sd'|' - || true)" \
  "CLAUDE.md has the Project Learnings subsections /dream and /diff-review write to"
# docs/ is the kit's own long-form spec. The copy loop takes named .claude/
# subdirectories plus named root files, so a project must not receive it.
assert_dir_not_exists "$TEMP_DIR/docs" "docs/ is not copied into a project"
assert_file_not_exists "$TEMP_DIR/QUICK-START.md" "QUICK-START.md is not copied into a project"
assert_dir_exists "$TEMP_DIR/.claude/agents" ".claude/agents/ directory exists"
assert_dir_exists "$TEMP_DIR/.claude/commands" ".claude/commands/ directory exists"
assert_file_exists "$TEMP_DIR/.claude/skills/SKILL.md" "SKILL.md exists"
assert_json_valid "$TEMP_DIR/.claude/settings.json" "settings.json is valid JSON"

# Count agents
AGENT_COUNT=$(find "$TEMP_DIR/.claude/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Agent count is 15"

# Count commands
CMD_COUNT=$(find "$TEMP_DIR/.claude/commands" -name "*.md" | wc -l | tr -d ' ')
assert_eq "32" "$CMD_COUNT" "Command count is 32"

# The firewall ships its tier record and its generator; without both, a fresh install has
# a policy nothing can describe or lower.
assert_json_valid "$TEMP_DIR/.claude/security.json" ".claude/security.json is valid JSON"
assert_file_exists "$TEMP_DIR/.claude/bin/firewall.sh" ".claude/bin/firewall.sh is installed"
assert_cmd_success "[ -x '$TEMP_DIR/.claude/bin/firewall.sh' ]" ".claude/bin/firewall.sh is executable"
assert_file_exists "$TEMP_DIR/.claude/commands/firewall.md" "/firewall is installed"
assert_eq "relaxed" "$(python3 -c "
import json; print(json.load(open('$TEMP_DIR/.claude/security.json')).get('tier', '__MISSING__'))" 2>/dev/null)" \
  "a fresh install lands on the relaxed tier"

# Check .gitignore was updated
assert_file_exists "$TEMP_DIR/.gitignore" ".gitignore exists"
GITIGNORE_CONTENT="$(cat "$TEMP_DIR/.gitignore")"
assert_contains "$GITIGNORE_CONTENT" ".claude/skills/ext/" ".gitignore contains ext/ entry"
assert_contains "$GITIGNORE_CONTENT" "CLAUDE.local.md" ".gitignore contains CLAUDE.local.md entry"
assert_contains "$GITIGNORE_CONTENT" ".gitmodules" ".gitignore contains .gitmodules (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "CLAUDE.md" ".gitignore contains CLAUDE.md (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" ".mcp.json" ".gitignore contains .mcp.json (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "solana-ai-kit config" ".gitignore has config markers for /commit-claude-config"

# Check .claude/VERSION exists
assert_file_exists "$TEMP_DIR/.claude/VERSION" ".claude/VERSION file exists"

# Check .claude/bin scripts exist
assert_file_exists "$TEMP_DIR/.claude/bin/update.sh" ".claude/bin/update.sh exists"
assert_file_exists "$TEMP_DIR/.claude/bin/resync.sh" ".claude/bin/resync.sh exists"
assert_file_exists "$TEMP_DIR/.claude/bin/skills.sh" ".claude/bin/skills.sh exists for /add-skill"
assert_file_exists "$TEMP_DIR/.claude/commands/add-skill.md" "/add-skill is installed"

print_summary
