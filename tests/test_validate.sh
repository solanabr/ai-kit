#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_validate] Running validate.sh from repo root..."

assert_cmd_success "cd '$REPO_ROOT' && bash validate.sh" "validate.sh exits 0"

# --- A clone without --recurse-submodules: every ext/ dir exists but is empty ---
echo "[uninitialized submodules]"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/.claude/skills/ext"
for item in "$REPO_ROOT/.claude"/*; do
  [ "$(basename "$item")" = skills ] || cp -R "$item" "$TEMP_DIR/.claude/"
done
for item in "$REPO_ROOT/.claude/skills"/*; do
  [ "$(basename "$item")" = ext ] || cp -R "$item" "$TEMP_DIR/.claude/skills/"
done
for dir in "$REPO_ROOT/.claude/skills/ext"/*/; do
  mkdir "$TEMP_DIR/.claude/skills/ext/$(basename "$dir")"
done
cp "$REPO_ROOT/validate.sh" "$REPO_ROOT/.env.example" "$REPO_ROOT/.mcp.json" "$TEMP_DIR/"
# plugin/ is mostly symlinks into .claude/; -P copies them as links, so they resolve inside the fixture
cp -RP "$REPO_ROOT/plugin" "$TEMP_DIR/"

OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "0" "$RC" "validate.sh exits 0 when the ext/ submodules are not checked out"
assert_contains "$OUT" "checks skipped because submodules aren't initialized" "summary reports the skipped checks"

# Still checked: a link into a pack that is checked out, and a pack that doesn't exist
echo "[links still checked]"
touch "$TEMP_DIR/.claude/skills/ext/solana-dev/README.md"
printf '[moved](ext/solana-dev/moved.md) [typo](ext/no-such-pack/SKILL.md)\n' > "$TEMP_DIR/.claude/skills/zz-links.md"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails on a broken ext/ link"
assert_contains "$OUT" "FAIL: .claude/skills/zz-links.md -> ext/solana-dev/moved.md" "link into a checked-out pack is still checked"
assert_contains "$OUT" "FAIL: .claude/skills/zz-links.md -> ext/no-such-pack/SKILL.md" "link into a pack that does not exist still fails"

print_summary
