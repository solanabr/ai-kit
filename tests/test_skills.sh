#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SKILLS_DIR="$REPO_ROOT/.claude/skills"
SKILL_FILE="$SKILLS_DIR/SKILL.md"

echo "[test_skills] Checking SKILL.md links..."

assert_file_exists "$SKILL_FILE" "SKILL.md exists"

# Parse markdown links (excluding http links)
BROKEN=0
CHECKED=0
while IFS= read -r link; do
  link="$(echo "$link" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  [ -z "$link" ] && continue

  target="$SKILLS_DIR/$link"
  CHECKED=$((CHECKED + 1))

  TOTAL=$((TOTAL + 1))
  if [ -e "$target" ] || [ -d "$target" ]; then
    echo "  PASS: $link exists"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Broken link -> $link"
    FAIL=$((FAIL + 1))
    BROKEN=$((BROKEN + 1))
  fi
done < <(grep -oE '\]\([^)]+\)' "$SKILL_FILE" | sed 's/\](//' | sed 's/)//' | grep -v '^http')

echo ""
echo "Checked $CHECKED links, $BROKEN broken."

echo ""
echo "[test_skills] Checking links in local skills, agents and commands (relative to each file, #anchors dropped)..."

LOCAL_CHECKED=0
LOCAL_BROKEN=0
while IFS= read -r file; do
  dir="$(dirname "$file")"
  rel="${file#"$REPO_ROOT"/}"
  while IFS= read -r link; do
    LOCAL_CHECKED=$((LOCAL_CHECKED + 1))
    TOTAL=$((TOTAL + 1))
    if [ -e "$dir/${link%%#*}" ]; then
      PASS=$((PASS + 1))
    else
      echo "  FAIL: Broken link in $rel -> $link"
      FAIL=$((FAIL + 1))
      LOCAL_BROKEN=$((LOCAL_BROKEN + 1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$file" | sed 's/\](//' | sed 's/)$//' | grep -v '^http' | grep -v '^#')
done < <(find "$SKILLS_DIR" -name '*.md' -not -path '*/ext/*' -not -path "$SKILL_FILE"; find "$REPO_ROOT/.claude/agents" "$REPO_ROOT/.claude/commands" -name '*.md')

echo "Checked $LOCAL_CHECKED local links, $LOCAL_BROKEN broken."

print_summary
