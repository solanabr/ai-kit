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
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"

# --- Run update ---
echo "[basic update]"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"

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
if grep -qE '(^|[[:space:]])[0-9]+\.[0-9]+\.[0-9]+$' <<<"$VERSION_CONTENT"; then
  echo "  PASS: VERSION content is valid semver ($VERSION_CONTENT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: VERSION content is not valid semver ($VERSION_CONTENT)"
  FAIL=$((FAIL + 1))
fi

# --- Counts after update ---
assert_count "$TEMP_DIR/.claude/agents" "*.md" "15" "Agent count == 15 after update"
assert_count "$TEMP_DIR/.claude/commands" "*.md" "34" "Command count == 34 after update"

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
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"

assert_file_exists "$TEMP_DIR/CLAUDE.md.upstream" "CLAUDE.md.upstream created when CLAUDE.md differs"
assert_file_contains "$TEMP_DIR/CLAUDE.md" "My customized" "Original CLAUDE.md not overwritten"

# --- Protected files: .env not overwritten ---
echo "[protected files]"
echo "MY_SECRET=preserved" > "$TEMP_DIR/.env"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_file_contains "$TEMP_DIR/.env" "MY_SECRET=preserved" ".env not overwritten by update"

# --- Retired rules: unedited kit copies go; edited copies and the user's own stay ---
# A copy counts as the kit's only when it is byte-identical (CRs aside) to a version the
# kit shipped. rust.md below has the kit's name and globs: but content no version ever
# had, which is what a user's hand-corrected copy looks like, so it must survive.
echo "[retired rules]"
mkdir -p "$TEMP_DIR/.claude/rules"
printf -- '---\nglobs:\n  - "**/*.rs"\n---\n# Rust Code Standards for Solana\n' > "$TEMP_DIR/.claude/rules/rust.md"
printf -- '---\npaths:\n  - "src/**/*.ts"\n---\n# Team API rules\n' > "$TEMP_DIR/.claude/rules/team-api.md"
# Unedited copies come from the v2.1.0 tag, dotnet.md with the CRLF endings a Windows
# checkout gives it. Without the tag (shallow clone, no network) skip those, loudly.
RULE_TAG_OK=yes
for f in anchor.md dotnet.md; do
  if ! git -C "$REPO_ROOT" show "v2.1.0:.claude/rules/$f" > "$TEMP_DIR/$f.shipped" 2>/dev/null; then
    git -C "$REPO_ROOT" fetch -q --depth=1 origin tag v2.1.0 >/dev/null 2>&1 || true
    git -C "$REPO_ROOT" show "v2.1.0:.claude/rules/$f" > "$TEMP_DIR/$f.shipped" 2>/dev/null || RULE_TAG_OK=no
  fi
done
if [ "$RULE_TAG_OK" = yes ]; then
  cp "$TEMP_DIR/anchor.md.shipped" "$TEMP_DIR/.claude/rules/anchor.md"
  sed 's/$/\r/' "$TEMP_DIR/dotnet.md.shipped" > "$TEMP_DIR/.claude/rules/dotnet.md"
fi
rm -f "$TEMP_DIR/anchor.md.shipped" "$TEMP_DIR/dotnet.md.shipped"
DRY_RULES="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run 2>&1)"
assert_contains "$DRY_RULES" "[notice] .claude/rules/rust.md was edited after install, so it was kept" \
  "--dry-run reports the edited kit rule as kept, and why it still loads everywhere"
printf '%s\n' "$DRY_RULES" > "$TEMP_DIR/rules-dry.out"
assert_file_not_contains "$TEMP_DIR/rules-dry.out" "[would remove] .claude/rules/rust.md" "--dry-run does not plan to remove the edited copy"
if [ "$RULE_TAG_OK" = yes ]; then
  assert_contains "$DRY_RULES" "[would remove] .claude/rules/anchor.md" "--dry-run reports the unedited kit rule"
  assert_contains "$DRY_RULES" "[would remove] .claude/rules/dotnet.md" "--dry-run matches a CRLF copy of a shipped rule"
  assert_file_exists "$TEMP_DIR/.claude/rules/anchor.md" "--dry-run leaves the unedited kit rule in place"
else
  echo "  SKIP: removal of unedited kit rules needs the v2.1.0 tag (shallow clone and no network)"
