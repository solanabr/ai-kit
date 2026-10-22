#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install_agents_only] Installing --agents to temp directory: $TEMP_DIR"

# Initialize a git repo so submodule commands work
(cd "$TEMP_DIR" && git init -q)

# Run install.sh in agents-only mode
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$TEMP_DIR"

echo ""
echo "[test_install_agents_only] Verifying --agents installation..."

# .agents/ directory should exist (NOT .claude/)
assert_dir_exists "$TEMP_DIR/.agents" ".agents/ directory exists"

# .claude/ should NOT exist
TOTAL=$((TOTAL + 1))
if [ ! -d "$TEMP_DIR/.claude" ]; then
  echo "  PASS: .claude/ does NOT exist (--agents mode installs to .agents/)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: .claude/ should NOT exist in --agents mode"
  FAIL=$((FAIL + 1))
fi

# All subdirectories should exist in .agents/
assert_dir_exists "$TEMP_DIR/.agents/agents" ".agents/agents/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/commands" ".agents/commands/ directory exists"
assert_dir_exists "$TEMP_DIR/.agents/skills" ".agents/skills/ directory exists"
assert_dir_not_exists "$TEMP_DIR/.agents/rules" ".agents/rules/ not installed (kit ships none)"
assert_dir_exists "$TEMP_DIR/.agents/bin" ".agents/bin/ directory exists"
assert_file_exists "$TEMP_DIR/.agents/skills/SKILL.md" "SKILL.md exists in .agents/"

# --agents mode is unfirewalled, and ships nothing that pretends otherwise. Nothing there
# reads a permission block: Grok reads .claude/settings.json, Codex reads AGENTS.md plus
# .agents/skills/ with hooks in .codex/hooks.json. So the tier record, the generator,
# /firewall and settings.json itself (#160: 22 KB of rules, a sandbox flag and a hooks
# block that no harness parses there) are all skipped, and firewall.sh apply never runs.
assert_file_not_exists "$TEMP_DIR/.agents/settings.json" "no .agents/settings.json (no harness reads it there)"
assert_file_not_exists "$TEMP_DIR/.agents/security.json" "no .agents/security.json (--agents is unfirewalled)"
assert_file_not_exists "$TEMP_DIR/.agents/bin/firewall.sh" "no .agents/bin/firewall.sh"
assert_file_not_exists "$TEMP_DIR/.agents/commands/firewall.md" "no /firewall in --agents mode"
for skipped in "security.json" "settings.json" "bin/firewall.sh" "commands/firewall.md"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$skipped" <<< "$(sed -n 's/^AGENTS_SKIP_FILES=.\(.*\).$/\1/p' "$REPO_ROOT/install.sh")"; then
    echo "  PASS: install.sh AGENTS_SKIP_FILES skips $skipped"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: install.sh AGENTS_SKIP_FILES does not skip $skipped"
    FAIL=$((FAIL + 1))
  fi
done

