#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SKILLS_DIR="$REPO_ROOT/.claude/skills"
SKILL_FILE="$SKILLS_DIR/SKILL.md"

echo "[test_skills] Checking SKILL.md links..."

assert_file_exists "$SKILL_FILE" "SKILL.md exists"

# Parse markdown links (excluding http links). A link into an ext/ pack that is present
# but empty is skipped: the submodule isn't checked out. A link into a pack that IS
# checked out still fails if the file is gone, which is how an upstream path rename is
# caught.
BROKEN=0
CHECKED=0
NOT_CHECKED_OUT=0
while IFS= read -r link; do
  link="$(echo "$link" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  [ -z "$link" ] && continue

  target="$SKILLS_DIR/$link"

  if [ -e "$target" ] || [ -d "$target" ]; then
    CHECKED=$((CHECKED + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $link exists"
    PASS=$((PASS + 1))
  elif in_uninitialized_submodule "$target"; then
    NOT_CHECKED_OUT=$((NOT_CHECKED_OUT + 1))
    skip "$link (its pack is not checked out)"
  else
    CHECKED=$((CHECKED + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: Broken link -> $link"
    FAIL=$((FAIL + 1))
    BROKEN=$((BROKEN + 1))
  fi
done < <(grep -oE '\]\([^)]+\)' "$SKILL_FILE" | sed 's/\](//' | sed 's/)//' | grep -v '^http')

echo ""
echo "Checked $CHECKED links, $BROKEN broken, $NOT_CHECKED_OUT into packs that are not checked out."
# The tally above is printed whatever happened, including "Checked 0 links, 0 broken",
# which reads like a pass. The extraction is a grep for inline `](target)`, so a hub
# rewritten with reference-style links empties it and the whole suite collapses to the
# one assert_file_exists. Demonstrated: 284 checks became 1, with a broken route left in
# the hub and the suite exiting 0.
assert_cmd_success "[ $((CHECKED + NOT_CHECKED_OUT)) -gt 0 ]" \
  "SKILL.md yielded relative links to check ($CHECKED checked, $NOT_CHECKED_OUT not checked out)"

print_summary