fi
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
if [ "$RULE_TAG_OK" = yes ]; then
  assert_file_not_exists "$TEMP_DIR/.claude/rules/anchor.md" "Unedited kit rule removed by update"
  assert_file_not_exists "$TEMP_DIR/.claude/rules/dotnet.md" "Unedited kit rule with CRLF endings removed by update"
fi
assert_file_exists "$TEMP_DIR/.claude/rules/rust.md" "Edited kit rule kept by update"
assert_file_exists "$TEMP_DIR/.claude/rules/team-api.md" "User-written rule kept by update"
rm -f "$TEMP_DIR/.claude/rules/rust.md" "$TEMP_DIR/rules-dry.out"
# update.sh's list of shipped rule versions is pasted by hand. It must equal every
# version of the five files in the kit's history, or an unedited copy of a missing
# version would be kept as if the user had edited it. Needs full history.
if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
  HIST_BLOBS="$(for c in $(git -C "$REPO_ROOT" rev-list HEAD -- .claude/rules/); do
      git -C "$REPO_ROOT" ls-tree "$c" .claude/rules/; done \
    | awk '$4 ~ /\/(anchor|dotnet|pinocchio|rust|typescript)\.md$/ {print $3}' | sort -u | tr '\n' ' ')"
  LISTED_BLOBS="$(awk '/^RETIRED_RULE_BLOBS="/,/"$/' "$REPO_ROOT/.claude/bin/update.sh" \
    | grep -oE '[0-9a-f]{40}' | sort -u | tr '\n' ' ')"
  assert_eq "$HIST_BLOBS" "$LISTED_BLOBS" "update.sh lists exactly the rule versions the kit ever shipped"
else
  echo "  SKIP: the shipped-rule list check needs full git history (shallow clone)"
fi

# --- A failed fetch stops the update instead of reporting success ---
# The clone sits in update.sh's frozen range and swallows git's exit status, so a dead
# upstream used to run every step below it and exit 0 with "Update complete!". A
# file:// URL that does not exist fails at once and offline. The retired rule is the
# first thing below the guard that writes to the project, so its surviving pins the
# guard above every write, not just above the summary.
echo "[failed fetch]"
mkdir -p "$TEMP_DIR/.claude/rules"
printf -- '---\nglobs:\n  - "**/*.rs"\n---\n# Rust Code Standards for Solana\n' > "$TEMP_DIR/.claude/rules/rust.md"
DEAD_URL="file://$TEMP_DIR/no-such-upstream.git"
FETCH_RC=0
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC='' SOLANA_CLAUDE_LOCAL_SRC='' SOLANA_AI_KIT_UPSTREAM="$DEAD_URL" \
  bash .claude/bin/update.sh) > "$TEMP_DIR/fetch.out" 2> "$TEMP_DIR/fetch.err" || FETCH_RC=$?
assert_eq "non-zero" "$([ "$FETCH_RC" -ne 0 ] && echo non-zero || echo "$FETCH_RC")" \
  "update.sh exits non-zero when the upstream cannot be fetched"
assert_file_contains "$TEMP_DIR/fetch.err" "could not fetch $DEAD_URL" "the failure is reported on stderr, naming the URL"
assert_file_not_contains "$TEMP_DIR/fetch.out" "Update complete" "a failed fetch does not report success"
assert_file_exists "$TEMP_DIR/.claude/rules/rust.md" "a failed fetch writes nothing to the project"
rm -f "$TEMP_DIR/.claude/rules/rust.md" "$TEMP_DIR/fetch.out" "$TEMP_DIR/fetch.err"

# A token in SOLANA_AI_KIT_UPSTREAM must not reach stderr through our message. Only
# stderr is ours here: the clone's last line on stdout is printed by the frozen range.
CRED_URL="file://tok3n-s3cr3t@$TEMP_DIR/no-such-upstream.git"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC='' SOLANA_CLAUDE_LOCAL_SRC='' SOLANA_AI_KIT_UPSTREAM="$CRED_URL" \
  bash .claude/bin/update.sh) > "$TEMP_DIR/fetch.out" 2> "$TEMP_DIR/fetch.err" || true
assert_file_contains "$TEMP_DIR/fetch.err" "could not fetch file://$TEMP_DIR/no-such-upstream.git" \
  "the failure names the upstream without its credentials"