# Count agents (should match full install)
AGENT_COUNT=$(find "$TEMP_DIR/.agents/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Agent count is 15"

# Count commands (should match full install)
CMD_COUNT=$(find "$TEMP_DIR/.agents/commands" -name "*.md" | wc -l | tr -d ' ')
KIT_CMDS=$(find "$REPO_ROOT/.claude/commands" -name "*.md" | wc -l | tr -d ' ')
# Two commands are Claude-Code-only: /cleanup, and /firewall (it writes a permission
# block that nothing reads under .agents/ — Grok reads .claude/, Codex reads AGENTS.md
# plus .agents/skills/ with its hooks in .codex/hooks.json).
assert_eq "$((KIT_CMDS - 2))" "$CMD_COUNT" "Command count is the kit's minus the two Claude-Code-only commands"

# AGENTS.md (read by Codex and opencode) should exist at project root; CLAUDE.md stays Claude Code's
assert_file_exists "$TEMP_DIR/AGENTS.md" "AGENTS.md exists at project root"
assert_file_not_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md is not written in --agents mode"

# .gitignore should have .agents/skills/ext/ entry
assert_file_exists "$TEMP_DIR/.gitignore" ".gitignore exists"
GITIGNORE_CONTENT="$(cat "$TEMP_DIR/.gitignore")"
assert_contains "$GITIGNORE_CONTENT" ".agents/skills/ext/" ".gitignore contains .agents/skills/ext/ entry"
assert_contains "$GITIGNORE_CONTENT" ".gitmodules" ".gitignore contains .gitmodules (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "solana-ai-kit config" ".gitignore has config markers for /commit-claude-config"

# ── Agents-mode layout checks (CI runs them on ubuntu and macOS via run_all.sh) ──
WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR" "$WORK"' EXIT
export SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" NO_COLOR=1

# install_agents <dir> — returns install.sh's exit code; output goes to $WORK/last.log
install_agents() { bash "$REPO_ROOT/install.sh" --agents "$1" >"$WORK/last.log" 2>&1; }
# config_block, ignore_status and add_to_block live in helpers.sh: test_install.sh asks
# the same questions of a default install.

# Project-relative .claude/ paths would dangle in an agents-mode install (this mode
# never creates .claude/). Intentional ones are skipped: ~/.claude/ and $HOME/.claude/
# (user-global), paths inside the vendored ext/ repos, bin/ (scripts resolve their own
# dir and read the kit repo's .claude/ layout). Files that describe the kit's own
# repo are not installed at all in this mode (install.sh's AGENTS_SKIP_FILES).
CLAUDE_REF='(^|[^[:alnum:]_./~-])\.claude/|CLAUDE_PROJECT_DIR:-[.][}]/\.claude/'
dangling_claude_refs() {
  local d="$1"
  {
    grep -rnE --exclude-dir=ext --exclude-dir=bin "$CLAUDE_REF" \
      "$d/.agents" "$d/AGENTS.md" "$d/.gitmodules" 2>/dev/null || true
    sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$d/.gitignore" 2>/dev/null \
      | grep '\.claude' || true
  } | grep -v '\.agents/' || true
}

# Lines naming BOTH .claude/ and .agents/ are "works in either mode" idioms. The
# rewrite skips them, so dangling_claude_refs cannot see them and a stale .claude/
# inside one would pass unnoticed. Pin the files that hold them: a new file here
# means a new idiom that has to be read and classified by hand.
both_mode_files() {
  grep -rlE --exclude-dir=ext --exclude-dir=bin "$CLAUDE_REF" "$1/.agents" 2>/dev/null \
    | while IFS= read -r f; do
        grep -qE "$CLAUDE_REF" "$f" && grep -q '\.agents/' "$f" && echo "${f#"$1"/.agents/}"
      done | LC_ALL=C sort -u || true
}
skip_value() {
  python3 -c '
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^AGENTS_SKIP_FILES=\x27(.*?)\x27$", s, re.M | re.S)
sys.stdout.write(m.group(1) if m else "<<missing>>")
' "$1"
}
SKIP_FILES_INSTALL="$(skip_value "$REPO_ROOT/install.sh")"
SKIP_FILES_UPDATE="$(skip_value "$REPO_ROOT/.claude/bin/update.sh")"
BOTH_MODE_EXPECTED='commands/add-skill.md
commands/commit-claude-config.md
commands/doctor.md
commands/resync.md
commands/scaffold.md
commands/update.md
skills/skill-registry.json'

# snapshot <dir> [paths...] — checksums of every file (default: whole tree minus .git/)
snapshot() {
  local d="$1"; shift
  if [ "$#" -eq 0 ]; then set -- .; fi
  (cd "$d" && find "$@" -path ./.git -prune -o -type f -exec cksum {} + | LC_ALL=C sort -k3)
}

assert_no_dangling_refs() {
  local refs; refs="$(dangling_claude_refs "$1")"
  TOTAL=$((TOTAL + 1))
  if [ -z "$refs" ]; then
    echo "  PASS: $2"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $2"
    printf '%s\n' "$refs" | head -10 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# Packs a default install carries (skill-registry.json tier "core"). Extensions stay
# registered in .gitmodules but install on demand, recorded in skills/extensions.txt.
CORE_PACKS="$(python3 -c '
import json, sys
reg = json.load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(e["id"] for e in reg["entries"] if e.get("tier") == "core"))
' "$REPO_ROOT/.claude/skills/skill-registry.json")"

assert_submodules_under_agents() {
  local d="$1" paths bad="" p installed no_src=""
  # Every path must sit under .agents/skills/ext/; only installed packs (core plus
  # the extensions this project recorded) must be populated. A pack that is empty in
  # THIS repo installs as an empty folder, so it cannot be expected populated here —
  # that is skipped. A pack whose source is checked out but lands empty is still a
  # failure, which is what catches a copy install.sh got wrong.
  installed=" $CORE_PACKS $(grep -vE '^[[:space:]]*(#|$)' "$d/.agents/skills/extensions.txt" 2>/dev/null | tr '\n' ' ' || true) "
  paths="$(git config -f "$d/.gitmodules" --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')"
  for p in $paths; do
    case "$p" in
      .agents/skills/ext/*)
        case "$installed" in
          *" ${p##*/} "*)
            if [ -z "$(ls -A "$d/$p" 2>/dev/null)" ]; then
              if ext_pack_empty "$REPO_ROOT/.claude/skills/ext/${p##*/}"; then
                no_src="$no_src ${p##*/}"
              else
                bad="$bad $p(empty)"
              fi
            fi
            ;;
        esac ;;
      *) bad="$bad $p" ;;
    esac
  done
  [ -z "$no_src" ] || skip "$2: not checked out in this repo, so not expected populated:$no_src"
  assert_eq "$(git config -f "$REPO_ROOT/.gitmodules" --get-regexp '\.path$' | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$paths" | grep -c .)" "$2: every kit submodule is registered"
  assert_eq "" "$bad" "$2: .gitmodules paths are under .agents/skills/ext/ and installed packs are populated"
  assert_eq "0" "$(find "$d/.agents/skills/ext" -name .git -type f | wc -l | tr -d ' ')" \
    "$2: no dangling submodule gitfiles in .agents/skills/ext/"
}

