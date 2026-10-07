#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# What a vendored pack loads into an agent without anyone choosing it.
#
# "ext/ is not auto-discovered" is a property of the 44 packs that happen to put their
# skills at <pack>/skills/<name>/, not of ext/. Claude Code discovers a directory named
# .claude/skills at ANY depth, so a pack shipping one has its skills listed and
# invokable in every session of every project that installed it — expo ships
# .claude/skills/expo-skill-eval/, and it was observed listed from
# .claude/skills/ext/expo/.claude/skills. A pack's .claude/ is also where it would put
# rules, agents, settings or hooks of its own (qedgen ships .claude/rules/ with
# paths: "**/*.lean").
#
# Two halves, and both are needed. At pin time this suite records which packs carry
# such a directory, so a pack that gains one is reviewed rather than shipped silently.
# At install time it asserts the installers strip every one, which is what actually
# protects a project (.claude/bin/_pack_strip.sh, called from install.sh and
# skills.sh). The pin-time half is review; the install-time half is the control.

echo "[test_pack_load_surfaces] What a vendored pack loads on its own"
echo ""

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

EXT="$REPO_ROOT/.claude/skills/ext"

# --- From here on every check needs the ext/ packs checked out -----------------------
#
# Every check here reads real pack content or installs it, so without a checkout the
# setup can only report that setup state. The setup is not run, and every check goes
# through pack_check, which records it as skipped under the same message — one skip per
# check either way, so an uninitialised tree reports the same total as a checked-out
# one and there is no count to keep in step by hand. Outputs the checks read are
# pre-set to "" and filled only inside `if packs_ready`, since a bare assignment from a
# failing substitution would abort the suite under set -e.
if ext_packs_uninitialized; then PACKS_READY=0; else PACKS_READY=1; fi
packs_ready() { [ "$PACKS_READY" = 1 ]; }

# pack_check <assert_*> <args...> — run one check, or record it as skipped. The skip
# text is the last argument, which is the message every assert_* helper takes last.
pack_check() {
  if packs_ready; then
    "$@"
  else
    skip "${*: -1} (its ext/ pack is not checked out)"
  fi
}