assert_file_not_contains "$TEMP_DIR/fetch.err" "tok3n-s3cr3t" "no credential from the upstream URL reaches stderr"

# A local source without .claude/ makes the frozen range fall back to the network in
# silence. When that fetch fails too, the error has to name the local path, not just
# a URL nobody asked for.
mkdir -p "$TEMP_DIR/empty-src"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$TEMP_DIR/empty-src" SOLANA_AI_KIT_UPSTREAM="$DEAD_URL" \
  bash .claude/bin/update.sh) > "$TEMP_DIR/fetch.out" 2> "$TEMP_DIR/fetch.err" || true
assert_file_contains "$TEMP_DIR/fetch.err" "SOLANA_AI_KIT_LOCAL_SRC=$TEMP_DIR/empty-src has no .claude/" \
  "a local source without .claude/ is named when the fallback fetch fails"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC='' SOLANA_CLAUDE_LOCAL_SRC="$TEMP_DIR/empty-src" SOLANA_AI_KIT_UPSTREAM="$DEAD_URL" \
  bash .claude/bin/update.sh) > "$TEMP_DIR/fetch.out" 2> "$TEMP_DIR/fetch.err" || true
assert_file_contains "$TEMP_DIR/fetch.err" "SOLANA_CLAUDE_LOCAL_SRC=$TEMP_DIR/empty-src has no .claude/" \
  "...under the legacy variable's name when that is the one set"
rm -rf "$TEMP_DIR/empty-src"; rm -f "$TEMP_DIR/fetch.out" "$TEMP_DIR/fetch.err"

# --- The note about a fetched ref that is not a release tag ---
# /update passes kit-ref.sh's ref, which is main until a release above the floor exists,
# so a note on main fired on every /update. A requested main is quiet; any other
# non-release ref still gets the note. The fixture is a file:// upstream holding this
# checkout's kit on main and on a branch, so the clone runs offline.
echo "[ref note]"
REF_UP="$TEMP_DIR/ref-upstream"
mkdir -p "$REF_UP"
cp -r "$REPO_ROOT/.claude" "$REF_UP/.claude"
for f in CLAUDE-solana.md .mcp.json .env.example .env.schema; do
  if [ -f "$REPO_ROOT/$f" ]; then cp "$REPO_ROOT/$f" "$REF_UP/$f"; fi
done
(cd "$REF_UP" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
  GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
  && git init -q -b main && git add -A && git commit -q --no-gpg-sign -m fixture && git branch feature)
ref_update() {  # ref_update <branch>: stderr of an update fetching <branch> from the fixture
  (cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC='' SOLANA_CLAUDE_LOCAL_SRC='' \
    SOLANA_AI_KIT_UPSTREAM="file://$REF_UP" SOLANA_AI_KIT_BRANCH="$1" \
    bash .claude/bin/update.sh) > "$TEMP_DIR/ref.out" 2> "$TEMP_DIR/ref.err" || true
}
ref_update main
assert_file_contains "$TEMP_DIR/ref.out" "Update complete" "an update fetching main from a file:// upstream completes"
assert_file_not_contains "$TEMP_DIR/ref.err" "not a release tag" "a requested main (kit-ref.sh's answer before a release) prints no note"
# Control: the same run on a branch prints it, so the assertion above can fail.
ref_update feature
assert_file_contains "$TEMP_DIR/ref.err" "fetched feature, which is not a release tag" "a requested ref that is neither a tag nor main is still noted"

# --- Fetching an older VERSION than the one installed ---
# The copy loop applies whatever was fetched, so a downgrade (an install that followed
# main moving to an older release) is warned about, never silent.
echo "[downgrade warning]"
KIT_VERSION="$(awk '{print $NF}' "$REPO_ROOT/.claude/VERSION")"
echo "solana-ai-kit 99.0.0" > "$TEMP_DIR/.claude/VERSION"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$TEMP_DIR/ref.out" 2> "$TEMP_DIR/ref.err" || true
assert_file_contains "$TEMP_DIR/ref.err" "this fetched v$KIT_VERSION, older than the installed v99.0.0" \
  "an update to a lower VERSION warns that it is a downgrade"
