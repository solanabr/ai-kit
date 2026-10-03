#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# new_tmp (helpers.sh) falls back when `mktemp -d` is denied by the sandbox — reproduced
# three times this session. That is the shipped bug this release fixes, so the migration
# tests must not hang off it.
TEMP_DIR="$(new_tmp)" || exit 1
FW_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR" "$FW_DIR"' EXIT

echo "[test_update] Comprehensive update.sh validation"
echo ""

# --- Setup: initial install ---
(cd "$TEMP_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" >/dev/null 2>&1

# --- Run update ---
echo "[basic update]"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1

assert_dir_exists "$TEMP_DIR/.claude" ".claude/ still exists after update"
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md still exists after update"
assert_dir_exists "$TEMP_DIR/.claude/agents" "agents/ preserved"
assert_dir_exists "$TEMP_DIR/.claude/commands" "commands/ preserved"
assert_file_exists "$TEMP_DIR/.claude/skills/SKILL.md" "SKILL.md preserved"
assert_json_valid "$TEMP_DIR/.claude/settings.json" "settings.json still valid"
assert_file_exists "$TEMP_DIR/.claude/VERSION" ".claude/VERSION exists after update"

# --- VERSION is valid semver ---
VERSION_CONTENT="$(cat "$TEMP_DIR/.claude/VERSION")"
TOTAL=$((TOTAL + 1))
if echo "$VERSION_CONTENT" | grep -qE '(^|[[:space:]])[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "  PASS: VERSION content is valid semver ($VERSION_CONTENT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: VERSION content is not valid semver ($VERSION_CONTENT)"
  FAIL=$((FAIL + 1))
fi

# --- Counts after update ---
assert_count "$TEMP_DIR/.claude/agents" "*.md" "15" "Agent count == 15 after update"
assert_count "$TEMP_DIR/.claude/commands" "*.md" "32" "Command count == 32 after update"

# --- Dry-run mode ---
echo "[dry-run]"
DRY_OUTPUT="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run 2>&1)"
assert_contains "$DRY_OUTPUT" "DRY RUN" "--dry-run output contains DRY RUN"

# VERSION should still be valid after dry-run (not corrupted)
VERSION_AFTER="$(cat "$TEMP_DIR/.claude/VERSION")"
assert_eq "$VERSION_CONTENT" "$VERSION_AFTER" "VERSION unchanged after dry-run"

# --- CLAUDE.md.upstream: modify CLAUDE.md, then update ---
echo "[upstream detection]"
echo "# My customized CLAUDE.md" > "$TEMP_DIR/CLAUDE.md"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1

assert_file_exists "$TEMP_DIR/CLAUDE.md.upstream" "CLAUDE.md.upstream created when CLAUDE.md differs"
assert_file_contains "$TEMP_DIR/CLAUDE.md" "My customized" "Original CLAUDE.md not overwritten"

# --- Protected files: .env not overwritten ---
echo "[protected files]"
echo "MY_SECRET=preserved" > "$TEMP_DIR/.env"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_file_contains "$TEMP_DIR/.env" "MY_SECRET=preserved" ".env not overwritten by update"

# --- Retired rules: the kit's old globs: copies go, rules the user wrote stay ---
echo "[retired rules]"
mkdir -p "$TEMP_DIR/.claude/rules"
printf -- '---\nglobs:\n  - "**/*.rs"\n---\n# Rust Code Standards for Solana\n' > "$TEMP_DIR/.claude/rules/rust.md"
printf -- '---\npaths:\n  - "src/**/*.ts"\n---\n# Team API rules\n' > "$TEMP_DIR/.claude/rules/team-api.md"
DRY_RULES="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run 2>&1)"
assert_contains "$DRY_RULES" "[would remove] .claude/rules/rust.md" "--dry-run reports the retired kit rule"
assert_file_exists "$TEMP_DIR/.claude/rules/rust.md" "--dry-run leaves the retired kit rule in place"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_file_not_exists "$TEMP_DIR/.claude/rules/rust.md" "Retired kit rule removed by update"
assert_file_exists "$TEMP_DIR/.claude/rules/team-api.md" "User-written rule kept by update"

# --- Retired kit defaults: what kit <= 2.1.0 wrote into settings.json and .mcp.json ---
echo "[retired kit defaults]"
json_at() {  # json_at <file> <key>... -> the value (JSON for non-strings), or __MISSING__
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k, "__MISSING__") if isinstance(d, dict) else "__MISSING__"
print(d if isinstance(d, str) else json.dumps(d))' "$@"
}
SETTINGS="$TEMP_DIR/.claude/settings.json"
MCP="$TEMP_DIR/.mcp.json"
echo "solana-ai-kit 2.1.0" > "$TEMP_DIR/.claude/VERSION"
# v2.1.0's values for these keys, plus user edits that must survive
python3 -c 'import json, sys
s = json.load(open(sys.argv[1]))
s["env"] = {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_COORDINATOR_MODE": "1",
            "CLAUDE_CODE_EFFORT_LEVEL": "max", "BASH_MAX_OUTPUT_LENGTH": "30000",
            "MAX_MCP_OUTPUT_TOKENS": "25000", "MY_VAR": "keep"}
