#!/usr/bin/env bash
# Sourced by install.sh and skills.sh — never executed on its own.
#
# A vendored skill pack is third-party content sitting inside the user's project tree,
# and part of it loads with no decision from the model and no prompt to the user. Those
# parts are config for developing the pack, in the pack's own repo; in a project that
# merely installed the pack they are an injection channel on paths the kit actively
# tells agents to read. Strip them from the copy that lands in a project.
#
#   <pack>/.claude/  — Claude Code discovers a directory named .claude/skills at ANY
#     depth, so a pack shipping one has its skills listed and invokable in every
#     session: expo ships .claude/skills/expo-skill-eval/, which was observed listed
#     from .claude/skills/ext/expo/.claude/skills. The same directory is where a pack
#     puts rules, agents, settings or hooks of its own (qedgen ships .claude/rules/
#     with paths: "**/*.lean"), so the whole directory goes, not just its skills.
#
# Never run this over the kit's own .claude/skills/ext/ checkout: there the packs are
# live submodules, and deleting a tracked file makes the gitlink dirty and the pin
# checks fail. Callers pass a staging copy or an installed project.
#
# tests/test_pack_load_surfaces.sh holds both halves: that a pin carries no surface the
# kit has not accounted for, and that an installed project carries none at all.

# strip_pack_load_surfaces <pack dir> [<pack dir>...] — remove the auto-loading
# surfaces from each vendored pack. Prints the number removed, so a caller can report
# it; a pack directory that is not there is skipped rather than failing the install.
strip_pack_load_surfaces() {
  local pack found target removed=0
  for pack in "$@"; do
    [ -d "$pack" ] || continue
    # Matched by name, not by -type d: a pack could ship .claude as a symlink, and
    # -prune keeps find out of a directory this loop is about to delete under it.
    # Collected in full before anything is removed, for the same reason.
    found="$(find "$pack" -name .claude -prune -print 2>/dev/null)"
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      rm -rf "${target:?}" && removed=$((removed + 1))
    done <<EOF
$found
EOF
  done
  printf '%s' "$removed"
}