assert_file_contains "$TEMP_DIR/ref.err" "SOLANA_AI_KIT_BRANCH=main" "...and says how to stay on the newer version"
# A dry run copies nothing, so it says the downgrade would happen, not that it did.
echo "solana-ai-kit 99.0.0" > "$TEMP_DIR/.claude/VERSION"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run) > "$TEMP_DIR/ref.out" 2> "$TEMP_DIR/ref.err" || true
assert_file_contains "$TEMP_DIR/ref.err" "this would downgrade to v$KIT_VERSION from the installed v99.0.0" \
  "a dry run says the downgrade would happen"
assert_file_not_contains "$TEMP_DIR/ref.err" "this fetched v$KIT_VERSION, older than" "...and not that it was applied"
# Controls: the same VERSION, and an older installed one, are not downgrades.
for v in "$KIT_VERSION" 0.0.1; do
  echo "solana-ai-kit $v" > "$TEMP_DIR/.claude/VERSION"
  (cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$TEMP_DIR/ref.out" 2> "$TEMP_DIR/ref.err" || true
  assert_file_not_contains "$TEMP_DIR/ref.err" "older than the installed" "no downgrade warning from v$v to v$KIT_VERSION"
done
# A field compares as a number, not as text: 2.10.0 is newer than 2.9.0.
echo "solana-ai-kit 2.9.0" > "$TEMP_DIR/.claude/VERSION"
cp -r "$REF_UP" "$TEMP_DIR/v210-src"
echo "solana-ai-kit 2.10.0" > "$TEMP_DIR/v210-src/.claude/VERSION"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$TEMP_DIR/v210-src" bash .claude/bin/update.sh) > "$TEMP_DIR/ref.out" 2> "$TEMP_DIR/ref.err" || true
assert_file_not_contains "$TEMP_DIR/ref.err" "older than the installed" "v2.9.0 to v2.10.0 is not a downgrade"
rm -rf "$REF_UP" "$TEMP_DIR/v210-src"; rm -f "$TEMP_DIR/ref.out" "$TEMP_DIR/ref.err"
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

# --- Firewall tier migration: the three ways it can resolve ------------------
# No security.json means a pre-firewall install. What happens next depends only on
# whether the permissions block is still the one the kit shipped.
echo "[firewall tier migration]"
(cd "$FW_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$FW_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"
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
# What tier off promises is the permission policy, not the whole file: the same run also
# registers the kit hooks this pre-firewall install never had (issue #91), which is a
# different surface and an append rather than a rewrite. So compare the two blocks the
# notice is actually about, and assert the hooks landed beside them.
fw_policy() {  # fw_policy <settings file> — the permissions + sandbox blocks, canonical
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps({k: d.get(k) for k in ('permissions', 'sandbox')}, sort_keys=True))" "$1"
}
assert_eq "$(fw_policy "$FW_DIR/tuned.before")" "$(fw_policy "$FW_SETTINGS")" \
  "a tuned permissions and sandbox policy is left byte-identical"
assert_file_contains "$FW_SETTINGS" "Bash(my-own-tool *)" "the user's own rule survives"
assert_file_contains "$FW_SETTINGS" "secrets-guard.sh" \
  "the kit's guards are registered even where the tier backs off to off"

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

# (4) MCP gating reaches an install that already has a security.json.
#
# This is the case the pre-firewall migration above deliberately skips, so without the
# catch-up it is the case that never receives a rule change. Two independent things have
# to land: the PreToolUse matcher in settings.json (which update.sh never overwrites and
# firewall.sh never manages) and the regenerated rule block (which needs the
# ruleSetVersion comparison to fire).
echo "[MCP gating migration]"
# The fixture is a CURRENT install, not the v2.1.0 one used above: at that tag the hook
# bodies were still inline in settings.json, so none of its entries name a guard script
# and the migration correctly declines to touch them — which would make every assertion
# below pass for the wrong reason. (It did, before this comment existed.)
cp "$REPO_ROOT/.claude/settings.json" "$FW_SETTINGS"
cp "$REPO_ROOT/.claude/security.json" "$FW_SECURITY"
assert_eq "3" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {}).get('PreToolUse') or []
print(len([e for e in hooks
           if any(g in ' '.join(h.get('command','') for h in e.get('hooks') or [])
                  for g in ('secrets-guard','onchain-guard','egress-guard'))]))" 2>/dev/null)" \
  "the fixture really has three kit guard registrations to migrate"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["tier"] = "high"
