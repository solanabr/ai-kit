#!/usr/bin/env bash
set -euo pipefail

# install.sh and /update fetch the same ref for the same upstream (#125): the newest
# vX.Y.Z release tag above v2.4.0, else main, or whatever SOLANA_AI_KIT_BRANCH names.
# install.sh resolves it inline (a curl | bash install has no kit on disk yet) and /update
# through .claude/bin/kit-ref.sh, so the two copies are run side by side here against
# local fixture upstreams rather than compared as text.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

KIT_REF="$REPO_ROOT/.claude/bin/kit-ref.sh"
UPDATE_MD="$REPO_ROOT/.claude/commands/update.md"
TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_kit_ref] install.sh and /update resolve the same kit ref"
echo ""

# Identity and signing from the environment, never from the machine's git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset SOLANA_AI_KIT_BRANCH SOLANA_CLAUDE_BRANCH SOLANA_AI_KIT_UPSTREAM SOLANA_CLAUDE_UPSTREAM \
  SOLANA_AI_KIT_LOCAL_SRC SOLANA_CLAUDE_LOCAL_SRC 2>/dev/null || true

# upstream <name> <tag>... — a one-commit repo on main carrying the given tags
upstream() {
  local dir="$TEMP_DIR/up-$1" tag
  shift
  mkdir -p "$dir"
  echo fixture > "$dir/README.md"
  (
    cd "$dir"
    git init -q -b main
    git add README.md
    git commit -q --no-gpg-sign -m fixture
    for tag in "$@"; do git tag --no-sign "$tag"; done
  )
  printf '%s' "$dir"
}

# The ref install.sh cloned, from its "Cloning <url> (<ref>)..." step. The fixture holds
# no kit, so the install stops after the clone; only the ref is read.
install_ref() {
  local out
  out="$(env "$@" bash "$REPO_ROOT/install.sh" "$TEMP_DIR/target-$RANDOM" 2>&1 || true)"
  printf '%s\n' "$out" | sed -n 's/^▸ Cloning .* (\(.*\))\.\.\.$/\1/p' | head -1
}
update_ref() { env "$@" bash "$KIT_REF"; }

# same_ref <expected> <label> <env assignments...>
same_ref() {
  local expected="$1" label="$2" got_install got_update
  shift 2
  got_install="$(install_ref "$@")"
  got_update="$(update_ref "$@")"
  assert_eq "$expected" "$got_install" "install.sh: $label"
  assert_eq "$expected" "$got_update" "/update (kit-ref.sh): $label"
}

echo "[resolution]"
UP="$(upstream releases v2.0.1 v2.1.0 v2.4.0 v2.5.0 v2.9.0 v2.10.0 v3.0.0-rc1 vnext)"
same_ref v2.10.0 "the newest release tag, compared numerically, ignoring pre-releases" SOLANA_AI_KIT_UPSTREAM="$UP"
same_ref v2.10.0 "the legacy SOLANA_CLAUDE_UPSTREAM is honoured" SOLANA_CLAUDE_UPSTREAM="$UP"
same_ref v2.5.0 "SOLANA_AI_KIT_BRANCH overrides the tag" SOLANA_AI_KIT_UPSTREAM="$UP" SOLANA_AI_KIT_BRANCH=v2.5.0
same_ref main "SOLANA_AI_KIT_BRANCH=main tracks main" SOLANA_AI_KIT_UPSTREAM="$UP" SOLANA_AI_KIT_BRANCH=main
same_ref v2.4.0 "the legacy SOLANA_CLAUDE_BRANCH is honoured" SOLANA_AI_KIT_UPSTREAM="$UP" SOLANA_CLAUDE_BRANCH=v2.4.0

# Every release up to v2.4.0 ships an /update that fetches main, so landing on one would
# flip the install between that tag and main on each /update. Both fall back to main.
OLD="$(upstream old v2.1.0 v2.2.0 v2.4.0)"
same_ref main "only tags up to v2.4.0: main, not a tag whose /update fetches main" SOLANA_AI_KIT_UPSTREAM="$OLD"
NONE="$(upstream none)"
same_ref main "no tags: main" SOLANA_AI_KIT_UPSTREAM="$NONE"
same_ref main "an unreachable upstream: main" SOLANA_AI_KIT_UPSTREAM="$TEMP_DIR/no-such-repo"

echo "[wiring]"
# /update hands kit-ref.sh's answer to update.sh, whose frozen first 93 lines default to
# main and honour SOLANA_AI_KIT_BRANCH: that variable is the only way in.
assert_file_contains "$UPDATE_MD" 'SOLANA_AI_KIT_BRANCH="$(bash "$BIN/kit-ref.sh" 2>/dev/null)" bash "$BIN/update.sh"' \
  "/update passes kit-ref.sh's ref to update.sh"
assert_file_contains "$REPO_ROOT/.claude/bin/update.sh" 'BRANCH="${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-main}}"' \
  "update.sh takes its ref from SOLANA_AI_KIT_BRANCH"
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_REF" ]; then
  echo "  PASS: kit-ref.sh is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL: kit-ref.sh is not executable"
  FAIL=$((FAIL + 1))
fi
# The floor is written twice; a change to one copy alone would split the two answers on
# exactly the upstream the cases above do not build.
FLOOR_REF="$(sed -n 's/^TAG_FLOOR="\(.*\)"$/\1/p' "$KIT_REF")"
FLOOR_INSTALL="$(sed -n 's/.*awk -v floor="\([0-9.]*\)".*/\1/p' "$REPO_ROOT/install.sh")"
assert_eq "$FLOOR_REF" "$FLOOR_INSTALL" "install.sh and kit-ref.sh share the tag floor ($FLOOR_REF)"
# A third copy: skills.sh add fetches the tag an install's VERSION names only above the
# floor, so a raised floor there alone would send every install between the two to main.
SKILLS_SH="$REPO_ROOT/.claude/bin/skills.sh"
floor_of() { sed -n 's/.*awk -v floor="\([0-9.]*\)".*/\1/p' "$1"; }
assert_eq "$FLOOR_REF" "$(floor_of "$SKILLS_SH")" "skills.sh add shares the tag floor ($FLOOR_REF)"
# Control: a skills.sh whose floor moved is told apart, so the assertion above can fail.
sed 's/awk -v floor="[0-9.]*"/awk -v floor="9.9.9"/' "$SKILLS_SH" > "$TEMP_DIR/skills-moved.sh"
assert_eq "9.9.9" "$(floor_of "$TEMP_DIR/skills-moved.sh")" "a moved skills.sh floor reads back as the moved value"
# And the floor is what skills.sh compares against: the tag named for each VERSION.
# The awk program is lifted from skills.sh, so a rewrite that stops reading floor fails here.
SKILLS_AWK="$(sed -n '/branch="$(awk -v floor=/,/CONFIG_DIR\/VERSION/p' "$SKILLS_SH" \
  | sed -e '1s/.*awk -v floor="[0-9.]*" '"'"'//' -e '$d' | sed '$s/'"'"' \\$//')"
for pair in "2.4.0:" "2.3.9:" "2.4.1:v2.4.1" "2.10.0:v2.10.0" "3.0.0:v3.0.0" "2.5.0-rc1:"; do
  v="${pair%%:*}"; want="${pair#*:}"
  got="$(echo "solana-ai-kit $v" | awk -v floor="$FLOOR_REF" "$SKILLS_AWK")"
  assert_eq "$want" "$got" "skills.sh add: VERSION $v fetches ${want:-main}"
done

print_summary