# packs_with <any|skills> — ids of the packs holding a .claude/ of their own ("any"),
# or one holding a skills/ ("skills"), sorted and space separated. An empty .claude/
# does not count: Claude Code's own write-tracking scratch directory
# (.claude/.cc-writes) appears under a pack in a working checkout, is untracked and
# holds no files, and counting it would make this suite pass in CI and fail on a
# developer's machine.
packs_with() {
  local want="$1" pack dir out="" hit
  for pack in "$EXT"/*/; do
    [ -d "$pack" ] || continue
    hit=""
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      [ -n "$(find "$dir" -type f -print -quit 2>/dev/null)" ] || continue
      if [ "$want" = skills ] && [ ! -d "$dir/skills" ]; then continue; fi
      hit=1
    done < <(find "$pack" -name .claude -prune -print 2>/dev/null)
    [ -z "$hit" ] || out="$out$(basename "${pack%/}")
"
  done
  printf '%s' "$(printf '%s' "$out" | sort | tr '\n' ' ' | sed -E 's/ +$//')"
}

# --- Pin time: which packs carry a load surface of their own -------------------------
#
# These two lists are a review record, not a safety mechanism — the installers strip
# every one of these whether it is listed here or not. When a pin bump makes a line
# below fail: read what the pack now ships, and if it is the pack's own harness
# config (it has been, every time so far), update the list. The point is that somebody
# looks.
echo "[pin time]"
KNOWN_NESTED_CLAUDE="expo qedgen"
KNOWN_NESTED_SKILLS="expo"
NESTED_CLAUDE=""
NESTED_SKILLS=""
if packs_ready; then
  NESTED_CLAUDE="$(packs_with any)"
  NESTED_SKILLS="$(packs_with skills)"
fi
pack_check assert_eq "$KNOWN_NESTED_CLAUDE" "$NESTED_CLAUDE" \
  "Only the recorded packs ship a .claude/ of their own"
pack_check assert_eq "$KNOWN_NESTED_SKILLS" "$NESTED_SKILLS" \
  "Only the recorded packs ship a .claude/skills/, which Claude Code discovers at any depth"
# Not vacuous: expo really does ship the directory this suite exists for, so the
# install-time checks below have something to strip.
pack_check assert_file_exists "$EXT/expo/.claude/skills/expo-skill-eval/SKILL.md" \
  "expo still ships the nested skill the install-time checks must remove"

# --- Install time: a project receives none of it -------------------------------------
echo "[install]"
PROJ="$TEMP_DIR/project"
AGENTS_PROJ="$TEMP_DIR/agents-project"
# find_claude <dir> — pack-local .claude/ directories under an installed ext/ tree.
find_claude() { find "$1" -name .claude -prune -print 2>/dev/null | wc -l | tr -d ' '; }
if packs_ready; then
  mkdir -p "$PROJ" "$AGENTS_PROJ"
  (cd "$PROJ" && git init -q)
  SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --with expo "$PROJ" \
    > "$TEMP_DIR/install.log" 2>&1
  SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents --with expo "$AGENTS_PROJ" \
    > "$TEMP_DIR/install-agents.log" 2>&1
fi
# The pack installed at all — without this the two counts below pass on an empty tree.
pack_check assert_file_exists "$PROJ/.claude/skills/ext/expo/plugins/expo/skills/expo-overview/SKILL.md" \
  "install.sh --with expo installs the pack's own skills"
pack_check assert_eq "0" "$(find_claude "$PROJ/.claude/skills/ext")" \
  "An installed project carries no pack-local .claude/"
pack_check assert_file_not_exists "$PROJ/.claude/skills/ext/expo/.claude/skills/expo-skill-eval/SKILL.md" \
  "...so expo's nested skill is not listed in the project's sessions"
pack_check assert_eq "0" "$(find_claude "$AGENTS_PROJ/.agents/skills/ext")" \
  "An --agents install carries none either"
pack_check assert_dir_exists "$AGENTS_PROJ/.agents/skills/ext/expo/plugins/expo/skills" \
  "...and still has the pack"

# --- skills.sh add: the on-demand path -----------------------------------------------
echo "[skills.sh add]"
if packs_ready; then
  (cd "$PROJ" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add qedgen) \
    > "$TEMP_DIR/add.log" 2>&1
fi
pack_check assert_file_exists "$PROJ/.claude/skills/ext/qedgen/skills/qedgen/SKILL.md" \
  "skills.sh add installs qedgen"
pack_check assert_eq "0" "$(find_claude "$PROJ/.claude/skills/ext/qedgen")" \
  "...without its .claude/rules and .claude/agents"
# The kit's own checkout is a live submodule: stripping there would dirty the gitlink
# and fail every pin check. skills.sh must write only to the copy.
pack_check assert_file_exists "$EXT/qedgen/.claude/rules/lean-proofs.md" \
  "...and without touching the kit's own checkout of it"

# --- skills.sh prune: the /update path -----------------------------------------------
# update.sh copies the packs itself, from a frozen code path, and then calls
# `skills.sh prune`. That call is where a project already installed gets cleaned, so a
# surface planted in an installed pack must not survive it.
echo "[skills.sh prune]"
PRUNE_OUT=""
if packs_ready; then
  mkdir -p "$PROJ/.claude/skills/ext/expo/.claude/skills/planted"
  printf -- '---\nname: planted\ndescription: a skill a pack smuggled back in\n---\n' \
    > "$PROJ/.claude/skills/ext/expo/.claude/skills/planted/SKILL.md"
  PRUNE_OUT="$(cd "$PROJ" && bash .claude/bin/skills.sh prune 2>&1)"
fi
pack_check assert_eq "0" "$(find_claude "$PROJ/.claude/skills/ext")" \
  "skills.sh prune removes a .claude/ an older install left in a pack"
pack_check assert_contains "$PRUNE_OUT" "pack-local .claude/" \
  "...and says it did"
pack_check assert_dir_exists "$PROJ/.claude/skills/ext/expo/plugins/expo/skills" \
  "...and leaves the pack itself alone"

print_summary