# An install generated by the previous rule set, with the old Bash-only matcher.
(d.get("enforced") or {})["ruleSetVersion"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SECURITY"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for e in (d.get("hooks") or {}).get("PreToolUse", []):
    e["matcher"] = "Bash"
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SETTINGS"

# The rule-set version this kit ships; the catch-up goes from 1 to it.
FW_RS="$(awk -F= '/^RULE_SET_VERSION[[:space:]]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$REPO_ROOT/.claude/bin/firewall.sh")"
FW_DRY="$(fw_update --dry-run)"
assert_contains "$FW_DRY" "PreToolUse matcher" "--dry-run reports the matcher migration"
assert_contains "$FW_DRY" "firewall rule set v1 -> v$FW_RS" "--dry-run reports the rule-set catch-up"
assert_eq "Bash" "$(python3 -c "
import json
print((json.load(open('$FW_SETTINGS')).get('hooks') or {})['PreToolUse'][0]['matcher'])" 2>/dev/null)" \
  "--dry-run rewrites no matcher"

FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "PreToolUse matcher" "the matcher migration is reported"
assert_json_valid "$FW_SETTINGS" "settings.json is still valid JSON after the matcher rewrite"
assert_eq "0" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {}).get('PreToolUse') or []
bad = [e for e in hooks
       if any(g in ' '.join(h.get('command','') for h in e.get('hooks') or [])
              for g in ('secrets-guard','onchain-guard','egress-guard'))
       and e.get('matcher') != 'Bash|mcp__context-mode__.*']
print(len(bad))" 2>/dev/null)" \
  "every kit guard now matches Bash and context-mode's MCP tools"
# The rule-set catch-up has to have re-applied High, which is what adds the tool denies:
# context-mode's five and Playwright's two, plus mcp__cloudflare__execute and
# mcp__playwright__browser_evaluate, which only High carries.
assert_eq "9" "$(python3 -c "
import json
p = json.load(open('$FW_SETTINGS')).get('permissions') or {}
print(len([r for r in (p.get('deny') or []) if r.startswith('mcp__')]))" 2>/dev/null)" \
  "re-applying High on an older rule set adds the MCP executor denies"
assert_eq "$FW_RS" "$(python3 -c "
import json
print((json.load(open('$FW_SECURITY')).get('enforced') or {}).get('ruleSetVersion'))" 2>/dev/null)" \
  "security.json records the new rule-set version"
assert_eq "high" "$(fw_tier)" "the declared tier is preserved by the catch-up"
# Idempotent: a second run has nothing to say and changes nothing.
cp "$FW_SETTINGS" "$FW_DIR/mcp.before"
FW_OUT="$(fw_update)"
assert_eq "no" "$(grep -q 'PreToolUse matcher' <<<"$FW_OUT" && echo yes || echo no)" \
  "a second update does not report the matcher migration again"
assert_eq "no" "$(grep -q 'firewall rule set v' <<<"$FW_OUT" && echo yes || echo no)" \
  "a second update does not report the rule-set catch-up again"
assert_cmd_success "cmp -s '$FW_DIR/mcp.before' '$FW_SETTINGS'" \
  "a second update leaves settings.json byte-identical"
# A matcher the user narrowed themselves is theirs, not the kit's to widen.
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d.setdefault("hooks", {}).setdefault("PreToolUse", []).append(
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-audit-hook"}]})
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SETTINGS"
fw_update >/dev/null
assert_eq "Bash" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {})['PreToolUse']
print([e['matcher'] for e in hooks if 'my-own-audit-hook' in ' '.join(h.get('command','') for h in e['hooks'])][0])" 2>/dev/null)" \
  "a non-kit Bash hook keeps its own matcher"