s["enableAllProjectMcpServers"] = True
s["defaultMode"] = "default"
s["enabledPlugins"] = {"rust-analyzer-lsp@claude-plugins-official": True,
                       "typescript-lsp@claude-plugins-official": True,
                       "csharp-lsp@claude-plugins-official": False,
                       "my-plugin@my-market": True}
s["modelDefaults"] = {"agent": "opus", "command": "sonnet"}
s["includeCoAuthoredBy"] = False
json.dump(s, open(sys.argv[1], "w"), indent=2)
m = json.load(open(sys.argv[2]))
m["mcpServers"].update({
    "playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@latest"]},
    "context-mode": {"command": "npx", "args": ["-y", "context-mode@latest"]},
    "memsearch": {"command": "npx", "args": ["-y", "memsearch-mcp@latest"]},
    "surfpool": {"command": "surfpool", "args": ["mcp"]},
    "my-server": {"command": "my-mcp"}})
json.dump(m, open(sys.argv[2], "w"), indent=2)' "$SETTINGS" "$MCP"

DRY_RETIRED="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run 2>&1)"
assert_contains "$DRY_RETIRED" "[would remove] .claude/settings.json: env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "--dry-run reports the retired settings"
assert_contains "$DRY_RETIRED" "[would remove] .mcp.json: mcpServers.memsearch, mcpServers.surfpool" "--dry-run reports the retired MCP servers"
assert_eq "max" "$(json_at "$SETTINGS" env CLAUDE_CODE_EFFORT_LEVEL)" "--dry-run leaves settings.json alone"

UPDATE_OUT="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh 2>&1)"
assert_contains "$UPDATE_OUT" "[removed] .claude/settings.json:" "update reports what it removed"
assert_json_valid "$SETTINGS" "settings.json still valid JSON after the migration"
for var in CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDE_CODE_COORDINATOR_MODE CLAUDE_CODE_EFFORT_LEVEL \
           BASH_MAX_OUTPUT_LENGTH MAX_MCP_OUTPUT_TOKENS; do
  assert_eq "__MISSING__" "$(json_at "$SETTINGS" env "$var")" "kit env.$var removed"
done
assert_eq "keep" "$(json_at "$SETTINGS" env MY_VAR)" "user env var kept"
for key in enableAllProjectMcpServers defaultMode modelDefaults; do
  assert_eq "__MISSING__" "$(json_at "$SETTINGS" "$key")" "kit $key removed"
done
assert_eq '{"csharp-lsp@claude-plugins-official": false, "my-plugin@my-market": true}' \
  "$(json_at "$SETTINGS" enabledPlugins)" "kit LSP plugins removed; the user's plugin choices kept"
assert_eq "false" "$(json_at "$SETTINGS" includeCoAuthoredBy)" "attribution setting untouched"
assert_eq "true" "$(json_at "$SETTINGS" sandbox enabled)" "sandbox policy untouched"
MCP_LEFT="$(python3 -c "import json; print(' '.join(sorted(json.load(open('$MCP'))['mcpServers'])))")"
assert_eq "context-mode context7 helius my-server playwright solana-dev" "$MCP_LEFT" "kit MCP servers removed; user and user-edited servers kept (context-mode is a default again, so it stays)"

# Idempotent: a second run changes nothing
cp "$SETTINGS" "$TEMP_DIR/settings.before"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_cmd_success "cmp -s '$SETTINGS' '$TEMP_DIR/settings.before'" "second update leaves settings.json unchanged"

# Only installs from kit <= 2.1.0 are migrated: a value set later is the user's choice
echo "solana-ai-kit 2.2.0" > "$TEMP_DIR/.claude/VERSION"
python3 -c 'import json, sys
s = json.load(open(sys.argv[1])); s["enableAllProjectMcpServers"] = True
json.dump(s, open(sys.argv[1], "w"), indent=2)' "$SETTINGS"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_eq "true" "$(json_at "$SETTINGS" enableAllProjectMcpServers)" "newer installs keep the value (migration runs once)"

