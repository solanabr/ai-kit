#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — Submodule Resync
# Updates external skill submodules to latest and verifies integrity.
#
# Usage:
#   bash .claude/bin/resync.sh
#   bash .agents/bin/resync.sh

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

# Hub links into an extension this project has not installed (registry tier +
# skills/extensions.txt, read by skills.sh) dangle until skills.sh add. They are
# not broken paths: count them apart and name the extensions instead.
NOT_INSTALLED=" "
if [ -f "$SCRIPT_DIR/skills.sh" ]; then
  NOT_INSTALLED=" $(bash "$SCRIPT_DIR/skills.sh" uninstalled 2>/dev/null | tr '\n' ' ' || true)"
fi
SKIPPED=0
SKIPPED_IDS=""
skip_uninstalled() {
  local id="${1#ext/}"
  [ "$id" != "$1" ] || return 1
  id="${id%%/*}"
  case "$NOT_INSTALLED" in *" $id "*) ;; *) return 1 ;; esac
  SKIPPED=$((SKIPPED + 1))
  case "$SKIPPED_IDS " in *" $id "*) ;; *) SKIPPED_IDS="$SKIPPED_IDS $id" ;; esac
}

if [ -f "$SKILL_HUB" ]; then
  echo "Verifying skill paths referenced in SKILL.md..."

  while IFS= read -r ref; do
    FULL_PATH="$SKILL_DIR/$ref"
    if [ ! -f "$FULL_PATH" ]; then
      skip_uninstalled "$ref" && continue
      echo "  MISSING: $ref -> $FULL_PATH"
      MISSING=$((MISSING + 1))
    fi
  done < <(grep -oE '\]\([^)]+\.md\)' "$SKILL_HUB" | sed 's/\](//' | sed 's/)//' | grep -v '^http')

  while IFS= read -r ref; do
    FULL_PATH="$SKILL_DIR/$ref"
    if [ ! -d "$FULL_PATH" ]; then
      skip_uninstalled "$ref" && continue
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
  if [ "$SKIPPED" -gt 0 ]; then
    echo "  Skipped $SKIPPED link(s) into extensions this project has not installed:$SKIPPED_IDS"
    echo "  Install one when a task needs it: bash $CONFIG_NAME/bin/skills.sh add <id>"
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