# (5) /update never carries a project onto the maintainer tier, nor re-applies it. A
# project that declares it (copied out of a kit checkout) is reported, not regenerated,
# even with a rule set behind the shipped one — the case that otherwise re-applies.
echo "[maintainer tier is never re-applied]"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["tier"] = "maintainer"
(d.get("enforced") or {})["ruleSetVersion"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SECURITY"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "declares the maintainer tier" "a declared maintainer tier is reported by /update"
assert_eq "no" "$(printf '%s' "$FW_OUT" | grep -q 'firewall rule set v' && echo yes || echo no)" \
  "/update does not re-apply the maintainer tier on an older rule set"
assert_eq "maintainer" "$(fw_tier)" "/update leaves the declared tier for the user to change"
assert_eq "no" "$(grep -q '"git submodule \*"' "$FW_SETTINGS" && echo yes || echo no)" \
  "/update writes no maintainer rule into settings.json"
rm -f "$FW_SETTINGS" "$FW_SECURITY"
fi  # FW_TAG_OK

# --- Agents mode ---
echo "[agents mode]"
AGENTS_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR" "$FW_DIR" "$AGENTS_DIR"' EXIT
(cd "$AGENTS_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$AGENTS_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"

assert_dir_exists "$AGENTS_DIR/.agents" ".agents/ exists after --agents install"
assert_file_exists "$AGENTS_DIR/.agents/bin/update.sh" ".agents/bin/update.sh exists"

(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
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

# grep -q stopping at an early match used to kill `tr` with SIGPIPE under pipefail, so a
# large .gitignore whose match came first read as "not found" and got a second line.
{ printf '.memsearch/\n'; seq 1 4000 | sed 's|.*|generated/path-&/|'; tr -d '\r' < "$TEMP_DIR/.gitignore" | awk '$0 != ".memsearch/"'; } > "$FW_DIR/gi"
cat "$FW_DIR/gi" > "$TEMP_DIR/.gitignore" && rm -f "$FW_DIR/gi"
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
printf 'PRECIOUS\n' > "$FW_DIR/victim"
ln -s "$FW_DIR/victim" "$TEMP_DIR/.gitignore.tmp"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "1" "$(grep -cxF '.env.local' "$TEMP_DIR/.gitignore")" "a last line without a newline stays its own line after an update"
assert_eq "PRECIOUS" "$(cat "$FW_DIR/victim")" "update.sh never writes through a planted .gitignore.tmp symlink"
assert_eq "1" "$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$TEMP_DIR/.gitignore" | grep -cxF '.safe-ai-skill/')" \
  "...while the edit that uses the scratch file ran: .safe-ai-skill/ is back in the kit block"
rm -f "$TEMP_DIR/.gitignore.tmp"

# The JSON rewrites went through fixed names as well, so a repo could plant a link at
# any of them. A fresh install's first /update rewrites security.json and settings.json,
# and a firewall apply rewrites them again.
echo "[json scratch files]"
JP="$(new_tmp)" || exit 1
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$JP" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"
PLANTED="security.json.firewall.tmp settings.json.mcp.tmp security.json.hooks.tmp settings.json.hooks.tmp .settings.json.firewall.tmp .security.json.firewall.tmp"
for n in $PLANTED; do printf 'PRECIOUS\n' > "$FW_DIR/victim-$n"; ln -s "$FW_DIR/victim-$n" "$JP/.claude/$n"; done
(cd "$JP" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
(cd "$JP" && CLAUDE_PROJECT_DIR="$JP" bash .claude/bin/firewall.sh apply relaxed) > "$QUIET_LOG" 2>&1 || quiet_fail "firewall.sh apply"
HIT=""
for n in $PLANTED; do [ "$(cat "$FW_DIR/victim-$n")" = PRECIOUS ] || HIT="$HIT $n"; done
assert_eq "" "$HIT" "neither /update nor firewall.sh writes through a link planted at a fixed scratch-file name"
rm -rf "$JP"

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
cp "$TEMP_DIR/.env.schema" "$FW_DIR/shared.schema"
python3 - "$FW_DIR/shared.schema" <<'EOF'
import sys
p = sys.argv[1]
head = open(p).read().rstrip("\n").rpartition("\n\n")[0]
open(p, "w").write(head + "\n")
EOF
cp "$FW_DIR/shared.schema" "$FW_DIR/shared.before"
rm -f "$TEMP_DIR/.env.schema" && ln -s "$FW_DIR/shared.schema" "$TEMP_DIR/.env.schema"
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_eq "" "$(diff "$FW_DIR/shared.before" "$FW_DIR/shared.schema" 2>&1 || true)" "update.sh never writes through a symlinked .env.schema"
rm -f "$TEMP_DIR/.env.schema"

print_summary
