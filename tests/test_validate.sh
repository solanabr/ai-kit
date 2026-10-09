#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_validate] Running validate.sh from repo root..."

assert_cmd_success "cd '$REPO_ROOT' && bash validate.sh" "validate.sh exits 0"

# --- A clone without --recurse-submodules: every ext/ dir exists but is empty ---
echo "[uninitialized submodules]"
TEMP_DIR="$(new_tmp)" || exit 1
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

# Links between kit files are checked too, in agents and commands as well as skills
echo "[kit links]"
printf '[gone](../skills/no-such-reference.md)\n' > "$TEMP_DIR/.claude/agents/zz-agent.md"
printf '[gone](no-such-command.md)\n' > "$TEMP_DIR/.claude/commands/zz-command.md"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails on a broken link between kit files"
assert_contains "$OUT" "FAIL: .claude/agents/zz-agent.md -> ../skills/no-such-reference.md" "a broken link in an agent is reported"
assert_contains "$OUT" "FAIL: .claude/commands/zz-command.md -> no-such-command.md" "a broken link in a command is reported"
rm "$TEMP_DIR/.claude/agents/zz-agent.md" "$TEMP_DIR/.claude/commands/zz-command.md"

# Still checked: a link into a pack that is checked out, and a pack that doesn't exist
echo "[links still checked]"
touch "$TEMP_DIR/.claude/skills/ext/solana-dev/README.md"
printf '[moved](ext/solana-dev/moved.md) [typo](ext/no-such-pack/SKILL.md)\n' > "$TEMP_DIR/.claude/skills/zz-links.md"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails on a broken ext/ link"
assert_contains "$OUT" "FAIL: .claude/skills/zz-links.md -> ext/solana-dev/moved.md" "link into a checked-out pack is still checked"
assert_contains "$OUT" "FAIL: .claude/skills/zz-links.md -> ext/no-such-pack/SKILL.md" "link into a pack that does not exist still fails"
rm "$TEMP_DIR/.claude/skills/zz-links.md" "$TEMP_DIR/.claude/skills/ext/solana-dev/README.md"

# A pack's own submodules are third-party pins nobody here chose, and the registry's
# "vendored" field is the only place they are written down. Reading that record and
# comparing it to the gitlinks says nothing about a pack whose pins were never recorded
# at all — which is how two of them shipped unwatched — so validate.sh checks the inverse
# too. A vendored pack has no index to read, so its .gitmodules is what gets held against
# the record. Asserted by line rather than by exit code: filling a pack dir also dangles
# every hub link into it, so the run fails for that reason as well.
echo "[unrecorded nested submodule]"
NESTED="$TEMP_DIR/.claude/skills/ext/counterparty-gate"
printf '[submodule "vendor/unrecorded"]\n\tpath = vendor/unrecorded\n\turl = https://example.invalid/x\n' > "$NESTED/.gitmodules"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" || true
assert_contains "$OUT" 'counterparty-gate declares a submodule at vendor/unrecorded that "vendored" does not record' \
  "a nested submodule with no vendored record fails validation"
rm -f "$NESTED/.gitmodules"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" || true
assert_contains "$OUT" 'packs with submodules of their own are recorded in "vendored", and match' \
  "...and the check passes once the pack declares nothing the record misses"

# The shipped VERSION must sit outside update.sh's retired-defaults migration case
echo "[migration gate]"
UPDATE_SH="$TEMP_DIR/.claude/bin/update.sh"
cp "$UPDATE_SH" "$TEMP_DIR/update.sh.orig"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "0" "$RC" "validate.sh passes with the shipped VERSION and update.sh's case"

printf 'solana-ai-kit 2.1.0\n' > "$TEMP_DIR/.claude/VERSION"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails when VERSION is left at a migrated version (2.1.0)"
assert_contains "$OUT" "FAIL: Shipped VERSION 2.1.0 is outside" "the failure names the shipped version"
cp "$REPO_ROOT/.claude/VERSION" "$TEMP_DIR/.claude/VERSION"

SHIPPED="$(awk '{print $NF}' "$REPO_ROOT/.claude/VERSION")"
sed "s/^  unknown|1\.\*|/  unknown|$SHIPPED|1.*|/" "$TEMP_DIR/update.sh.orig" > "$UPDATE_SH"
assert_cmd_success "grep -q '  unknown|$SHIPPED|' '$UPDATE_SH'" "fixture adds the shipped version to the case"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails when the shipped version is added to the migration case"
cp "$TEMP_DIR/update.sh.orig" "$UPDATE_SH"

# A default MCP server on @latest (or any unpinned npx package) fails validation
echo "[mcp pins]"
sed -i.bak 's/"helius-mcp@[^"]*"/"helius-mcp@latest"/' "$TEMP_DIR/.mcp.json"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails when .mcp.json uses @latest"
assert_contains "$OUT" "helius:helius-mcp@latest" "the failure names the unpinned server"
sed -i.bak 's/"helius-mcp@latest"/"helius-mcp"/' "$TEMP_DIR/.mcp.json"
OUT="$(cd "$TEMP_DIR" && bash validate.sh 2>&1)" && RC=0 || RC=$?
assert_eq "1" "$RC" "validate.sh fails when an npx package has no version"

print_summary