echo "[instruction file + paths]"
# Generic, not tied to CLAUDE-solana.md's wording: the only differences allowed are
# .claude/ -> .agents/ path rewrites and the removal of HTML comments (Codex and
# opencode do not strip those, so they would reach the model as instructions).
# Independent oracle: a regex engine, not a second copy of the shipped awk. Copying
# the implementation here would make the comparison below assert nothing.
strip_comments_norm() {
  python3 -c '
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
out, prev_blank = [], False
for line in s.split("\n"):
    if line.strip():
        out.append(line); prev_blank = False
    elif not prev_blank:
        out.append(""); prev_blank = True
sys.stdout.write("\n".join(out).rstrip("\n") + "\n")
' "$1"
}
# drop trailing blank lines on both sides: they carry no meaning in markdown and
# the awk keeps one where the oracle does not.
trim_trailing_blanks() { awk 'NF { last = NR } { line[NR] = $0 } END { for (i = 1; i <= last; i++) print line[i] }'; }
sed 's#\.agents/#.claude/#g' "$TEMP_DIR/AGENTS.md" 2>/dev/null | trim_trailing_blanks > "$WORK/agents-md.norm" || true
strip_comments_norm "$REPO_ROOT/CLAUDE-solana.md" | sed 's#\.agents/#.claude/#g' | trim_trailing_blanks > "$WORK/claude-solana-md.norm"
assert_cmd_success "cmp -s '$WORK/agents-md.norm' '$WORK/claude-solana-md.norm'" \
  "AGENTS.md is CLAUDE-solana.md with only path rewrites and comments stripped"
assert_eq "" "$(grep -n '<!--\|-->' "$TEMP_DIR/AGENTS.md" || true)" \
  "AGENTS.md carries no HTML comments (Codex reads them as instructions)"
# /dream and /diff-review write into these; the stripped comment must not have been the only structure.
assert_eq "### Recurring Issues|### Fix Patterns|### Config Conventions" \
  "$(sed -n '/^## Project Learnings/,/^## [^#]/p' "$TEMP_DIR/AGENTS.md" 2>/dev/null | grep '^### ' | paste -sd'|' - || true)" \
  "AGENTS.md keeps the Project Learnings subsections after comment stripping"
assert_eq "" "$(grep -nE "$CLAUDE_REF" "$TEMP_DIR/AGENTS.md" | grep -v '\.agents/' || true)" \
  "AGENTS.md has no dangling .claude/ path"
# Grok Build skips an instruction file that .gitignore lists, so an --agents install
# that ignored AGENTS.md gave Grok no house rules. Asked of git rather than of the block,
# since check-ignore applies every rule that matches: a stray AGENTS.md line anywhere
# fails it. .mcp.json is the control — still ignored, so the 1 is not a missing file.
assert_eq "" "$(config_block "$TEMP_DIR" | grep -xF 'AGENTS.md' || true)" \
  ".gitignore config block does not list AGENTS.md"
assert_eq "1" "$(ignore_status "$TEMP_DIR" AGENTS.md)" \
  "git does not ignore AGENTS.md (Grok Build skips an ignored instruction file)"
assert_eq "0" "$(ignore_status "$TEMP_DIR" .mcp.json)" \
  "...while the rest of the kit config stays ignored (.mcp.json)"
assert_no_dangling_refs "$TEMP_DIR" "no dangling .claude/ references in the installed tree"
assert_eq "$BOTH_MODE_EXPECTED" "$(both_mode_files "$TEMP_DIR")" \
  "only the known both-mode files keep a .claude/ path (new ones need classifying)"
# CLAUDE_REF only matches the .claude/ DIRECTORY. The bare instruction filename is a
# separate class: a file telling Codex to read or write CLAUDE.md names a file that
# mode never creates. Lines naming AGENTS.md too are fine; CLAUDE-solana.md is the source.
#
# skill-registry.json is exempt because it is data, not instructions. It catalogues
# third-party packs and about twenty of them ship a root CLAUDE.md that an agent working
# inside the pack directory picks up, so the safety prose has to be free to say so. #217
# went red on exactly that and rewrote the two offending strings instead of this predicate,
# which leaves the next pack scan that names the file red again for describing a hazard.
#
# Python rather than piped greps because the AGENTS.md exemption has to read the LINE, not
# grep's "path:lineno:" prefix. It read the prefix: every hit inside AGENTS.md carried
# AGENTS.md in its own path and was dropped unread, so that half of the check could not fail.
BARE_CLAUDE_MD="$(python3 - "$TEMP_DIR" <<'PY'
import os, re, sys
root = sys.argv[1]
BARE = re.compile(r"(^|[^.~/A-Za-z0-9])CLAUDE(\.local)?\.md")
targets = [os.path.join(root, "AGENTS.md")]
for base, dirs, files in os.walk(os.path.join(root, ".agents")):
    dirs[:] = [d for d in dirs if d not in ("ext", "bin")]
    targets += [os.path.join(base, f) for f in files]
