#!/usr/bin/env bash
# Compare a project installed by install.sh with what this checkout's README promises.
# Usage: check-install.sh <project> <extension-id> [expected-version]
# Run from the repository root. Used by install-live.yml, whose install takes the path
# real users take (the published one-liner, the latest tag, no SOLANA_AI_KIT_LOCAL_SRC),
# so a stale release or a --with that installs nothing fails here instead of in a
# user's project (#113).
set -uo pipefail

P="$1"; EXT="$2"; WANT_VERSION="${3:-}"
C="$P/.claude"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "::error::$*"; FAILS=$((FAILS + 1)); }

# The README's headline sentence carries the counts (tests/test_cross_references.sh
# keeps it in step with the repository).
CLAIM="$(grep -m1 'One command installs' README.md || true)"
AGENTS="$(printf '%s' "$CLAIM" | grep -oE '[0-9]+ specialized agents' | grep -oE '^[0-9]+' || true)"
COMMANDS="$(printf '%s' "$CLAIM" | grep -oE '[0-9]+ workflow commands' | grep -oE '^[0-9]+' || true)"
MCP="$(printf '%s' "$CLAIM" | grep -oE '[0-9]+ MCP servers' | grep -oE '^[0-9]+' || true)"
if [ -z "$AGENTS" ] || [ -z "$COMMANDS" ] || [ -z "$MCP" ]; then
  fail "could not read the agent, command and MCP counts from README.md's 'One command installs' sentence"
  exit 1
fi

count_md() { find "$1" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
n="$(count_md "$C/agents")"
[ "$n" = "$AGENTS" ] && pass "$n agents, as README says" || fail "$n agents installed, README says $AGENTS"
n="$(count_md "$C/commands")"
[ "$n" = "$COMMANDS" ] && pass "$n commands, as README says" || fail "$n commands installed, README says $COMMANDS"
n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["mcpServers"]))' "$P/.mcp.json" 2>/dev/null || echo none)"
[ "$n" = "$MCP" ] && pass "$n MCP servers in .mcp.json, as README says" || fail "$n MCP servers in .mcp.json, README says $MCP"

[ ! -e "$C/rules" ] && pass "no .claude/rules/" || fail ".claude/rules/ exists; the kit ships no rules"
[ -x "$C/bin/skills.sh" ] && pass ".claude/bin/skills.sh is present and executable" || fail ".claude/bin/skills.sh is missing or not executable"

# A pack counts as installed when it carries a SKILL.md outside a dot-directory.
has_skill() { [ -n "$(find "$1" -name '.*' -prune -o -name SKILL.md -print -quit 2>/dev/null)" ]; }
has_skill "$C/skills/ext/$EXT" && pass "--with $EXT installed ext/$EXT" || fail "--with $EXT left ext/$EXT without a SKILL.md"
grep -qx "$EXT" "$C/skills/extensions.txt" 2>/dev/null \
  && pass "$EXT is recorded in skills/extensions.txt" || fail "$EXT is not recorded in skills/extensions.txt, so /update would drop it"

# Every core pack is fetched; no extension other than the one asked for is.
REG="$C/skills/skill-registry.json"
if [ -f "$REG" ]; then
  while IFS=' ' read -r tier id; do
    if [ "$tier" = core ]; then
      has_skill "$C/skills/ext/$id" && pass "core pack $id installed" || fail "core pack $id has no SKILL.md"
    elif [ "$id" != "$EXT" ] && has_skill "$C/skills/ext/$id"; then
      fail "extension $id was installed without being asked for"
    fi
  done < <(python3 -c '
import json, sys
for e in json.load(open(sys.argv[1]))["entries"]:
    if e.get("tier") in ("core", "extension") and e.get("path", "").startswith(".claude/skills/ext/"):
        print(e["tier"], e["id"])' "$REG")
else
  fail "no skills/skill-registry.json installed"
fi

GOT_VERSION="$(awk '{print $NF}' "$C/VERSION" 2>/dev/null || true)"
if [ -n "$WANT_VERSION" ]; then
  [ "$GOT_VERSION" = "$WANT_VERSION" ] && pass "installed VERSION $GOT_VERSION is the latest tag" \
    || fail "installed VERSION $GOT_VERSION, latest tag is v$WANT_VERSION"
fi
echo "main is at $(awk '{print $NF}' .claude/VERSION), the install is at ${GOT_VERSION:-no VERSION}"

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "Installed tree matches the docs"
