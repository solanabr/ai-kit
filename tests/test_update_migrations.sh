#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Split out of tests/test_update.sh: what /update migrates in an existing install's own
# files (retired kit defaults in settings.json and .mcp.json, the .gitignore backfill and
# the .env.schema merge). Its own install, updated once, which is the state the original
# single suite reached these checks in.
TEMP_DIR="$(new_tmp)" || exit 1
# Scratch space outside the project, for files a test plants links to or stages through.
SCRATCH="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR" "$SCRATCH"' EXIT

echo "[test_update_migrations] update.sh: settings, .mcp.json, .gitignore and .env.schema migrations"
echo ""

(cd "$TEMP_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"

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
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_cmd_success "cmp -s '$SETTINGS' '$TEMP_DIR/settings.before'" "second update leaves settings.json unchanged"

# Only installs from kit <= 2.1.0 are migrated: a value set later is the user's choice
echo "solana-ai-kit 2.2.0" > "$TEMP_DIR/.claude/VERSION"
python3 -c 'import json, sys
s = json.load(open(sys.argv[1])); s["enableAllProjectMcpServers"] = True
json.dump(s, open(sys.argv[1], "w"), indent=2)' "$SETTINGS"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
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

# --- .gitignore backfill on a CRLF file adds nothing twice ---
# Git for Windows checks a tracked .gitignore out with CRLF endings. The backfill's
# exact-line check has to ignore the CR, or every /update appends .memsearch/ again.
echo "[gitignore backfill, CRLF]"
printf '.memsearch/\r\n.claude/worktrees/\r\n' > "$TEMP_DIR/.gitignore"
for _ in 1 2; do
  (cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
done
assert_eq "1" "$(tr -d '\r' < "$TEMP_DIR/.gitignore" | grep -cxF '.memsearch/')" "a CRLF .gitignore keeps one .memsearch/ line across two updates"
assert_eq "1" "$(tr -d '\r' < "$TEMP_DIR/.gitignore" | grep -cxF '.claude/worktrees/')" "a CRLF .gitignore keeps one .claude/worktrees/ line across two updates"
assert_eq "1" "$(tr -d '\r' < "$TEMP_DIR/.gitignore" | grep -cxF '.claude/reports/')" \
  "an existing install's .gitignore gains .claude/reports/ (report pages), once across two updates"
# A 1.x install never ignored context/, where /crew's stage file and /rundown --handoff,
# with the record's export appended, are written.
assert_eq "1" "$(tr -d '\r' < "$TEMP_DIR/.gitignore" | grep -cxF '.claude/context/')" \
  "an existing install's .gitignore gains .claude/context/ (hand-offs), once across two updates"

# grep -q stopping at an early match used to kill `tr` with SIGPIPE under pipefail, so a
# large .gitignore whose match came first read as "not found" and got a second line.
{ printf '.memsearch/\n'; seq 1 4000 | sed 's|.*|generated/path-&/|'; tr -d '\r' < "$TEMP_DIR/.gitignore" | awk '$0 != ".memsearch/"'; } > "$SCRATCH/gi"
cat "$SCRATCH/gi" > "$TEMP_DIR/.gitignore" && rm -f "$SCRATCH/gi"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "1" "$(grep -cxF '.memsearch/' "$TEMP_DIR/.gitignore")" "an update over a large .gitignore whose match comes first adds no second line"

# --- .gitignore: no glued last line, no write through a planted scratch file ---
# A last line without a newline would be glued to the next append (`.env.local` then
# `.memsearch/` became `.env.local.memsearch/`, un-ignoring .env.local). And the scratch
# copy that edits the kit block must never go through a .gitignore.tmp a repo shipped as
# a symlink, since the repo's .gitignore text would land wherever it points.
echo "[gitignore appends and scratch file]"
# A kit block without .safe-ai-skill/ makes the update edit the block through its
# scratch file; a final `.env.local` with no newline is what the next append meets.
{
  printf '# >>> solana-ai-kit config — gitignored by default; run /commit-claude-config to version it >>>\n'
  printf '.gitmodules\n.claude/\n.mcp.json\n'
  printf '# <<< solana-ai-kit config <<<\n'
  printf '.env.local'
} > "$TEMP_DIR/.gitignore"
printf 'PRECIOUS\n' > "$SCRATCH/victim"
ln -s "$SCRATCH/victim" "$TEMP_DIR/.gitignore.tmp"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "1" "$(grep -cxF '.env.local' "$TEMP_DIR/.gitignore")" "a last line without a newline stays its own line after an update"
assert_eq "PRECIOUS" "$(cat "$SCRATCH/victim")" "update.sh never writes through a planted .gitignore.tmp symlink"
assert_eq "1" "$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$TEMP_DIR/.gitignore" | grep -cxF '.safe-ai-skill/')" \
  "...while the edit that uses the scratch file ran: .safe-ai-skill/ is back in the kit block"
rm -f "$TEMP_DIR/.gitignore.tmp"

# --- .env.schema: an existing schema gets the kit's missing keys ---
# .env receives every kit key, and varlock treats a key its schema does not declare as
# required, so a schema that lacks one breaks `varlock load`. Dropping the last block
# stands in for a key a newer kit adds.
echo "[.env.schema merge]"
cp "$REPO_ROOT/.env.schema" "$TEMP_DIR/.env.schema"
python3 - "$TEMP_DIR/.env.schema" <<'EOF'
import sys
p = sys.argv[1]
head = open(p).read().rstrip("\n").rpartition("\n\n")[0]
open(p, "w").write(head + "\n")
EOF
LAST_KEY="$(grep -E '^[A-Z_]+=' "$REPO_ROOT/.env.schema" | tail -1 | cut -d= -f1)"
DRY_SCHEMA="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run 2>&1)"
assert_contains "$DRY_SCHEMA" "[would update] .env.schema — kit keys added: $LAST_KEY" "--dry-run reports the kit key the schema lacks"
assert_eq "0" "$(grep -c "^$LAST_KEY=" "$TEMP_DIR/.env.schema")" "...and writes nothing"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "1" "$(grep -c "^$LAST_KEY=" "$TEMP_DIR/.env.schema")" "update.sh appends the kit key the schema lacks"
assert_eq "1" "$(grep -c '^# ---' "$TEMP_DIR/.env.schema")" "...without copying the kit's header again"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "1" "$(grep -c "^$LAST_KEY=" "$TEMP_DIR/.env.schema")" "...and a second run adds nothing"
# A symlinked schema points somewhere the project does not own: never written through.
cp "$TEMP_DIR/.env.schema" "$SCRATCH/shared.schema"
python3 - "$SCRATCH/shared.schema" <<'EOF'
import sys
p = sys.argv[1]
head = open(p).read().rstrip("\n").rpartition("\n\n")[0]
open(p, "w").write(head + "\n")
EOF
cp "$SCRATCH/shared.schema" "$SCRATCH/shared.before"
rm -f "$TEMP_DIR/.env.schema" && ln -s "$SCRATCH/shared.schema" "$TEMP_DIR/.env.schema"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "" "$(diff "$SCRATCH/shared.before" "$SCRATCH/shared.schema" 2>&1 || true)" "update.sh never writes through a symlinked .env.schema"
rm -f "$TEMP_DIR/.env.schema"

print_summary
