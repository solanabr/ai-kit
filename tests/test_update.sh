#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# new_tmp (helpers.sh) falls back when `mktemp -d` is denied by the sandbox — reproduced
# three times this session. That is the shipped bug this release fixes, so the migration
# tests must not hang off it.
TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_update] Comprehensive update.sh validation"
echo ""

# The settings and .mcp.json migrations, the .gitignore backfill and the .env.schema
# merge live in tests/test_update_migrations.sh, the firewall tier migration in
# tests/test_update_firewall.sh and agents mode in tests/test_update_agents.sh. Each
# builds its own install, so they run side by side under run_all.sh instead of one
# suite setting the whole run's floor.

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
assert_count "$TEMP_DIR/.claude/commands" "*.md" "54" "Command count == 54 after update"

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
    fetch_tag v2.1.0 || true
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

# --- Retired guards: an unedited copy is removed, an edited one is kept and named ---
# secrets-guard and fetch-exec-guard left the kit when safe-ai-skill took over what they
# gated. The hooks/ copy never deletes, so update.sh removes a file only while it is a
# version the kit shipped, CRs aside. Unedited copies come from the kit's history, from
# before the last commit that touched them; without it (shallow clone) skip those, loudly.
echo "[retired guards]"
HOOK_HIST_OK=no
LAST_FE="$(git -C "$REPO_ROOT" rev-list -1 HEAD -- .claude/hooks/fetch-exec-guard.awk 2>/dev/null)" || LAST_FE=""
if [ -n "$LAST_FE" ] \
   && git -C "$REPO_ROOT" show "$LAST_FE^:.claude/hooks/fetch-exec-guard.awk" > "$TEMP_DIR/fe.awk" 2>/dev/null \
   && git -C "$REPO_ROOT" show "$LAST_FE^:.claude/hooks/fetch-exec-guard.sh" > "$TEMP_DIR/fe.sh" 2>/dev/null; then
  cp "$TEMP_DIR/fe.awk" "$TEMP_DIR/.claude/hooks/fetch-exec-guard.awk"
  sed 's/$/\r/' "$TEMP_DIR/fe.sh" > "$TEMP_DIR/.claude/hooks/fetch-exec-guard.sh"
  HOOK_HIST_OK=yes
fi
rm -f "$TEMP_DIR/fe.awk" "$TEMP_DIR/fe.sh"
printf '#!/bin/sh\n# my own secrets checks\nexit 0\n' > "$TEMP_DIR/.claude/hooks/secrets-guard.sh"
DRY_HOOKS="$(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh --dry-run 2>&1)"
assert_contains "$DRY_HOOKS" "[notice] .claude/hooks/secrets-guard.sh was edited after install, so it was kept" \
  "--dry-run names an edited retired guard as kept"
if [ "$HOOK_HIST_OK" = yes ]; then
  assert_contains "$DRY_HOOKS" "[would remove] .claude/hooks/fetch-exec-guard.awk" "--dry-run reports an unedited retired guard"
  assert_contains "$DRY_HOOKS" "[would remove] .claude/hooks/fetch-exec-guard.sh" "--dry-run matches a CRLF copy of a retired guard"
  assert_file_exists "$TEMP_DIR/.claude/hooks/fetch-exec-guard.awk" "--dry-run leaves the unedited retired guard in place"
else
  echo "  SKIP: removal of unedited retired guards needs the kit's git history (shallow clone)"
fi
(cd "$TEMP_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
if [ "$HOOK_HIST_OK" = yes ]; then
  assert_file_not_exists "$TEMP_DIR/.claude/hooks/fetch-exec-guard.awk" "Unedited retired guard removed by update"
  assert_file_not_exists "$TEMP_DIR/.claude/hooks/fetch-exec-guard.sh" "Unedited retired guard with CRLF endings removed by update"
fi
assert_file_exists "$TEMP_DIR/.claude/hooks/secrets-guard.sh" "Edited retired guard kept by update"
rm -f "$TEMP_DIR/.claude/hooks/secrets-guard.sh"
# The list of retired versions is pasted by hand as well. It must hold every version of the
# four files in the kit's history, as shipped and as an --agents install rewrote it, or an
# unedited copy would be kept as if the user had edited it. Needs full history.
if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
  LISTED_HOOK="$(sed -n '/^RETIRED_HOOK_BLOBS="/,/"$/p' "$REPO_ROOT/.claude/bin/update.sh" \
    | sed -e 's/^RETIRED_HOOK_BLOBS="//' -e 's/"$//')"
  MISSING_HOOK=""
  for f in secrets-guard.sh secrets-guard.awk fetch-exec-guard.sh fetch-exec-guard.awk; do
    for c in $(git -C "$REPO_ROOT" rev-list HEAD -- ".claude/hooks/$f"); do
      git -C "$REPO_ROOT" show "$c:.claude/hooks/$f" > "$TEMP_DIR/retired.v" 2>/dev/null || continue
      for b in "$(git hash-object "$TEMP_DIR/retired.v")" \
               "$(sed -E '/\.agents\//!{s#(^|[^[:alnum:]_./~-])\.claude/#\1.agents/#g;s#([$][{]CLAUDE_PROJECT_DIR:-[.][}])/\.claude/#\1/.agents/#g;}' "$TEMP_DIR/retired.v" | git hash-object --stdin)"; do
        grep -qxF "$b  $f" <<<"$LISTED_HOOK" || MISSING_HOOK="$MISSING_HOOK $b($f)"
      done
    done
  done
  rm -f "$TEMP_DIR/retired.v"
  assert_eq "" "$MISSING_HOOK" "update.sh lists every version of the retired guards, as shipped and as --agents rewrote it"
else
  echo "  SKIP: the retired-guard list check needs full git history (shallow clone)"
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

print_summary
