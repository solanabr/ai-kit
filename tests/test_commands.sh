#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

CMDS_DIR="$REPO_ROOT/.claude/commands"

echo "[test_commands] Checking command frontmatter..."

COUNT=0
for f in "$CMDS_DIR"/*.md; do
  name="$(basename "$f")"
  COUNT=$((COUNT + 1))

  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(sed -n '/^---$/,/^---$/p' "$f" | head -20 || true)"

    TOTAL=$((TOTAL + 1))
    if echo "$frontmatter" | grep -q "^description:"; then
      echo "  PASS: $name has description:"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name missing description:"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  FAIL: $name has no frontmatter"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
  fi
done

echo ""
assert_eq "31" "$COUNT" "Total command count is 31"

echo ""
echo "[test_commands] Checking setup-mcp.md covers every .env.example key..."

ENV_EXAMPLE="$REPO_ROOT/.env.example"
SETUP_MCP="$CMDS_DIR/setup-mcp.md"

if [ -f "$ENV_EXAMPLE" ] && [ -f "$SETUP_MCP" ]; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    assert_file_contains "$SETUP_MCP" "$key" "setup-mcp.md mentions .env.example key: $key"
  done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$ENV_EXAMPLE" | sed 's/=$//')
else
  assert_eq "0" "1" ".env.example and setup-mcp.md both exist for drift check"
fi

echo ""
echo "[test_commands] Checking /dream and /diff-review write to the Project Learnings subsections in CLAUDE-solana.md..."
for sub in "### Recurring Issues" "### Fix Patterns" "### Config Conventions"; do
  assert_file_contains "$REPO_ROOT/CLAUDE-solana.md" "$sub" "CLAUDE-solana.md has '$sub'"
  assert_file_contains "$CMDS_DIR/dream.md" "\`$sub\`" "dream.md names '$sub'"
done
assert_file_contains "$CMDS_DIR/diff-review.md" '`### Recurring Issues`' "diff-review.md files repeated mistakes under ### Recurring Issues"
assert_file_contains "$CMDS_DIR/diff-review.md" '`### Config Conventions`' "diff-review.md files confirmed conventions under ### Config Conventions"
assert_file_contains "$CMDS_DIR/dream.md" "if it is missing (never a differently named one)" "dream.md creates a missing subsection instead of inventing one"

echo ""
echo "[test_commands] Checking --agents install-mode support..."
assert_file_contains "$CMDS_DIR/resync.md" ".agents/bin" "resync.md supports --agents installs (.agents/bin)"
assert_file_contains "$CMDS_DIR/update.md" ".agents/bin" "update.md supports --agents installs (.agents/bin)"

print_summary
