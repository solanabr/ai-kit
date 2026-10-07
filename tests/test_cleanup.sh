#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_cleanup] Simulating /cleanup command contract"
echo ""

# --- Setup: Install + copy scaffolding files to simulate a forked template ---
(cd "$TEMP_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"

# Copy scaffolding files that would exist in a fork
cp "$REPO_ROOT/install.sh" "$TEMP_DIR/install.sh"
cp "$REPO_ROOT/validate.sh" "$TEMP_DIR/validate.sh"
cp "$REPO_ROOT/README.md" "$TEMP_DIR/README.md"
cp "$REPO_ROOT/QUICK-START.md" "$TEMP_DIR/QUICK-START.md"
cp -r "$REPO_ROOT/docs" "$TEMP_DIR/docs"
cp "$REPO_ROOT/CLAUDE-solana.md" "$TEMP_DIR/CLAUDE-solana.md"
cp -r "$REPO_ROOT/tests" "$TEMP_DIR/tests"

# Create a custom .env with user data
echo "HELIUS_API_KEY=my-secret-key" > "$TEMP_DIR/.env"

echo "[pre-cleanup]"
assert_file_exists "$TEMP_DIR/install.sh" "Scaffolding: install.sh exists"
assert_file_exists "$TEMP_DIR/validate.sh" "Scaffolding: validate.sh exists"
assert_file_exists "$TEMP_DIR/README.md" "Scaffolding: README.md exists"
assert_file_exists "$TEMP_DIR/QUICK-START.md" "Scaffolding: QUICK-START.md exists"
assert_dir_exists "$TEMP_DIR/docs" "Scaffolding: docs/ exists"
assert_file_exists "$TEMP_DIR/CLAUDE-solana.md" "Scaffolding: CLAUDE-solana.md exists"
assert_dir_exists "$TEMP_DIR/tests" "Scaffolding: tests/ exists"
assert_dir_exists "$TEMP_DIR/.claude" ".claude/ exists pre-cleanup"

# --- Simulate cleanup: what /cleanup command instructs ---
simulate_cleanup() {
  local dir="$1"

  # Step 1: Copy CLAUDE-solana.md → CLAUDE.md (the production config)
  if [ -f "$dir/CLAUDE-solana.md" ]; then
    cp "$dir/CLAUDE-solana.md" "$dir/CLAUDE.md"
  fi

  # Step 2: Create .env from .env.example if no .env exists
  # (We already have .env, so skip)

  # Step 3: Remove scaffolding files
  rm -f "$dir/install.sh"
  rm -f "$dir/validate.sh"
  rm -f "$dir/README.md"
  rm -f "$dir/QUICK-START.md"
  rm -rf "$dir/docs"
  rm -f "$dir/CLAUDE-solana.md"
  rm -rf "$dir/tests"
}

simulate_cleanup "$TEMP_DIR"

echo "[post-cleanup]"
# CLAUDE.md should now contain solana-builder content
assert_file_contains "$TEMP_DIR/CLAUDE.md" "solana-builder" "CLAUDE.md contains solana-builder (from CLAUDE-solana.md)"

# .claude/ should be fully preserved
assert_dir_exists "$TEMP_DIR/.claude" ".claude/ preserved after cleanup"
assert_dir_exists "$TEMP_DIR/.claude/agents" "agents/ preserved after cleanup"
assert_dir_exists "$TEMP_DIR/.claude/commands" "commands/ preserved after cleanup"
assert_dir_exists "$TEMP_DIR/.claude/skills" "skills/ preserved after cleanup"
assert_file_exists "$TEMP_DIR/.claude/settings.json" "settings.json preserved after cleanup"
assert_json_valid "$TEMP_DIR/.claude/settings.json" "settings.json still valid after cleanup"

# Scaffolding files should be removed
assert_file_not_exists "$TEMP_DIR/install.sh" "install.sh removed"
assert_file_not_exists "$TEMP_DIR/validate.sh" "validate.sh removed"
assert_file_not_exists "$TEMP_DIR/README.md" "README.md removed"
assert_file_not_exists "$TEMP_DIR/QUICK-START.md" "QUICK-START.md removed"
assert_dir_not_exists "$TEMP_DIR/docs" "docs/ removed"
assert_file_not_exists "$TEMP_DIR/CLAUDE-solana.md" "CLAUDE-solana.md removed"
assert_dir_not_exists "$TEMP_DIR/tests" "tests/ removed"

# Preserved files should still exist
assert_file_exists "$TEMP_DIR/.env" ".env preserved after cleanup"
assert_file_contains "$TEMP_DIR/.env" "my-secret-key" ".env content preserved"
assert_file_exists "$TEMP_DIR/.gitignore" ".gitignore preserved after cleanup"

print_summary
