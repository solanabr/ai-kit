#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install_symlinked_dirs] Installing --agents where .agents/skills is a symlink: $TEMP_DIR"

# Initialize a git repo so submodule commands work
(cd "$TEMP_DIR" && git init -q)

# Simulate a user who shares one skills directory across agent CLIs:
# .agents/skills is a symlink to .claude/skills
mkdir -p "$TEMP_DIR/.claude/skills" "$TEMP_DIR/.agents"
ln -s ../.claude/skills "$TEMP_DIR/.agents/skills"

# Run install.sh in agents-only mode — must not fail on the symlink
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$TEMP_DIR"

echo ""
echo "[test_install_symlinked_dirs] Verifying installation through symlink..."

# The symlink should be preserved, not replaced
TOTAL=$((TOTAL + 1))
if [ -L "$TEMP_DIR/.agents/skills" ]; then
  echo "  PASS: .agents/skills is still a symlink"
  PASS=$((PASS + 1))
else
  echo "  FAIL: .agents/skills symlink was replaced"
  FAIL=$((FAIL + 1))
fi

# Skills should have been installed through the symlink into .claude/skills
assert_file_exists "$TEMP_DIR/.agents/skills/SKILL.md" "SKILL.md reachable via .agents/skills symlink"
assert_file_exists "$TEMP_DIR/.claude/skills/SKILL.md" "SKILL.md landed in symlink target .claude/skills"

# Non-symlinked directories still install normally
assert_dir_exists "$TEMP_DIR/.agents/agents" ".agents/agents/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/commands" ".agents/commands/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/rules" ".agents/rules/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/bin" ".agents/bin/ directory exists"

# Install completed past the copy step
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md exists at project root"
assert_file_exists "$TEMP_DIR/.agents/VERSION" "VERSION exists in .agents/"

print_summary