for path in sorted(targets):
    if os.path.basename(path) == "skill-registry.json":
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    for n, line in enumerate(text.splitlines(), 1):
        if BARE.search(line) and "AGENTS.md" not in line and "CLAUDE-solana.md" not in line:
            print(f"{os.path.relpath(path, root)}:{n}: {line.strip()}")
PY
)"
assert_eq "" "$BARE_CLAUDE_MD" "nothing points Codex at a bare CLAUDE.md without also naming AGENTS.md"
assert_eq "$SKIP_FILES_INSTALL" "$SKIP_FILES_UPDATE" \
  "AGENTS_SKIP_FILES is identical in install.sh and bin/update.sh"
assert_file_not_exists "$TEMP_DIR/.agents/commands/cleanup.md" \
  "/cleanup is not installed in --agents mode (it describes a Claude Code fork flow)"
assert_file_exists "$TEMP_DIR/.agents/commands/add-skill.md" \
  "/add-skill is installed in --agents mode (it resolves .claude/bin or .agents/bin)"
assert_file_exists "$TEMP_DIR/.agents/bin/skills.sh" ".agents/bin/skills.sh exists for /add-skill"
assert_contains "$(cat "$TEMP_DIR/.agents/commands/commit-claude-config.md")" 'INSTR_FILE' \
  "/commit-claude-config resolves the instruction file so it stages AGENTS.md"
assert_submodules_under_agents "$TEMP_DIR" "fresh install"

# ── Idempotent re-install ───────────────────────────────────────────────────
echo "[idempotent re-install]"
snapshot "$TEMP_DIR" > "$WORK/before.txt"
assert_cmd_success "install_agents '$TEMP_DIR'" "second install.sh --agents exits 0"
snapshot "$TEMP_DIR" > "$WORK/after.txt"
assert_cmd_success "diff '$WORK/before.txt' '$WORK/after.txt'" "second install changes no file"
assert_file_not_exists "$TEMP_DIR/AGENTS.md.bak" "no AGENTS.md.bak when AGENTS.md is unchanged"

# ── Next to an existing Claude Code setup ───────────────────────────────────
echo "[existing .claude/]"
WITH_CLAUDE="$WORK/with-claude"; mkdir -p "$WITH_CLAUDE/.claude/agents"; git -C "$WITH_CLAUDE" init -q
echo '{"user_custom": true}' > "$WITH_CLAUDE/.claude/settings.json"
echo "# my agent" > "$WITH_CLAUDE/.claude/agents/mine.md"
echo "# my Claude Code instructions" > "$WITH_CLAUDE/CLAUDE.md"
BEFORE="$(snapshot "$WITH_CLAUDE" .claude CLAUDE.md)"
assert_cmd_success "install_agents '$WITH_CLAUDE'" "install.sh --agents next to .claude/ exits 0"
assert_eq "$BEFORE" "$(snapshot "$WITH_CLAUDE" .claude CLAUDE.md)" ".claude/ and CLAUDE.md are left untouched"
assert_file_not_exists "$WITH_CLAUDE/CLAUDE.md.bak" "no CLAUDE.md.bak (CLAUDE.md is not replaced)"
assert_file_exists "$WITH_CLAUDE/AGENTS.md" "AGENTS.md installed next to .claude/"
assert_no_dangling_refs "$WITH_CLAUDE" "no dangling .claude/ references next to .claude/"

# ── Existing .agents/ (e.g. the user's own Codex skills), AGENTS.md, .gitmodules ──
echo "[existing .agents/]"
WITH_AGENTS="$WORK/with-agents"; mkdir -p "$WITH_AGENTS/.agents/skills/my-skill"; git -C "$WITH_AGENTS" init -q
printf -- '---\nname: my-skill\ndescription: mine\n---\n' > "$WITH_AGENTS/.agents/skills/my-skill/SKILL.md"
echo "# my AGENTS.md" > "$WITH_AGENTS/AGENTS.md"
printf '[submodule "vendor/lib"]\n\tpath = vendor/lib\n\turl = https://example.com/lib.git\n' > "$WITH_AGENTS/.gitmodules"
assert_cmd_success "install_agents '$WITH_AGENTS'" "install.sh --agents over an existing .agents/ exits 0"
assert_file_contains "$WITH_AGENTS/.agents/skills/my-skill/SKILL.md" "name: my-skill" "user's own skill preserved"
assert_file_contains "$WITH_AGENTS/AGENTS.md.bak" "my AGENTS.md" "user's AGENTS.md backed up to AGENTS.md.bak"
assert_cmd_success "cmp -s '$TEMP_DIR/AGENTS.md' '$WITH_AGENTS/AGENTS.md'" "AGENTS.md replaced with the kit's"
assert_file_contains "$WITH_AGENTS/.gitmodules" 'path = vendor/lib' "user's own .gitmodules entry preserved"
assert_eq "$(git config -f "$REPO_ROOT/.gitmodules" --get-regexp '\.path$' | wc -l | tr -d ' ')" \
  "$(git config -f "$WITH_AGENTS/.gitmodules" --get-regexp '\.path$' | grep -c ' \.agents/skills/ext/')" \
  "every kit submodule merged into an existing .gitmodules"

