#!/usr/bin/env bash
set -euo pipefail

# skills.sh's list helpers, run the way skills.sh runs them: under pipefail. A helper built
# as `printf … | grep -q` reads a long list as "line absent" whenever grep exits on its
# first match before printf has written the rest. With a list past the pipe buffer that is
# every time, and in CI it surfaced as `printf: write error: Broken pipe`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SKILLS="$REPO_ROOT/.claude/bin/skills.sh"
echo "[test_skills_helpers] skills.sh list helpers under pipefail"

DEFS="$(awk '/^has_line\(\)/ || /^valid_name\(\)/' "$SKILLS")"
assert_eq "2" "$(printf '%s\n' "$DEFS" | grep -c '()')" "fixture: both helpers found in skills.sh"
assert_eq "0" "$(printf '%s\n' "$DEFS" | grep -vc '}$' || true)" "fixture: each is a whole one-line definition, so none is cut short"
eval "$DEFS"

BIG="$(seq 1 300000 | sed 's/^/pack-/')"
assert_cmd_success 'has_line "$BIG" pack-1' "has_line finds the first line of a list past the pipe buffer"
assert_cmd_success 'has_line "$BIG" pack-300000' "...and the last"
assert_cmd_fails 'has_line "$BIG" pack-300001' "...and not a line that is absent"
assert_cmd_fails 'has_line "$BIG" pack-' "...and not a prefix of a line"
assert_cmd_fails 'has_line "$BIG" "pack-*"' "...and reads the line as text, not as a pattern"
assert_cmd_success 'has_line "$(printf "a\n\nb")" ""' "an empty line counts as a line"
assert_cmd_success 'valid_name core-pack-2' "valid_name accepts a kebab-case name"
assert_cmd_fails 'valid_name Core_Pack' "valid_name refuses any other shape"

print_summary
