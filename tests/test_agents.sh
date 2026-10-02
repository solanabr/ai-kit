#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

AGENTS_DIR="$REPO_ROOT/.claude/agents"

echo "[test_agents] Checking agent frontmatter..."

COUNT=0
for f in "$AGENTS_DIR"/*.md; do
  name="$(basename "$f")"
  COUNT=$((COUNT + 1))

  # Extract frontmatter
  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(sed -n '/^---$/,/^---$/p' "$f" | head -20 || true)"

    TOTAL=$((TOTAL + 1))
    if echo "$frontmatter" | grep -q "^name:"; then
      echo "  PASS: $name has name:"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name missing name:"
      FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    if echo "$frontmatter" | grep -q "^description:"; then
      echo "  PASS: $name has description:"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name missing description:"
      FAIL=$((FAIL + 1))
    fi
    # model: is optional (omitted = inherit the session model); test_model_routing.sh checks values
  else
    echo "  FAIL: $name has no frontmatter"
    TOTAL=$((TOTAL + 2))
    FAIL=$((FAIL + 2))
  fi
done

echo ""
assert_eq "15" "$COUNT" "Total agent count is 15"

echo ""
echo "[test_agents] Checking #[error_code] guidance (every enum starts at 6000 unless offset is set)..."
assert_file_not_contains "$AGENTS_DIR/anchor-engineer.md" 'One `#[error_code]` enum per program' "anchor-engineer.md drops the false one-enum rule"
assert_file_contains "$AGENTS_DIR/anchor-engineer.md" '#[error_code(offset = N)]' "anchor-engineer.md names the offset fix for a second enum"
assert_file_contains "$REPO_ROOT/.claude/commands/audit-solana.md" '**Error codes**' "audit-solana.md checks for overlapping #[error_code] ranges"

print_summary