# ── update.sh and resync.sh from .agents/bin ────────────────────────────────
echo "[update.sh + resync.sh]"
if DRY_OUT="$(cd "$TEMP_DIR" && bash .agents/bin/update.sh --dry-run 2>&1)"; then RC=0; else RC=$?; fi
assert_eq "0" "$RC" "update.sh --dry-run exits 0"
assert_contains "$DRY_OUT" "DRY RUN" "update.sh --dry-run reports a dry run"
assert_cmd_success "cd '$TEMP_DIR' && bash .agents/bin/update.sh" "update.sh exits 0"
assert_dir_not_exists "$TEMP_DIR/.claude" "update.sh does not create .claude/"
assert_file_not_exists "$TEMP_DIR/CLAUDE.md" "update.sh does not create CLAUDE.md"
assert_file_not_exists "$TEMP_DIR/AGENTS.md.upstream" "no AGENTS.md.upstream when AGENTS.md matches upstream"
assert_no_dangling_refs "$TEMP_DIR" "no dangling .claude/ references after update.sh"
assert_submodules_under_agents "$TEMP_DIR" "after update.sh"

if RESYNC_OUT="$(cd "$WORK" && bash "$TEMP_DIR/.agents/bin/resync.sh" 2>&1)"; then RC=0; else RC=$?; fi
assert_eq "0" "$RC" "resync.sh exits 0 (run from another cwd)"
# A core pack that is not checked out installs as an empty folder, so resync.sh reports
# every link into it as MISSING. tests/test_resync.sh covers the report itself.
if ext_packs_uninitialized; then
  skip "resync.sh resolves every SKILL.md path (core packs are not checked out)"
else
  assert_contains "$RESYNC_OUT" "All skill paths resolve correctly." "resync.sh resolves every SKILL.md path"
fi
assert_dir_not_exists "$TEMP_DIR/.claude" "resync.sh does not create .claude/"

# ── Not a git repository ────────────────────────────────────────────────────
echo "[non-git directory]"
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
assert_cmd_success "install_agents '$NOGIT'" "install.sh --agents exits 0 outside git"
assert_no_dangling_refs "$NOGIT" "no dangling .claude/ references outside git"
assert_cmd_success "cd '$NOGIT' && bash .agents/bin/update.sh" "update.sh exits 0 outside git"
if RESYNC_OUT="$(cd "$NOGIT" && bash .agents/bin/resync.sh 2>&1)"; then RC=0; else RC=$?; fi
assert_eq "0" "$RC" "resync.sh exits 0 outside git"
assert_contains "$RESYNC_OUT" "Not a git repository" "resync.sh explains it skipped the submodule update"
assert_dir_not_exists "$NOGIT/.claude" "nothing written under .claude/ outside git"

# ── Upgrade an install made by an older --agents installer ──────────────────
# Older installers wrote CLAUDE.md (and listed it in the gitignore block), kept
# .claude/skills/ext/ paths in .gitmodules, copied dangling submodule gitfiles and
# shipped the Claude-Code-only /cleanup.
echo "[upgrade from an older --agents install]"
for OLD in "$WORK/old-update" "$WORK/old-reinstall"; do
  mkdir -p "$OLD"; git -C "$OLD" init -q
  install_agents "$OLD" || true
  mv "$OLD/AGENTS.md" "$OLD/CLAUDE.md" 2>/dev/null || true
  sed 's#\.agents/skills/ext/#.claude/skills/ext/#g' "$OLD/.gitmodules" > "$WORK/gm" && cat "$WORK/gm" > "$OLD/.gitmodules"
  add_to_block "$OLD" CLAUDE.md
  echo "gitdir: ../../../../.git/modules/.claude/skills/ext/solana-dev" > "$OLD/.agents/skills/ext/solana-dev/.git" 2>/dev/null || true
  cp "$REPO_ROOT/.claude/commands/cleanup.md" "$OLD/.agents/commands/cleanup.md"
  # and every install before #160 wrote an .agents/settings.json nothing reads
  cp "$REPO_ROOT/.claude/settings.json" "$OLD/.agents/settings.json"
done
UPD_OUT="$(cd "$WORK/old-update" && bash .agents/bin/update.sh 2>&1)" && RC=0 || RC=$?
assert_eq "0" "$RC" "update.sh upgrades an older --agents install"
assert_contains "$UPD_OUT" "[removed] .agents/settings.json" "update.sh reports removing the older install's settings.json"
assert_cmd_success "install_agents '$WORK/old-reinstall'" "install.sh --agents re-install upgrades an older --agents install"
assert_file_contains "$WORK/last.log" "Removed .agents/commands/cleanup.md" \
  "install.sh --agents reports removing the older install's /cleanup"
