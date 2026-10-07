#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Nested third-party trees must not survive /update.
#
# update.sh clones with --recurse-submodules from inside the frozen region, so every
# pack's own submodules arrive with the copy and the prune after it is the only thing
# that removes them. Until this suite existed nothing ran that prune: every `vendored`
# assertion in tests/ and validate.sh is a schema check through python3's json, which
# reads the registry correctly, while the prune used a line-oriented parser that read
# only the entries written on one line. Two parsers, one field — the strict one guarded
# nothing and the loose one did the deleting, and 16 of 18 recorded paths shipped.
#
# So this suite runs the real update.sh against a synthetic source and a synthetic
# project, and looks at what is left on disk. The fixture carries the three shapes that
# matter and the decoys that must survive them:
#
#   multi-line-pack  a `vendored` object spanning several lines, as google's sixteen
#                    entries do, and no submodule file of its own — the registry path
#                    alone, and the exact shape that went unpruned
#   inline-pack      a single-line `vendored` object — what the old parser did read, so
#                    this is the regression guard on the case that already worked
#   unrecorded-pack  a submodule file of its own and no `vendored` record at all, as
#                    counterparty-gate and expo ship today — the per-pack path alone
#   escape-pack      a submodule file and a record that both try to climb out of ext/
#
# Nothing here reaches the network and no pack content is needed, so it runs the same on
# a worktree with uninitialized submodules as it does in CI.

echo "[test_update_vendored_prune] /update removes a pack's own submodules from a project"
echo ""

SRC_DIR="$(new_tmp)" || exit 1
PROJ_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$SRC_DIR" "$PROJ_DIR"' EXIT

# --- The synthetic upstream -------------------------------------------------
#
# update.sh takes this path through SOLANA_AI_KIT_LOCAL_SRC, which only needs a .claude/
# directory. Keeping it minimal keeps the run hermetic: with no bin/skills.sh in it the
# pin report and `skills.sh prune` are both skipped, so nothing but the prune under test
# can remove a directory. _env_merge.sh is here because update.sh sources it unguarded.
mkdir -p "$SRC_DIR/.claude/bin" "$SRC_DIR/.claude/skills"
cp "$REPO_ROOT/.claude/bin/update.sh" "$SRC_DIR/.claude/bin/update.sh"
cp "$REPO_ROOT/.claude/bin/_env_merge.sh" "$SRC_DIR/.claude/bin/_env_merge.sh"
# A current version keeps the retired-defaults migration out of the way.
printf 'solana-ai-kit 99.0.0\n' > "$SRC_DIR/.claude/VERSION"

# The registry the prune reads is the one update.sh copies in, so the fixture lives here.
# Indentation matters: the parser this replaced keyed off six leading spaces.
cat > "$SRC_DIR/.claude/skills/skill-registry.json" <<'JSON'
{
  "version": "1.2",
  "entries": [
    {
      "id": "multi-line-pack",
      "path": ".claude/skills/ext/multi-line-pack",
      "vendored": {
        "nested/one": "1111111111111111111111111111111111111111",
        "nested/two": "2222222222222222222222222222222222222222",
        "deeper/three/four": "3333333333333333333333333333333333333333"
      }
    },
    {
      "id": "inline-pack",
      "path": ".claude/skills/ext/inline-pack",
      "vendored": { "vendor/thirdparty": "4444444444444444444444444444444444444444" }
    },
    {
      "id": "escape-pack",
      "path": ".claude/skills/ext/escape-pack",
      "vendored": { "../../../../escaped-by-registry": "5555555555555555555555555555555555555555" }
    },
    {
      "id": "clean-pack",
      "path": ".claude/skills/ext/clean-pack"
    }
  ]
}
JSON

# --- The synthetic project --------------------------------------------------
mkdir -p "$PROJ_DIR/.claude/bin" "$PROJ_DIR/.claude/skills/ext"
cp "$REPO_ROOT/.claude/bin/update.sh" "$PROJ_DIR/.claude/bin/update.sh"
cp "$REPO_ROOT/.claude/bin/_env_merge.sh" "$PROJ_DIR/.claude/bin/_env_merge.sh"
EXT="$PROJ_DIR/.claude/skills/ext"

# seed <path> — a file deep enough that a shallow delete would leave something behind.
seed() {
  mkdir -p "$(dirname "$1")"
  printf 'third-party content\n' > "$1"
}

