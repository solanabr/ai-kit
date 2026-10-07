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
#   CLAUDE.md  — read as project instructions for every file an agent touches at or
#     below the directory holding it. 20 of the 45 pinned packs ship one at their
#     root, so one applies to every read anywhere in that pack; reading only
#     <pack>/.gitmodules was enough to inject two packs' instruction bodies into a
#     session, labelled "project instructions, checked into the codebase". Taken at
#     any depth, because the kit routes agents into <pack>/skills/ and
#     get-shit-pretty ships gsp/skills/CLAUDE.md.
#
#   <pack>/AGENTS.md  — the same channel for the harnesses an --agents install serves.
#     Root only: deeper ones are the pack's content for those harnesses rather than
#     its own repo config (huggingface-skills/agentsmd/ is a skill *about* AGENTS.md
#     files, and vercel ships one per skill folder).
#
# claudeMdExcludes in settings.json is not the remedy: install.sh writes that file only
# when it is absent, so a setting there reaches fresh installs only (issue #91).
# Removing the files reaches every install, through update.sh's copy of bin/ and the
# `skills.sh prune` it then runs.
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
    # One pass, and -prune does two jobs: a .claude/ is matched by name rather than by
    # -type d (a pack could ship it as a symlink) and never descended into, so no
    # CLAUDE.md inside one is listed twice, and find is kept out of a directory the
    # loop below is about to delete. Collected in full before anything is removed.
    found="$(find "$pack" \( -name .claude -o -name CLAUDE.md \) -prune -print 2>/dev/null)"
    # 7 of the 20 root CLAUDE.md files are symlinks to the pack's AGENTS.md, so both
    # names go and which of the pair holds the bytes does not matter: AGENTS.md here,
    # the CLAUDE.md link in the loop below, where rm does not care that the link no
    # longer resolves. -L as well as -e, since AGENTS.md can be a link of its own.
    if [ -e "$pack/AGENTS.md" ] || [ -L "$pack/AGENTS.md" ]; then
      rm -f "$pack/AGENTS.md" && removed=$((removed + 1))
    fi
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      rm -rf "${target:?}" && removed=$((removed + 1))
    done <<EOF
$found
EOF
  done
  printf '%s' "$removed"
}