assert_file_contains "$WORK/last.log" "Removed .agents/settings.json" \
  "install.sh --agents reports removing the older install's settings.json"
for OLD in "$WORK/old-update" "$WORK/old-reinstall"; do
  NAME="$(basename "$OLD")"
  assert_file_not_exists "$OLD/.agents/commands/cleanup.md" "$NAME: the older install's /cleanup is removed"
  assert_file_not_exists "$OLD/.agents/settings.json" "$NAME: the older install's settings.json is removed"
  assert_file_exists "$OLD/AGENTS.md" "$NAME: AGENTS.md created"
  assert_eq "" "$(config_block "$OLD" | grep -xF 'AGENTS.md' || true)" \
    "$NAME: AGENTS.md is not added to the .gitignore config block"
  assert_eq "1" "$(ignore_status "$OLD" AGENTS.md)" "$NAME: git does not ignore the AGENTS.md it created"
  assert_submodules_under_agents "$OLD" "$NAME"
done

# ── .agents/ as a symlink to .claude/ ───────────────────────────────────────
# The skip-file removal deletes by path under .agents/, so with the two directories
# being one it would delete Claude Code's live settings.json and firewall. It must not.
echo "[.agents/ -> .claude/]"
LINKED="$WORK/linked"; mkdir -p "$LINKED/.claude/bin"; git -C "$LINKED" init -q
ln -s .claude "$LINKED/.agents"
echo '{"user_custom": true}' > "$LINKED/.claude/settings.json"
echo '{"tier": "high"}' > "$LINKED/.claude/security.json"
echo '# firewall' > "$LINKED/.claude/bin/firewall.sh"
install_agents "$LINKED" || true
for f in settings.json security.json bin/firewall.sh; do
  assert_file_exists "$LINKED/.claude/$f" "install.sh --agents through a symlinked .agents/ keeps .claude/$f"
done
assert_file_contains "$LINKED/.claude/settings.json" "user_custom" "...and .claude/settings.json is unchanged"
(cd "$LINKED" && bash .agents/bin/update.sh > "$WORK/linked-update.log" 2>&1) || true
for f in settings.json security.json; do
  assert_file_exists "$LINKED/.claude/$f" "update.sh through a symlinked .agents/ keeps .claude/$f"
done

# ── Codex's skill budget (#212) ─────────────────────────────────────────────
# skills.sh budget warns once an --agents install registers more SKILL.md files than
# Codex's shared description budget holds. Driven against a scratch config dir so the
# count is exact whatever packs this checkout has populated.
echo "[codex skill budget]"
budget_dir() {  # budget_dir <dir> <config name> <skills> — a config dir with N skills
  local d="$1/$2" i
  mkdir -p "$d/bin" "$d/skills"
  cp "$REPO_ROOT/.claude/bin/skills.sh" "$REPO_ROOT/.claude/bin/_pack_strip.sh" "$d/bin/"
  for i in $(seq 1 "$3"); do mkdir -p "$d/skills/ext/p/s$i"; echo "---" > "$d/skills/ext/p/s$i/SKILL.md"; done
}
LIMIT="$(sed -n 's/^CODEX_SKILL_LIMIT=\([0-9]*\)$/\1/p' "$REPO_ROOT/.claude/bin/skills.sh")"
assert_cmd_success "[ -n '$LIMIT' ] && [ '$LIMIT' -gt 0 ]" "skills.sh declares CODEX_SKILL_LIMIT"
budget_dir "$WORK/b-at" .agents "$LIMIT"
budget_dir "$WORK/b-over" .agents "$((LIMIT + 1))"
budget_dir "$WORK/b-claude" .claude "$((LIMIT + 1))"
budget_dir "$WORK/b-dot" .agents "$LIMIT"
mkdir -p "$WORK/b-dot/.agents/skills/ext/p/.hidden/s"; echo "---" > "$WORK/b-dot/.agents/skills/ext/p/.hidden/s/SKILL.md"
assert_eq "" "$(bash "$WORK/b-at/.agents/bin/skills.sh" budget 2>&1)" "budget is silent at the limit"
OVER="$(bash "$WORK/b-over/.agents/bin/skills.sh" budget 2>&1 >/dev/null)"
assert_contains "$OVER" "$((LIMIT + 1)) skills are registered from .agents/skills/" "budget warns on stderr one past the limit"
assert_contains "$OVER" "bash .agents/bin/skills.sh prune" "...and names the way to remove an extension"
assert_eq "" "$(bash "$WORK/b-claude/.claude/bin/skills.sh" budget 2>&1)" "budget never warns for a .claude/ install"
assert_eq "" "$(bash "$WORK/b-dot/.agents/bin/skills.sh" budget 2>&1)" "a SKILL.md inside a dot-directory is not counted"
assert_contains "$(sed -n '/^cmd_add()/,/^}/p' "$REPO_ROOT/.claude/bin/skills.sh")" "cmd_budget" "skills.sh add runs the budget check"
assert_contains "$(sed -n '/^cmd_prune()/,/^}/p' "$REPO_ROOT/.claude/bin/skills.sh")" "cmd_budget" "skills.sh prune (/update) runs the budget check"
assert_file_contains "$REPO_ROOT/install.sh" 'skills.sh" budget' "install.sh --agents runs the budget check"

