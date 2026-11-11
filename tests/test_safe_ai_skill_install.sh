#!/usr/bin/env bash
set -euo pipefail

# install.sh installs the safe-ai-skill plugin in a full install. settings.json only
# enables it: Claude Code installs a plugin from an external source only when each user
# runs the install. A fake `claude` first on PATH records every call, and an isolated
# CLAUDE_CONFIG_DIR stands in for Claude Code's install list, so no real install runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_safe_ai_skill_install] install.sh installs the safe-ai-skill plugin"
echo ""

BIN="$TEMP_DIR/bin" && mkdir -p "$BIN"
LOG="$TEMP_DIR/claude.log"
cat > "$BIN/claude" <<'EOF'
#!/bin/sh
printf '%s :: %s\n' "$PWD" "$*" >> "$CLAUDE_FAKE_LOG"
cat >> "$CLAUDE_FAKE_LOG.stdin"
case "$*" in
  "plugin install safe-ai-skill@stbr --scope project")
    if [ -n "${CLAUDE_FAKE_FAIL_FIRST:-}" ] && [ ! -e "$CLAUDE_FAKE_LOG.failed" ]; then
      : > "$CLAUDE_FAKE_LOG.failed"
      echo "Plugin safe-ai-skill not found in marketplace stbr" >&2
      exit 1
    fi
    echo "Successfully installed plugin: safe-ai-skill@stbr (scope: project)" ;;
  "plugin marketplace add "*) echo "Successfully added marketplace: stbr" ;;
  "plugin marketplace update stbr") echo "Successfully updated marketplace: stbr" ;;
  "plugin update safe-ai-skill@stbr --scope "*)
    [ -z "${CLAUDE_FAKE_FAIL_UPDATE:-}" ] || { echo "EACCES: permission denied" >&2; exit 1; }
    echo "safe-ai-skill is already at the latest version (1.3.4)." ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/claude"
# Git Bash on native Windows, which safe-ai-skill ships a build for, and 32-bit ARM
# Linux, which it does not.
WINBIN="$TEMP_DIR/winbin" && mkdir -p "$WINBIN"
printf '#!/bin/sh\n[ "$1" = -s ] && echo MINGW64_NT-10.0-26100 || echo x86_64\n' > "$WINBIN/uname"
chmod +x "$WINBIN/uname"
ARMBIN="$TEMP_DIR/armbin" && mkdir -p "$ARMBIN"
printf '#!/bin/sh\n[ "$1" = -s ] && echo Linux || echo armv7l\n' > "$ARMBIN/uname"
chmod +x "$ARMBIN/uname"

N=0
# run_install [VAR=value ...] -- [install.sh args]: installs into a fresh project and sets
# P to it and OUT to the output. stdin carries a line claude must never read: under
# `curl | bash` the script itself is stdin.
run_install() {
  local vars=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  N=$((N + 1)); P="$TEMP_DIR/p$N"
  mkdir -p "$P" && git -C "$P" init -q
  rm -f "$LOG" "$LOG.stdin" "$LOG.failed"
  OUT="$(printf 'NOT-FOR-CLAUDE\n' | env PATH="$BIN:$PATH" CLAUDE_FAKE_LOG="$LOG" CLAUDE_CONFIG_DIR="$TEMP_DIR/cc$N" \
    SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" ${vars[@]+"${vars[@]}"} bash "$REPO_ROOT/install.sh" "$@" "$P" 2>&1)" || true
}
calls() { [ -f "$LOG" ] && cat "$LOG" || true; }
SAS_CMD="claude plugin install safe-ai-skill@stbr --scope project"

echo "[local source: not installed, command printed]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL= --
assert_eq "" "$(calls)" "A local-source install never calls claude (tests and offline runs)"
assert_contains "$OUT" "safe-ai-skill is enabled but not installed" "...and the closing box says the plugin is not installed"
assert_contains "$OUT" "$SAS_CMD" "...with the command that installs it"

echo "[installed by default]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 --
assert_eq "p$N :: plugin install safe-ai-skill@stbr --scope project" "$(calls | sed -E 's#^.*/([^/]+) :: #\1 :: #')" \
  "install.sh runs claude plugin install safe-ai-skill@stbr --scope project, in the project"