# --- Only installs on the retired-defaults list are migrated ----------------
# Both version fixtures above are hardcoded, so they pass whatever .claude/VERSION says
# and would keep passing after the migration stopped applying. Pin the shipped version
# against update.sh's own case list instead (issue #126): a release that forgot to drop
# itself from that list would re-run a one-shot migration on every fresh install.
echo "[retired-defaults version window]"
RETIRED_CASE="$(awk '/case "\$CURRENT_VERSION" in/{getline; gsub(/^[[:space:]]+|\)[[:space:]]*$/, ""); print; exit}' \
  "$REPO_ROOT/.claude/bin/update.sh")"
SHIPPED_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/.claude/VERSION" | head -1)"
TOTAL=$((TOTAL + 1))
if [ -z "$RETIRED_CASE" ]; then
  echo "  FAIL: could not read update.sh's retired-defaults case list"
  FAIL=$((FAIL + 1))
else
  MATCHED=no
  IFS='|' read -ra RETIRED_PATTERNS <<< "$RETIRED_CASE"
  for pat in "${RETIRED_PATTERNS[@]}"; do
    case "$SHIPPED_VERSION" in $pat) MATCHED=yes ;; esac
  done
  if [ "$MATCHED" = "no" ]; then
    echo "  PASS: shipped VERSION $SHIPPED_VERSION is outside the retired-defaults window ($RETIRED_CASE)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: shipped VERSION $SHIPPED_VERSION still matches the retired-defaults case list ($RETIRED_CASE)"
    FAIL=$((FAIL + 1))
  fi
fi

# --- Firewall tier migration: the three ways it can resolve ------------------
# No security.json means a pre-firewall install. What happens next depends only on
# whether the permissions block is still the one the kit shipped.
echo "[firewall tier migration]"
(cd "$FW_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$FW_DIR" >/dev/null 2>&1
FW_SETTINGS="$FW_DIR/.claude/settings.json"
FW_SECURITY="$FW_DIR/.claude/security.json"
# A settings.json the kit really shipped, straight from its tag, so the baseline hash in
# update.sh is matched by construction rather than by a copy that drifts.
#
# The tag is not present in a shallow clone, which is what `actions/checkout` produces by
# default — so try to fetch it, and if it still is not there, skip this section loudly
# instead of failing. A test that needs network or full history must say so rather than
# reporting a feature as broken.
FW_TAG_OK=yes
if ! git -C "$REPO_ROOT" show v2.1.0:.claude/settings.json > "$FW_DIR/pre-firewall.json" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch -q --depth=1 origin tag v2.1.0 >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" show v2.1.0:.claude/settings.json > "$FW_DIR/pre-firewall.json" 2>/dev/null || FW_TAG_OK=no
fi
if [ "$FW_TAG_OK" = no ]; then
  echo "  SKIP: firewall tier migration needs the v2.1.0 tag (shallow clone and no network)"
else
assert_json_valid "$FW_DIR/pre-firewall.json" "a pre-firewall settings.json is available from the v2.1.0 tag"

# The frozen byte range, asserted here because the tag is in hand. update.sh's copy loop
# overwrites the running script and bash resumes reading by byte offset, so a change in
# lines 1-93 breaks self-update for every existing install. Nothing else checked this.
assert_eq "$(git -C "$REPO_ROOT" show v2.1.0:.claude/bin/update.sh | head -93 | shasum | cut -d' ' -f1)" \
  "$(head -93 "$REPO_ROOT/.claude/bin/update.sh" | shasum | cut -d' ' -f1)" \
  "update.sh lines 1-93 are byte-identical to v2.1.0 (the frozen range)"

fw_reset() {  # fw_reset <settings source> — back to a pre-firewall install
  rm -f "$FW_SECURITY" "$FW_SETTINGS"
  cp "$1" "$FW_SETTINGS"
}
fw_tier() {
  python3 -c "
import json
try: print(json.load(open('$FW_SECURITY')).get('tier', '__MISSING__'))
except Exception: print('__NOFILE__')" 2>/dev/null
}
fw_update() {
  (cd "$FW_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@" 2>&1) || true
}

# (1) baseline permissions -> adopt relaxed
fw_reset "$FW_DIR/pre-firewall.json"
FW_DRY="$(fw_update --dry-run)"
assert_contains "$FW_DRY" "[would set] .claude/security.json: tier relaxed" \
  "--dry-run reports adopting relaxed on a pre-firewall install"
assert_eq "__NOFILE__" "$(fw_tier)" "--dry-run writes no security.json"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" ".claude/security.json: tier relaxed" "a baseline install adopts relaxed"
assert_eq "relaxed" "$(fw_tier)" "security.json records tier relaxed"
assert_json_valid "$FW_SETTINGS" "settings.json is still valid JSON after the migration"
# Running again must not re-resolve: /firewall owns the tier once it is recorded.
python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); d["tier"] = "high"
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SECURITY"
fw_update >/dev/null
assert_eq "high" "$(fw_tier)" "a recorded tier is never re-resolved by a later update"