# ── An --agents install that still lists AGENTS.md in the gitignore block ─────
# Every --agents install made before AGENTS.md left the block still lists it there, so
# Grok Build gets no house rules until it goes. /update and a re-install take it out of
# the marked block only: an AGENTS.md line the user wrote outside it is theirs to keep,
# and a block that lost its end marker is not a block.
echo "[AGENTS.md leaves an existing --agents install's gitignore block]"
for PREV in "$WORK/prev-update" "$WORK/prev-reinstall"; do
  mkdir -p "$PREV"; git -C "$PREV" init -q
  install_agents "$PREV" || true
  add_to_block "$PREV" AGENTS.md
done
PREV="$WORK/prev-update"
assert_eq "0" "$(ignore_status "$PREV" AGENTS.md)" "setup: the earlier install's block makes git ignore AGENTS.md"
cp "$PREV/.gitignore" "$WORK/gitignore.prev"
UPD_OUT="$(cd "$PREV" && bash .agents/bin/update.sh --dry-run 2>&1)" || true
assert_contains "$UPD_OUT" "[would update] .gitignore — AGENTS.md removed from the kit config block" \
  "update.sh --dry-run reports taking AGENTS.md out of the block"
assert_cmd_success "cmp -s '$WORK/gitignore.prev' '$PREV/.gitignore'" "...and writes nothing"
UPD_OUT="$(cd "$PREV" && bash .agents/bin/update.sh 2>&1)" || true
assert_contains "$UPD_OUT" "[updated] .gitignore — AGENTS.md removed from the kit config block" \
  "update.sh takes AGENTS.md out of the block"
assert_eq "1" "$(ignore_status "$PREV" AGENTS.md)" "...so git no longer ignores AGENTS.md"
assert_eq "" "$(grep -vxF 'AGENTS.md' "$WORK/gitignore.prev" | diff - "$PREV/.gitignore" || true)" \
  "...and that line is the only change to .gitignore"
cp "$PREV/.gitignore" "$WORK/gitignore.once"
UPD_OUT="$(cd "$PREV" && bash .agents/bin/update.sh 2>&1)" || true
assert_eq "" "$(printf '%s\n' "$UPD_OUT" | grep -F 'AGENTS.md removed' || true)" "a second update.sh has nothing to remove"
assert_cmd_success "cmp -s '$WORK/gitignore.once' '$PREV/.gitignore'" "...and leaves .gitignore as it was"
# The user's own AGENTS.md line below the block, on a CRLF checkout (Git for Windows)
add_to_block "$PREV" AGENTS.md
printf '# mine\nAGENTS.md\n' >> "$PREV/.gitignore"
awk '{ printf "%s\r\n", $0 }' "$PREV/.gitignore" > "$WORK/gi" && cat "$WORK/gi" > "$PREV/.gitignore"
(cd "$PREV" && bash .agents/bin/update.sh > "$QUIET_LOG" 2>&1) || quiet_fail "update.sh over a CRLF .gitignore" || true
assert_eq "" "$(config_block "$PREV" | grep -xF 'AGENTS.md' || true)" "update.sh takes a CRLF AGENTS.md line out of the block"
assert_eq "1" "$(tr -d '\r' < "$PREV/.gitignore" | grep -cxF 'AGENTS.md' || true)" \
  "...and keeps the user's own AGENTS.md line outside it"
# No end marker, so no block: everything after the opening line could be the user's
printf '# >>> solana-ai-kit config — gitignored by default; run /commit-claude-config to version it >>>\n.agents/\nAGENTS.md\n' > "$PREV/.gitignore"
(cd "$PREV" && bash .agents/bin/update.sh > "$QUIET_LOG" 2>&1) || quiet_fail "update.sh over an unterminated block" || true
assert_eq "1" "$(grep -cxF 'AGENTS.md' "$PREV/.gitignore" || true)" "update.sh leaves AGENTS.md alone when the block has no end marker"
PREV="$WORK/prev-reinstall"
install_agents "$PREV" || true
assert_file_contains "$WORK/last.log" "Removed AGENTS.md from the gitignore config block" \
  "install.sh --agents re-install reports taking AGENTS.md out of the block"
assert_eq "" "$(config_block "$PREV" | grep -xF 'AGENTS.md' || true)" "...takes it out"
assert_eq "1" "$(ignore_status "$PREV" AGENTS.md)" "...so git no longer ignores AGENTS.md"

