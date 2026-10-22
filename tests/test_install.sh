#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR" "$WORK"' EXIT

echo "[test_install] Installing to temp directory: $TEMP_DIR"

# Initialize a git repo so submodule commands work
(cd "$TEMP_DIR" && git init -q)

# Run install.sh targeting temp dir (use local source for testing)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR"

echo ""
echo "[test_install] Verifying installation..."

assert_dir_exists "$TEMP_DIR/.claude" ".claude/ directory exists"
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md exists"
assert_eq "### Recurring Issues|### Fix Patterns|### Config Conventions" \
  "$(sed -n '/^## Project Learnings/,/^## [^#]/p' "$TEMP_DIR/CLAUDE.md" 2>/dev/null | grep '^### ' | paste -sd'|' - || true)" \
  "CLAUDE.md has the Project Learnings subsections /dream and /diff-review write to"
# docs/ is the kit's own long-form spec. The copy loop takes named .claude/
# subdirectories plus named root files, so a project must not receive it.
assert_dir_not_exists "$TEMP_DIR/docs" "docs/ is not copied into a project"
assert_file_not_exists "$TEMP_DIR/QUICK-START.md" "QUICK-START.md is not copied into a project"
assert_dir_exists "$TEMP_DIR/.claude/agents" ".claude/agents/ directory exists"
assert_dir_exists "$TEMP_DIR/.claude/commands" ".claude/commands/ directory exists"
assert_file_exists "$TEMP_DIR/.claude/skills/SKILL.md" "SKILL.md exists"
assert_json_valid "$TEMP_DIR/.claude/settings.json" "settings.json is valid JSON"