# (2) hand-edited permissions -> adopt off, say so, and touch nothing
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d.setdefault("permissions", {}).setdefault("allow", []).append("Bash(my-own-tool *)")
json.dump(d, open(sys.argv[2], "w"), indent=2)' "$FW_DIR/pre-firewall.json" "$FW_DIR/tuned.json"
fw_reset "$FW_DIR/tuned.json"
cp "$FW_SETTINGS" "$FW_DIR/tuned.before"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "tier off (permissions were tuned here)" \
  "a hand-edited policy adopts off instead of being rewritten"
assert_contains "$FW_OUT" "Run /firewall relaxed to adopt the kit set" \
  "the notice says how to opt in"
assert_eq "off" "$(fw_tier)" "security.json records tier off"
assert_cmd_success "cmp -s '$FW_DIR/tuned.before' '$FW_SETTINGS'" \
  "a tuned permissions block is left byte-identical"
assert_file_contains "$FW_SETTINGS" "Bash(my-own-tool *)" "the user's own rule survives"

# (3) symlinked settings.json -> skipped, nothing written
fw_reset "$FW_DIR/pre-firewall.json"
mv "$FW_SETTINGS" "$FW_DIR/real-settings.json"
ln -s "$FW_DIR/real-settings.json" "$FW_SETTINGS"
cp "$FW_DIR/real-settings.json" "$FW_DIR/link.before"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "[skipped] firewall tier:" "a symlinked settings.json is reported as skipped"
assert_contains "$FW_OUT" "symlink" "the skip message says why"
assert_eq "__NOFILE__" "$(fw_tier)" "no security.json is written when settings.json is a symlink"
assert_cmd_success "cmp -s '$FW_DIR/link.before' '$FW_DIR/real-settings.json'" \
  "the symlink target is left byte-identical"
rm -f "$FW_SETTINGS"
fi  # FW_TAG_OK

# --- Agents mode ---
echo "[agents mode]"
AGENTS_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR" "$FW_DIR" "$AGENTS_DIR"' EXIT
(cd "$AGENTS_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$AGENTS_DIR" >/dev/null 2>&1

assert_dir_exists "$AGENTS_DIR/.agents" ".agents/ exists after --agents install"
assert_file_exists "$AGENTS_DIR/.agents/bin/update.sh" ".agents/bin/update.sh exists"

(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh) >/dev/null 2>&1
assert_dir_exists "$AGENTS_DIR/.agents/agents" ".agents/agents/ valid after agents-mode update"
assert_dir_exists "$AGENTS_DIR/.agents/commands" ".agents/commands/ valid after agents-mode update"

# --- Agents mode: an older install's /cleanup (Claude Code only) ---
# --dry-run must report the removal and write nothing; the real update removes it.
echo "[agents mode: Claude-Code-only files]"
tree_sum() { (cd "$1" && find . -path ./.git -prune -o -type f -exec cksum {} + | LC_ALL=C sort -k3 | cksum); }
echo "# /cleanup from an older --agents install" > "$AGENTS_DIR/.agents/commands/cleanup.md"
TREE_BEFORE="$(tree_sum "$AGENTS_DIR")"
DRY_AGENTS="$(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh --dry-run 2>&1)"
assert_eq "$TREE_BEFORE" "$(tree_sum "$AGENTS_DIR")" "--dry-run changes no file in an --agents install"
assert_contains "$DRY_AGENTS" "[would remove] .agents/commands/cleanup.md" "--dry-run reports the /cleanup it would remove"
UPDATE_AGENTS="$(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh 2>&1)"
assert_contains "$UPDATE_AGENTS" "[removed] .agents/commands/cleanup.md" "update reports removing /cleanup"
assert_file_not_exists "$AGENTS_DIR/.agents/commands/cleanup.md" "update removes /cleanup from an --agents install"

print_summary