assert_eq "1" "$(calls | wc -l | tr -d ' ')" "...once"
assert_contains "$OUT" "Installed safe-ai-skill" "...reports it"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...and the closing box says so"
assert_eq "" "$(cat "$LOG.stdin" 2>/dev/null || true)" "claude never reads install.sh's stdin"

echo "[marketplace registered on first failure]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 CLAUDE_FAKE_FAIL_FIRST=1 --
assert_contains "$(calls)" "plugin marketplace add https://github.com/solanabr/ai-kit.git" "A failed first install registers the kit's marketplace"
assert_eq "2" "$(calls | grep -c 'plugin install safe-ai-skill@stbr --scope project')" "...then installs again"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...and reports the plugin installed"

echo "[already installed]"
N1=$((N + 1)); mkdir -p "$TEMP_DIR/cc$N1/plugins" "$TEMP_DIR/p$N1"
printf '{"version": 2, "plugins": {"safe-ai-skill@stbr": [{"scope": "project", "projectPath": "%s"}]}}\n' "$TEMP_DIR/p$N1" \
  > "$TEMP_DIR/cc$N1/plugins/installed_plugins.json"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 --
assert_eq "$(printf '%s\n' "p$N1 :: plugin marketplace update stbr" "p$N1 :: plugin update safe-ai-skill@stbr --scope project")" \
  "$(calls | sed -E 's#^.*/([^/]+) :: #\1 :: #')" \
  "A plugin Claude Code already records for this project is not installed again, but moved to the kit's pin"
assert_contains "$OUT" "safe-ai-skill is at the version this kit pins" "...and install.sh says so"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...and is reported installed"
N1=$((N + 1)); mkdir -p "$TEMP_DIR/cc$N1/plugins" "$TEMP_DIR/p$N1"
printf '{"version": 2, "plugins": {"safe-ai-skill@stbr": [{"scope": "user"}]}}\n' > "$TEMP_DIR/cc$N1/plugins/installed_plugins.json"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 CLAUDE_FAKE_FAIL_UPDATE=1 --
assert_contains "$(calls)" "plugin update safe-ai-skill@stbr --scope user" "A user-scope install is updated at user scope"
assert_contains "$OUT" "Could not update safe-ai-skill to the version this kit pins" "...and a failed update says so"
assert_contains "$OUT" "claude plugin update safe-ai-skill@stbr --scope user" "...with the commands to run in a shell"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...while the plugin is still reported installed"
N1=$((N + 1)); mkdir -p "$TEMP_DIR/cc$N1/plugins"
printf '{"version": 2, "plugins": {"safe-ai-skill@stbr": [{"scope": "user"}]}}\n' > "$TEMP_DIR/cc$N1/plugins/installed_plugins.json"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL= --
assert_eq "" "$(calls)" "A local-source install never calls claude, not even to update an install already recorded"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...which is still reported installed"

echo "[--no-safe-ai-skill]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 -- --no-safe-ai-skill
assert_eq "" "$(calls)" "--no-safe-ai-skill skips the plugin install"
assert_contains "$OUT" "safe-ai-skill skipped" "...and the closing box says so, with the command"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=0 --
assert_eq "" "$(calls)" "SOLANA_AI_KIT_SAFE_AI_SKILL=0 skips it too"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=false --
assert_eq "" "$(calls)" "...and so does =false"

echo "[platforms]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 PATH="$WINBIN:$BIN:$PATH" --
assert_contains "$(calls)" "plugin install safe-ai-skill@stbr --scope project" "Git Bash on 64-bit Windows gets the plugin: safe-ai-skill ships a Windows build"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 PATH="$ARMBIN:$BIN:$PATH" --
assert_eq "" "$(calls)" "On a CPU it ships no build for (32-bit ARM Linux), it is not installed"
assert_contains "$OUT" "has no engine build for Linux/armv7l, so its gates would not run there" "...and install.sh names the platform and why"

echo "[update.sh moves the plugin to the kit's pin]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL= --
UP="$P" && CC="$TEMP_DIR/cc-update" && mkdir -p "$CC/plugins" "$TEMP_DIR/sas-install/bin"
: > "$TEMP_DIR/sas-install/bin/safe-ai-skill"
printf '{"version": 2, "plugins": {"safe-ai-skill@stbr": [{"scope": "project", "projectPath": "%s", "installPath": "%s"}]}}\n' \
  "$UP" "$TEMP_DIR/sas-install" > "$CC/plugins/installed_plugins.json"