# ── Reinstall into a git worktree keeps real submodule gitfiles ──────────────
# A submodule's gitdir lives under the repo's git COMMON dir, which sits outside
# the project when the project is a linked worktree. Matching only "inside the
# target" deletes live submodules there.
echo "[git worktree target]"
WT_ROOT="$(new_tmp)" || exit 1
git init -q "$WT_ROOT/main"
git -C "$WT_ROOT/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WT_ROOT/main" worktree add -q "$WT_ROOT/wt" -b wtb
mkdir -p "$WT_ROOT/wt/.agents/skills/ext/mysub" "$WT_ROOT/main/.git/worktrees/wt/modules/mysub"
printf 'gitdir: ../../../../../main/.git/worktrees/wt/modules/mysub\n' \
  > "$WT_ROOT/wt/.agents/skills/ext/mysub/.git"
install_agents "$WT_ROOT/wt" || true
assert_file_exists "$WT_ROOT/wt/.agents/skills/ext/mysub/.git" \
  "reinstall into a git worktree keeps a real submodule gitfile"
bash "$WT_ROOT/wt/.agents/bin/update.sh" >/dev/null 2>&1 || true
assert_file_exists "$WT_ROOT/wt/.agents/skills/ext/mysub/.git" \
  "update.sh in a git worktree keeps a real submodule gitfile"
rm -rf "$WT_ROOT"


# ── Dual install: .agents/ must join an existing .claude/ gitignore block ────
echo "[dual install gitignore]"
DUAL="$(new_tmp)" || exit 1
(cd "$DUAL" && git init -q)
bash "$REPO_ROOT/install.sh" "$DUAL" >/dev/null 2>&1 || true
install_agents "$DUAL" || true
DUAL_BLOCK="$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$DUAL/.gitignore")"
assert_contains "$DUAL_BLOCK" ".agents/" "dual install gitignores .agents/ too"
assert_eq "" "$(config_block "$DUAL" | grep -xF 'AGENTS.md' || true)" "dual install leaves AGENTS.md out of the block"
assert_eq "1" "$(ignore_status "$DUAL" AGENTS.md)" "...so git does not ignore it"
assert_eq "" "$(cd "$DUAL" && git status --porcelain --untracked-files=normal | grep '\.agents' || true)" \
  "dual install leaves no untracked .agents/ tree"
rm -rf "$DUAL"

# ── Reverse order: .claude/ must join an existing --agents gitignore block ───
echo "[dual install gitignore, --agents first]"
REV="$WORK/dual-agents-first"; mkdir -p "$REV"; git -C "$REV" init -q
install_agents "$REV" || true
bash "$REPO_ROOT/install.sh" "$REV" >/dev/null 2>&1 || true
for entry in .claude/ .agents/; do
  assert_eq "1" "$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$REV/.gitignore" | grep -cxF "$entry" || true)" \
    "--agents first: $entry is listed once in the gitignore config block"
done
for f in AGENTS.md CLAUDE.md; do
  assert_eq "0" "$(config_block "$REV" | grep -cxF "$f" || true)" \
    "--agents first: $f is not in the gitignore config block"
  assert_eq "1" "$(ignore_status "$REV" "$f")" "--agents first: git does not ignore $f"
done
assert_eq "" "$(cd "$REV" && git status --porcelain --untracked-files=normal | grep -E '\.claude|\.agents' || true)" \
  "--agents first: no kit path left untracked but the two instruction files"
cp "$REV/.gitignore" "$WORK/gitignore.before"
bash "$REPO_ROOT/install.sh" "$REV" >/dev/null 2>&1 || true
install_agents "$REV" || true
assert_cmd_success "cmp -s '$WORK/gitignore.before' '$REV/.gitignore'" "re-running both installs leaves .gitignore unchanged"
# /commit-claude-config deletes the marked block, so every config entry must sit inside it
assert_eq "1 1" "$(grep -c '^# >>> solana-ai-kit config' "$REV/.gitignore") $(grep -c '^# <<< solana-ai-kit config <<<$' "$REV/.gitignore")" \
  "one pair of /commit-claude-config markers"
assert_eq "" "$(sed '/# >>> solana-ai-kit config/,/# <<< solana-ai-kit config <<</d' "$REV/.gitignore" \
    | grep -xE '\.claude/|CLAUDE\.md|\.agents/|AGENTS\.md|\.mcp\.json|\.gitmodules' || true)" \
  "every kit config entry sits inside the /commit-claude-config markers"
# Git for Windows checks a tracked .gitignore out with CRLF endings
awk '{ printf "%s\r\n", $0 }' "$REV/.gitignore" > "$WORK/gitignore.crlf" && cat "$WORK/gitignore.crlf" > "$REV/.gitignore"
bash "$REPO_ROOT/install.sh" "$REV" >/dev/null 2>&1 || true
assert_eq "1" "$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$REV/.gitignore" | tr -d '\r' | grep -cxF '.claude/' || true)" \
  "a CRLF .gitignore gets no second .claude/ entry on re-install"
add_to_block "$REV" $'AGENTS.md\r'
install_agents "$REV" || true
assert_eq "" "$(config_block "$REV" | grep -xF 'AGENTS.md' || true)" \
  "an --agents re-install takes a CRLF AGENTS.md line out of the block"

print_summary
