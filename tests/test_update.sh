#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

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
assert_count "$TEMP_DIR/.claude/commands" "*.md" "31" "Command count == 31 after update"

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
assert_contains "$DRY_RETIRED" "[would remove] .mcp.json: mcpServers.context-mode, mcpServers.memsearch, mcpServers.surfpool" "--dry-run reports the retired MCP servers"
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
assert_eq "context7 helius my-server playwright solana-dev" "$MCP_LEFT" "kit MCP servers removed; user and user-edited servers kept"

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

# --- Agents mode ---
echo "[agents mode]"
AGENTS_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR" "$AGENTS_DIR"' EXIT
(cd "$AGENTS_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$AGENTS_DIR" >/dev/null 2>&1

assert_dir_exists "$AGENTS_DIR/.agents" ".agents/ exists after --agents install"
assert_file_exists "$AGENTS_DIR/.agents/bin/update.sh" ".agents/bin/update.sh exists"

(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh) >/dev/null 2>&1
assert_dir_exists "$AGENTS_DIR/.agents/agents" ".agents/agents/ valid after agents-mode update"
assert_dir_exists "$AGENTS_DIR/.agents/commands" ".agents/commands/ valid after agents-mode update"

print_summary