# multi-line-pack: recorded only, over several lines, and no submodule file of its own.
seed "$EXT/multi-line-pack/SKILL.md"
seed "$EXT/multi-line-pack/nested/one/README.md"
seed "$EXT/multi-line-pack/nested/one/deep/payload.js"
seed "$EXT/multi-line-pack/nested/two/README.md"
seed "$EXT/multi-line-pack/deeper/three/four/README.md"
# Decoy: a sibling of a pruned path, and a prefix of one. Neither is a submodule.
seed "$EXT/multi-line-pack/nested/keep-me/notes.md"
seed "$EXT/multi-line-pack/deeper/three/keep-me.md"

# inline-pack: the single-line shape, recorded and also declared by the pack.
seed "$EXT/inline-pack/SKILL.md"
seed "$EXT/inline-pack/vendor/thirdparty/LICENSE"
cat > "$EXT/inline-pack/.gitmodules" <<'GM'
[submodule "vendor/thirdparty"]
	path = vendor/thirdparty
	url = https://example.invalid/thirdparty.git
GM

# unrecorded-pack: declares its own submodules, and the registry has never heard of it.
seed "$EXT/unrecorded-pack/SKILL.md"
seed "$EXT/unrecorded-pack/skill/borrowed/SKILL.md"
seed "$EXT/unrecorded-pack/eval-harness/run.sh"
seed "$EXT/unrecorded-pack/own-code/keep-me.ts"
cat > "$EXT/unrecorded-pack/.gitmodules" <<'GM'
[submodule "skill/borrowed"]
	path = skill/borrowed
	url = https://example.invalid/borrowed.git
[submodule "eval-harness"]
	path = eval-harness
	url = https://example.invalid/harness.git
GM

# escape-pack: both sources point outside ext/. Nothing may be deleted on its account.
seed "$EXT/escape-pack/SKILL.md"
cat > "$EXT/escape-pack/.gitmodules" <<'GM'
[submodule "escape"]
	path = ../../../../escaped-by-gitmodules
	url = https://example.invalid/escape.git
GM
seed "$PROJ_DIR/escaped-by-gitmodules/keep-me.md"
seed "$PROJ_DIR/escaped-by-registry/keep-me.md"

# clean-pack: nothing nested at all; it must come through untouched.
seed "$EXT/clean-pack/SKILL.md"

# --- Guard: the fixture is actually there before the run --------------------
# Without this the "removed" assertions below would pass against a fixture that never
# got written, which is the failure mode that let the real defect sit unnoticed.
echo "[fixture]"
assert_dir_exists "$EXT/multi-line-pack/nested/one" "fixture: multi-line nested path present before update"
assert_dir_exists "$EXT/inline-pack/vendor/thirdparty" "fixture: inline nested path present before update"
assert_dir_exists "$EXT/unrecorded-pack/skill/borrowed" "fixture: unrecorded nested path present before update"

# --- Run the real update ----------------------------------------------------
echo ""
echo "[update]"
RUN_LOG="$PROJ_DIR/update-1.log"
RC=0
(cd "$PROJ_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$SRC_DIR" bash .claude/bin/update.sh) > "$RUN_LOG" 2>&1 || RC=$?
TOTAL=$((TOTAL + 1))
if [ "$RC" -eq 0 ]; then
  echo "  PASS: update.sh exits 0 on the fixture project"
  PASS=$((PASS + 1))
else
  echo "  FAIL: update.sh exited $RC on the fixture project"
  sed 's/^/        /' "$RUN_LOG"
  FAIL=$((FAIL + 1))
fi

# --- What the registry record covers ----------------------------------------
echo ""
echo "[recorded over several lines]"
assert_dir_not_exists "$EXT/multi-line-pack/nested/one" "multi-line vendored entry 1 pruned"
assert_dir_not_exists "$EXT/multi-line-pack/nested/two" "multi-line vendored entry 2 pruned"
assert_dir_not_exists "$EXT/multi-line-pack/deeper/three/four" "multi-line vendored entry 3 pruned"
assert_file_not_exists "$EXT/multi-line-pack/nested/one/deep/payload.js" "nothing left under a pruned path"

echo ""
echo "[recorded on one line]"
assert_dir_not_exists "$EXT/inline-pack/vendor/thirdparty" "inline vendored entry pruned"

echo ""
echo "[declared by the pack, recorded nowhere]"
assert_dir_not_exists "$EXT/unrecorded-pack/skill/borrowed" "nested submodule with no registry record pruned"
assert_dir_not_exists "$EXT/unrecorded-pack/eval-harness" "second nested submodule with no registry record pruned"