# Count agents
AGENT_COUNT=$(find "$TEMP_DIR/.claude/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Agent count is 15"

# Count commands
CMD_COUNT=$(find "$TEMP_DIR/.claude/commands" -name "*.md" | wc -l | tr -d ' ')
assert_eq "34" "$CMD_COUNT" "Command count is 34"

# The firewall ships its tier record and its generator; without both, a fresh install has
# a policy nothing can describe or lower.
assert_json_valid "$TEMP_DIR/.claude/security.json" ".claude/security.json is valid JSON"
assert_file_exists "$TEMP_DIR/.claude/bin/firewall.sh" ".claude/bin/firewall.sh is installed"
assert_cmd_success "[ -x '$TEMP_DIR/.claude/bin/firewall.sh' ]" ".claude/bin/firewall.sh is executable"
assert_file_exists "$TEMP_DIR/.claude/commands/firewall.md" "/firewall is installed"
assert_eq "relaxed" "$(python3 -c "
import json; print(json.load(open('$TEMP_DIR/.claude/security.json')).get('tier', '__MISSING__'))" 2>/dev/null)" \
  "a fresh install lands on the relaxed tier"

# Check .gitignore was updated
assert_file_exists "$TEMP_DIR/.gitignore" ".gitignore exists"
GITIGNORE_CONTENT="$(cat "$TEMP_DIR/.gitignore")"
assert_contains "$GITIGNORE_CONTENT" ".claude/skills/ext/" ".gitignore contains ext/ entry"
assert_contains "$GITIGNORE_CONTENT" "CLAUDE.local.md" ".gitignore contains CLAUDE.local.md entry"
assert_contains "$GITIGNORE_CONTENT" ".gitmodules" ".gitignore contains .gitmodules (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" ".mcp.json" ".gitignore contains .mcp.json (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "solana-ai-kit config" ".gitignore has config markers for /commit-claude-config"
# Grok Build reads CLAUDE.md as well as AGENTS.md and skips an instruction file that
# .gitignore lists, so a default install that ignored CLAUDE.md gave Grok no house rules.
# Asked of git rather than of the block, since check-ignore applies every rule that
# matches: a stray CLAUDE.md line anywhere fails it. .mcp.json is the control — still
# ignored, so the 1 is not a missing file.
assert_eq "" "$(config_block "$TEMP_DIR" | grep -xF 'CLAUDE.md' || true)" \
  ".gitignore config block does not list CLAUDE.md"
assert_eq "1" "$(ignore_status "$TEMP_DIR" CLAUDE.md)" \
  "git does not ignore CLAUDE.md (Grok Build skips an ignored instruction file)"
assert_eq "0" "$(ignore_status "$TEMP_DIR" .mcp.json)" \
  "...while the rest of the kit config stays ignored (.mcp.json)"
# CLAUDE.local.md holds private notes, so it stays ignored, from the local-only section:
# /commit-claude-config deletes the marked block, and must not un-ignore it with the rest.
assert_eq "0" "$(ignore_status "$TEMP_DIR" CLAUDE.local.md)" "git ignores CLAUDE.local.md (private notes)"
COMMITTED="$WORK/committed"; mkdir -p "$COMMITTED"; git -C "$COMMITTED" init -q
sed '/# >>> solana-ai-kit config/,/# <<< solana-ai-kit config <<</d' "$TEMP_DIR/.gitignore" > "$COMMITTED/.gitignore"
assert_eq "0" "$(ignore_status "$COMMITTED" CLAUDE.local.md)" \
  "...and still does once /commit-claude-config deletes the config block"

# Check .claude/VERSION exists
assert_file_exists "$TEMP_DIR/.claude/VERSION" ".claude/VERSION file exists"

# Check .claude/bin scripts exist
assert_file_exists "$TEMP_DIR/.claude/bin/update.sh" ".claude/bin/update.sh exists"
assert_file_exists "$TEMP_DIR/.claude/bin/resync.sh" ".claude/bin/resync.sh exists"
assert_file_exists "$TEMP_DIR/.claude/bin/skills.sh" ".claude/bin/skills.sh exists for /add-skill"
assert_file_exists "$TEMP_DIR/.claude/commands/add-skill.md" "/add-skill is installed"

# ── A default install that still lists CLAUDE.md in the gitignore block ──────
# Every default install made before CLAUDE.md left the block still lists it there, so
# Grok Build gets no house rules until it goes. /update and a re-install take it out of
# the marked block only: a CLAUDE.md line the user wrote outside it is theirs to keep,
# and a block that lost its end marker is not a block. The --agents suite runs the same
# cases for AGENTS.md.
echo "[CLAUDE.md leaves an existing default install's gitignore block]"
# install_default <dir> — returns install.sh's exit code; output goes to $WORK/last.log
install_default() { SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$1" >"$WORK/last.log" 2>&1; }
# update_default <dir> [args] — update.sh's output, stderr included
update_default() { (cd "$1" && shift && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@" 2>&1); }
for PREV in "$WORK/prev-update" "$WORK/prev-reinstall"; do
  mkdir -p "$PREV"; git -C "$PREV" init -q
  install_default "$PREV" || true
  add_to_block "$PREV" CLAUDE.md
done
PREV="$WORK/prev-update"
assert_eq "0" "$(ignore_status "$PREV" CLAUDE.md)" "setup: the earlier install's block makes git ignore CLAUDE.md"
cp "$PREV/.gitignore" "$WORK/gitignore.prev"
UPD_OUT="$(update_default "$PREV" --dry-run)" || true
assert_contains "$UPD_OUT" "[would update] .gitignore — CLAUDE.md removed from the kit config block" \
  "update.sh --dry-run reports taking CLAUDE.md out of the block"
assert_cmd_success "cmp -s '$WORK/gitignore.prev' '$PREV/.gitignore'" "...and writes nothing"
UPD_OUT="$(update_default "$PREV")" || true
assert_contains "$UPD_OUT" "[updated] .gitignore — CLAUDE.md removed from the kit config block" \
  "update.sh takes CLAUDE.md out of the block"
assert_eq "1" "$(ignore_status "$PREV" CLAUDE.md)" "...so git no longer ignores CLAUDE.md"
assert_eq "" "$(grep -vxF 'CLAUDE.md' "$WORK/gitignore.prev" | diff - "$PREV/.gitignore" || true)" \
  "...and that line is the only change to .gitignore"
cp "$PREV/.gitignore" "$WORK/gitignore.once"
UPD_OUT="$(update_default "$PREV")" || true
assert_eq "" "$(printf '%s\n' "$UPD_OUT" | grep -F 'CLAUDE.md removed' || true)" "a second update.sh has nothing to remove"
assert_cmd_success "cmp -s '$WORK/gitignore.once' '$PREV/.gitignore'" "...and leaves .gitignore as it was"
# The user's own CLAUDE.md line below the block, on a CRLF checkout (Git for Windows)
add_to_block "$PREV" CLAUDE.md
printf '# mine\nCLAUDE.md\n' >> "$PREV/.gitignore"
awk '{ printf "%s\r\n", $0 }' "$PREV/.gitignore" > "$WORK/gi" && cat "$WORK/gi" > "$PREV/.gitignore"
update_default "$PREV" > "$QUIET_LOG" || quiet_fail "update.sh over a CRLF .gitignore" || true
assert_eq "" "$(config_block "$PREV" | grep -xF 'CLAUDE.md' || true)" "update.sh takes a CRLF CLAUDE.md line out of the block"
assert_eq "1" "$(tr -d '\r' < "$PREV/.gitignore" | grep -cxF 'CLAUDE.md' || true)" \
  "...and keeps the user's own CLAUDE.md line outside it"
# No end marker, so no block: everything after the opening line could be the user's
printf '# >>> solana-ai-kit config — gitignored by default; run /commit-claude-config to version it >>>\n.claude/\nCLAUDE.md\n' > "$PREV/.gitignore"
update_default "$PREV" > "$QUIET_LOG" || quiet_fail "update.sh over an unterminated block" || true
assert_eq "1" "$(grep -cxF 'CLAUDE.md' "$PREV/.gitignore" || true)" "update.sh leaves CLAUDE.md alone when the block has no end marker"
PREV="$WORK/prev-reinstall"
install_default "$PREV" || true
assert_file_contains "$WORK/last.log" "Removed CLAUDE.md from the gitignore config block" \
  "install.sh re-install reports taking CLAUDE.md out of the block"
assert_eq "" "$(config_block "$PREV" | grep -xF 'CLAUDE.md' || true)" "...takes it out"
assert_eq "1" "$(ignore_status "$PREV" CLAUDE.md)" "...so git no longer ignores CLAUDE.md"
add_to_block "$PREV" $'CLAUDE.md\r'
install_default "$PREV" || true
assert_eq "" "$(config_block "$PREV" | grep -xF 'CLAUDE.md' || true)" \
  "a re-install takes a CRLF CLAUDE.md line out of the block"

# An unreachable upstream used to exit 128 with nothing on either stream: under set -e
# with pipefail the failing git ls-remote made its assignment fatal, so the fallback to
# main never ran, and a failed clone was swallowed by `| tail -1 || true`. A file:// URL
# to a path that does not exist fails at once and needs no network.
echo "[unreachable upstream]"
UNREACH="$(new_tmp)" || exit 1
UNREACH_RC=0
SOLANA_AI_KIT_LOCAL_SRC= SOLANA_CLAUDE_LOCAL_SRC= SOLANA_AI_KIT_UPSTREAM="file:///nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$UNREACH" > "$UNREACH/out" 2> "$UNREACH/err" || UNREACH_RC=$?
assert_eq "1" "$UNREACH_RC" "an unreachable upstream exits 1, not 128"
assert_contains "$(cat "$UNREACH/err")" "Could not clone" "an unreachable upstream says why on stderr"
assert_contains "$(cat "$UNREACH/err")" "(main)" "the fallback to main runs when the tag lookup fails"

# A token in SOLANA_AI_KIT_UPSTREAM (a private fork) must not reach the terminal or a CI
# log through our own message; git already keeps it out of its own.
echo "[upstream credentials]"
CREDS="$(new_tmp)" || exit 1
SOLANA_AI_KIT_LOCAL_SRC= SOLANA_CLAUDE_LOCAL_SRC= SOLANA_AI_KIT_UPSTREAM="file://tok3n-s3cr3t@/nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$CREDS" > "$CREDS/out" 2> "$CREDS/err" || true
assert_contains "$(cat "$CREDS/err")" "Could not clone file:///nonexistent/no-such-repo.git" "the failure names the upstream without its credentials"
assert_file_not_contains "$CREDS/err" "tok3n-s3cr3t" "no credential from the upstream URL reaches stderr"
assert_file_not_contains "$CREDS/out" "tok3n-s3cr3t" "no credential from the upstream URL reaches stdout"

# A local source without .claude/ used to fall through to the network clone silently,
# so an install meant to test a local tree installed whatever GitHub served instead.
echo "[local source without .claude/]"
NOSRC="$(new_tmp)" || exit 1
mkdir -p "$NOSRC/src" "$NOSRC/target"
NOSRC_RC=0
SOLANA_AI_KIT_LOCAL_SRC="$NOSRC/src" SOLANA_AI_KIT_UPSTREAM="file:///nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$NOSRC/target" > "$NOSRC/out" 2> "$NOSRC/err" || NOSRC_RC=$?
assert_eq "1" "$NOSRC_RC" "a local source without .claude/ exits 1"
assert_contains "$(cat "$NOSRC/err")" "SOLANA_AI_KIT_LOCAL_SRC=$NOSRC/src has no .claude/" "the refusal names the local source"
assert_file_not_contains "$NOSRC/err" "Could not clone" "it refuses before trying the network"
assert_dir_not_exists "$NOSRC/target/.claude" "nothing is installed"
# The legacy variable is the one named when it is the one set, and a refused install
# leaves nothing behind, not even the target directory.
SOLANA_AI_KIT_LOCAL_SRC= SOLANA_CLAUDE_LOCAL_SRC="$NOSRC/src" SOLANA_AI_KIT_UPSTREAM="file:///nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$NOSRC/target" > /dev/null 2> "$NOSRC/err2" || true
assert_contains "$(cat "$NOSRC/err2")" "SOLANA_CLAUDE_LOCAL_SRC=$NOSRC/src has no .claude/" "the refusal names the legacy variable when that is the one set"
SOLANA_AI_KIT_LOCAL_SRC="$NOSRC/src" SOLANA_AI_KIT_UPSTREAM="file:///nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$NOSRC/never-made" > /dev/null 2>&1 || true
assert_dir_not_exists "$NOSRC/never-made" "a refused install does not create the target"

# A repo can ship .gitignore.tmp as a symlink. The installer's scratch copy must never
# be written through it: the repo's .gitignore text, its author's, would land there.
echo "[.gitignore scratch file]"
VICTIM="$WORK/victim.txt"; printf 'PRECIOUS\n' > "$VICTIM"
grep -vxF '.safe-ai-skill/' "$TEMP_DIR/.gitignore" > "$WORK/gi" && cat "$WORK/gi" > "$TEMP_DIR/.gitignore"
ln -s "$VICTIM" "$TEMP_DIR/.gitignore.tmp"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > /dev/null 2>&1
assert_eq "PRECIOUS" "$(cat "$VICTIM")" "a re-install never writes through a planted .gitignore.tmp symlink"
rm -f "$TEMP_DIR/.gitignore.tmp"

# A last line with no newline would be glued to the next append: `.env.local` then
# `.memsearch/` became `.env.local.memsearch/`, and .env.local stopped being ignored.
echo "[.gitignore without a final newline]"
grep -vxF '.env.local' "$TEMP_DIR/.gitignore" | grep -vxF '.memsearch/' > "$WORK/gi"
{ cat "$WORK/gi"; printf '.env.local'; } > "$TEMP_DIR/.gitignore"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > /dev/null 2>&1
assert_eq "1" "$(grep -cxF '.env.local' "$TEMP_DIR/.gitignore")" "a last line without a newline stays its own line after a re-install"
assert_eq "0" "$(grep -c 'env\.local\.memsearch' "$TEMP_DIR/.gitignore")" "...instead of being glued to the next append"

echo "[.gitignore with CRLF endings]"
# Start from known lines, .memsearch/ among them, so the second assertion can fail too.
{ tr -d '\r' < "$TEMP_DIR/.gitignore" | awk '$0 != ".memsearch/"'; printf '.memsearch/\n'; } | sed 's/$/\r/' > "$WORK/gi"
cat "$WORK/gi" > "$TEMP_DIR/.gitignore"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > /dev/null 2>&1
assert_eq "1" "$(tr -d '\r' < "$TEMP_DIR/.gitignore" | grep -cxF '.env')" "a re-install over a CRLF .gitignore adds no second .env line"
assert_eq "1" "$(tr -d '\r' < "$TEMP_DIR/.gitignore" | grep -cxF '.memsearch/')" "...nor a second .memsearch/ line"

# grep -q stopping at an early match used to kill `tr` with SIGPIPE under pipefail, so a
# large .gitignore whose match came first read as "not found" and got a second line.
echo "[a large .gitignore]"
{ printf '.env.local\n'; seq 1 4000 | sed 's|.*|generated/path-&/|'; tr -d '\r' < "$TEMP_DIR/.gitignore" | awk '$0 != ".env.local"'; } > "$WORK/gi"
cat "$WORK/gi" > "$TEMP_DIR/.gitignore"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > /dev/null 2>&1
assert_eq "1" "$(grep -cxF '.env.local' "$TEMP_DIR/.gitignore")" "a re-install over a large .gitignore whose match comes first adds no second line"

# install.sh, update.sh and skills.sh each print an upstream URL; their redaction must
# not drift apart, and skills.sh's fetch line must not carry credentials either.
echo "[redact_url]"
DEFS="$(for f in install.sh .claude/bin/update.sh .claude/bin/skills.sh; do grep -h '^redact_url()' "$REPO_ROOT/$f" || true; done)"
assert_eq "3" "$(printf '%s\n' "$DEFS" | grep -c '^redact_url()' || true)" "install.sh, update.sh and skills.sh each define redact_url"
assert_eq "1" "$(printf '%s\n' "$DEFS" | sort -u | wc -l | tr -d ' ')" "...identically"
# The two helpers install.sh and update.sh both carry must not drift apart either.
fn_def() {  # fn_def <file> <name>: a one-line definition, or the block up to its closing }
  awk -v f="$2" 'index($0, f "() {") == 1 { print; if ($0 ~ /; }$/) exit; on = 1; next }
    on { print; if ($0 ~ /^}/) exit }' "$1"
}
for fn in end_with_newline missing_schema_blocks; do
  ONE="$(fn_def "$REPO_ROOT/install.sh" "$fn")"
  assert_contains "$ONE" "$fn() {" "install.sh defines $fn"
  assert_eq "$ONE" "$(fn_def "$REPO_ROOT/.claude/bin/update.sh" "$fn")" "...and update.sh defines it identically"
done
SK_OUT="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC= SOLANA_CLAUDE_LOCAL_SRC= SOLANA_AI_KIT_UPSTREAM="file://tok3n-s3cr3t@/nonexistent/no-such-repo.git" bash .claude/bin/skills.sh add jupiter 2>&1 || true)"
assert_contains "$SK_OUT" "Fetching the pinned packs from file:///nonexistent/no-such-repo.git" "skills.sh names the upstream without its credentials"
assert_eq "0" "$(printf '%s' "$SK_OUT" | grep -c 'tok3n-s3cr3t')" "...and never prints them"

print_summary
