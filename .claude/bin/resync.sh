#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — Submodule Resync
# Updates external skill submodules to latest and verifies integrity.
#
# Usage:
#   bash .claude/bin/resync.sh

# Auto-detect config dir from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_NAME="$(basename "$CONFIG_DIR")"
TARGET_DIR="$(cd "$CONFIG_DIR/.." && pwd)"

# Run from the target project root regardless of the caller's cwd, so the
# relative paths and git commands below always resolve against the project,
# not wherever this script happened to be invoked from.
cd "$TARGET_DIR"

if [ ! -d "$TARGET_DIR/$CONFIG_NAME/skills/ext" ]; then
  echo "Error: $CONFIG_NAME/skills/ext/ not found. Run from your project root."
  exit 1
fi

# install.sh also supports non-git projects; there is nothing to resync there
IN_GIT=false
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT=true

if [ "$IN_GIT" = true ]; then
  echo "Updating external skill submodules..."
  git submodule update --remote --merge || {
    echo "Submodule update failed. Attempting init first..."
    git submodule update --init --recursive
    git submodule update --remote --merge
  }
  echo ""

  echo "Changes in submodules:"
  git diff --submodule=diff
  echo ""

  echo "Submodule status:"
  git submodule status
  echo ""
else
  echo "Not a git repository: skipping the submodule update (ext/ skills are vendored copies here)."
  echo "Refresh them with: bash $CONFIG_NAME/bin/update.sh"
  echo ""
fi

# Verify skill paths
SKILL_HUB="$CONFIG_NAME/skills/SKILL.md"
SKILL_DIR="$CONFIG_NAME/skills"
MISSING=0

if [ -f "$SKILL_HUB" ]; then
  echo "Verifying skill paths referenced in SKILL.md..."

  while IFS= read -r ref; do
    FULL_PATH="$SKILL_DIR/$ref"
    if [ ! -f "$FULL_PATH" ]; then
      echo "  MISSING: $ref -> $FULL_PATH"
      MISSING=$((MISSING + 1))
    fi
  done < <(grep -oE '\]\([^)]+\.md\)' "$SKILL_HUB" | sed 's/\](//' | sed 's/)//' | grep -v '^http')

  while IFS= read -r ref; do
    FULL_PATH="$SKILL_DIR/$ref"
    if [ ! -d "$FULL_PATH" ]; then
      echo "  MISSING DIR: $ref -> $FULL_PATH"
      MISSING=$((MISSING + 1))
    fi
  done < <(grep -oE '\]\([^)]+/\)' "$SKILL_HUB" | sed 's/\](//' | sed 's/)//' | grep -v '^http')

  if [ "$MISSING" -eq 0 ]; then
    echo "  All skill paths resolve correctly."
  else
    echo ""
    echo "  $MISSING broken path(s) found. Fix SKILL.md or check submodule state."
  fi
fi
echo ""

if [ "$IN_GIT" = true ]; then
  echo "=== Submodule Summary ==="
  echo ""
  git submodule foreach --quiet '
    LATEST=$(git log -1 --format="%h %s" 2>/dev/null)
    echo "  $name: $LATEST"
  '
  echo ""
  echo "Run 'git add .gitmodules $CONFIG_NAME/skills/ext/' and commit to lock updates."
fi