# run_update [VAR=value ...] -- [update.sh args]: runs the project's update.sh against this checkout.
run_update() {
  local vars=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$LOG" "$LOG.stdin"
  OUT="$(cd "$UP" && printf 'NOT-FOR-CLAUDE\n' | env PATH="$BIN:$PATH" CLAUDE_FAKE_LOG="$LOG" CLAUDE_CONFIG_DIR="$CC" \
    SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" ${vars[@]+"${vars[@]}"} bash .claude/bin/update.sh "$@" 2>&1)" || true
}
SHIM_CMD="\"$TEMP_DIR/sas-install/bin/safe-ai-skill\" verify approve"
run_update --
assert_eq "" "$(calls)" "A local-source update never calls claude"
assert_contains "$OUT" "safe-ai-skill was not updated to the version this kit pins" "...and says the plugin was not updated"
assert_contains "$OUT" "claude plugin marketplace update stbr && claude plugin update safe-ai-skill@stbr --scope project" "...with the commands to run in a shell"
assert_contains "$OUT" "If your next session start lists blocked packs" "A first update, with no earlier pack checksums, says how to approve a changed pack"
assert_contains "$OUT" "$SHIM_CMD .claude/skills/ext/<pack>" "...with the plugin's own shim, since the CLI is not on PATH in a plugin-only install"
assert_file_exists "$UP/.claude/.ext-pack-sums" "...and records each pack's checksum for the next update"
assert_eq "1" "$(grep -cxF '.claude/.ext-pack-sums' "$UP/.gitignore")" "...which stays on this machine: .gitignore lists it once"
grep -vxF '.claude/.ext-pack-sums' "$UP/.gitignore" > "$TEMP_DIR/gitignore" && cp "$TEMP_DIR/gitignore" "$UP/.gitignore"
run_update -- --dry-run
assert_contains "$OUT" "[would run] claude plugin marketplace update stbr && claude plugin update safe-ai-skill@stbr --scope project" "--dry-run names the commands it would run"
run_update SOLANA_AI_KIT_SAFE_AI_SKILL=1 --
assert_eq "$(printf '%s\n' "$(basename "$UP") :: plugin marketplace update stbr" "$(basename "$UP") :: plugin update safe-ai-skill@stbr --scope project")" \
  "$(calls | sed -E 's#^.*/([^/]+) :: #\1 :: #')" "update.sh refreshes the stbr marketplace, then updates the plugin at its scope, in the project"
assert_eq "" "$(printf '%s\n' "$OUT" | grep -F 'safe-ai-skill was not updated' || true)" "...and a plugin already at the pin gets no notice"
assert_eq "" "$(cat "$LOG.stdin" 2>/dev/null || true)" "...and claude never reads update.sh's stdin"
assert_eq "1" "$(grep -cxF '.claude/.ext-pack-sums' "$UP/.gitignore")" "update.sh gitignores the pack checksums in an install whose .gitignore predates them"
run_update SOLANA_AI_KIT_SAFE_AI_SKILL=1 CLAUDE_FAKE_FAIL_UPDATE=1 --
assert_contains "$OUT" "safe-ai-skill was not updated to the version this kit pins" "A failed plugin update (a sandboxed session) is reported"
assert_eq "" "$(printf '%s\n' "$OUT" | grep -F 'skill pack' || true)" "An update that changed no pack names none"
PACK="$(awk 'NR == 1 { print $1 }' "$UP/.claude/.ext-pack-sums")"
if [ -n "$PACK" ]; then
  awk 'NR == 1 { $2 = "0000000000000000000000000000000000000000" } { print }' "$UP/.claude/.ext-pack-sums" > "$TEMP_DIR/sums" \
    && cp "$TEMP_DIR/sums" "$UP/.claude/.ext-pack-sums"
  run_update --
  assert_contains "$OUT" "This update changed these skill packs" "An update that changed a pack says safe-ai-skill blocks it until approved"
  assert_contains "$OUT" "$SHIM_CMD .claude/skills/ext/$PACK" "...with one approve line for that pack"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -cF "$SHIM_CMD" || true)" "...and none for the packs it left alone"
else
  echo "  SKIP: no ext/ pack in this install to change"
fi

echo "[--agents]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 -- --agents
assert_eq "" "$(calls)" "An --agents install never installs it: its hooks are Claude Code only"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c 'Security plugin:' || true)" "...and its closing box does not mention it"

print_summary