# --- What must survive ------------------------------------------------------
echo ""
echo "[kept]"
assert_file_exists "$EXT/multi-line-pack/SKILL.md" "the pack itself is kept"
assert_file_exists "$EXT/multi-line-pack/nested/keep-me/notes.md" "a sibling of a pruned path is kept"
assert_file_exists "$EXT/multi-line-pack/deeper/three/keep-me.md" "a file beside a pruned path is kept"
assert_file_exists "$EXT/inline-pack/SKILL.md" "inline-pack itself is kept"
assert_file_exists "$EXT/unrecorded-pack/own-code/keep-me.ts" "the pack's own code is kept"
assert_file_exists "$EXT/clean-pack/SKILL.md" "a pack with nothing nested is kept"
assert_file_exists "$PROJ_DIR/escaped-by-gitmodules/keep-me.md" "a ../ path in a pack's submodule file deletes nothing"
assert_file_exists "$PROJ_DIR/escaped-by-registry/keep-me.md" "a ../ path in the registry record deletes nothing"

# --- It says so -------------------------------------------------------------
echo ""
echo "[reporting]"
assert_file_contains "$RUN_LOG" "[pruned]" "the run reports the prune"
PRUNED_N="$(sed -n 's/.*\[pruned\] \([0-9][0-9]*\) nested.*/\1/p' "$RUN_LOG" | head -1)"
assert_eq "6" "${PRUNED_N:-0}" "the run reports 6 pruned trees (3 multi-line + 1 inline + 2 unrecorded)"

# --- Idempotent: a second run finds nothing left to do ----------------------
echo ""
echo "[second run]"
RUN2_LOG="$PROJ_DIR/update-2.log"
RC2=0
(cd "$PROJ_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$SRC_DIR" bash .claude/bin/update.sh) > "$RUN2_LOG" 2>&1 || RC2=$?
assert_eq "0" "$RC2" "a second update.sh run exits 0"
assert_file_not_contains "$RUN2_LOG" "[pruned]" "a second run prunes nothing"
assert_file_exists "$EXT/multi-line-pack/SKILL.md" "the packs survive a second run"
assert_file_exists "$EXT/unrecorded-pack/own-code/keep-me.ts" "the pack's own code survives a second run"

# --- The prune does not need python3 ----------------------------------------
#
# The per-pack submodule files are parsed in shell, so the primary list survives a host
# with no python3; only the registry's record needs it. Re-seed the fixture, hide
# python3 from PATH and check that the declared-by-the-pack paths still go.
echo ""
echo "[without python3]"
seed "$EXT/unrecorded-pack/skill/borrowed/SKILL.md"
seed "$EXT/unrecorded-pack/eval-harness/run.sh"
# Mirror the whole PATH and leave out just the interpreter, so this is an ordinary run
# minus python3 rather than a hand-listed minimum that quietly drops something else.
NOPY="$PROJ_DIR/no-python-bin"
mkdir -p "$NOPY"
IFS=':' read -r -a PATH_DIRS <<< "$PATH"
for path_dir in "${PATH_DIRS[@]}"; do
  [ -d "$path_dir" ] || continue
  for tool in "$path_dir"/*; do
    [ -f "$tool" ] && [ -x "$tool" ] || continue
    tool_name="$(basename "$tool")"
    case "$tool_name" in python|python2|python2.*|python3|python3.*) continue ;; esac
    [ -e "$NOPY/$tool_name" ] || ln -s "$tool" "$NOPY/$tool_name"
  done
done
TOTAL=$((TOTAL + 1))
if PATH="$NOPY" command -v python3 >/dev/null 2>&1; then
  echo "  FAIL: the no-python3 PATH still finds python3, so the check below proves nothing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: python3 is absent from the stripped PATH"
  PASS=$((PASS + 1))
fi
RC3=0
(cd "$PROJ_DIR" && PATH="$NOPY" SOLANA_AI_KIT_LOCAL_SRC="$SRC_DIR" bash .claude/bin/update.sh) \
  > "$PROJ_DIR/update-3.log" 2>&1 || RC3=$?
assert_eq "0" "$RC3" "update.sh exits 0 with no python3 on PATH"
assert_dir_not_exists "$EXT/unrecorded-pack/skill/borrowed" "pack-declared submodule pruned without python3"
assert_dir_not_exists "$EXT/unrecorded-pack/eval-harness" "second pack-declared submodule pruned without python3"

print_summary
