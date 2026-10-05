#!/usr/bin/env bash
set -euo pipefail

# skills_root: where an upstream pack's skill folders sit in ITS tree.
#
# The folder-fetch route (a "skills" list in the registry entry) assumed the folders
# were at skills/<name>. Packs that nest them deeper — stripe/ai keeps its at
# providers/agent-plugins/plugin/skills/<name> — need the source prefix to move while
# the destination stays <cfg>/skills/<name>/, which is the only layout the host
# auto-discovers. Absent, the field defaults to "skills", so every existing entry is
# unaffected.
#
# Why the route matters beyond layout: it copies ONLY the named folders, so a symlink
# elsewhere in the upstream tree is never touched. stripe/ai's four dangling
# LICENSE -> LICENSE links live outside its skills subtree, and cp aborts on a dangling
# link, so fetching folder-by-folder is what makes such a pack copyable at all.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SKILLS_SH="$REPO_ROOT/.claude/bin/skills.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_skills_root] upstream packs whose skill folders are not at skills/"
echo ""

check() {  # check <message> <command...>: passes when the command succeeds
  local message="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message"
    FAIL=$((FAIL + 1))
  fi
}

refute() {  # refute <message> <command...>: passes when the command fails
  local message="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: $message"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  fi
}

APACHE="$(cat "$SCRIPT_DIR/fixtures/apache-2.0-LICENSE.txt" 2>/dev/null || true)"
if [ -z "$APACHE" ]; then
  # The suite's own Apache copy is the only text check_skill accepts; without it
  # there is nothing to assert against.
  echo "  SKIP: no tests/fixtures/apache-2.0-LICENSE.txt to build a passing fixture from"
  print_summary
  exit 0
fi

# --- A fixture repo with its skills nested, plus one at the default location ---
FIX="$TEMP_DIR/mirror/nested-pack"
mkdir -p "$FIX/providers/agent-plugins/plugin/skills/deep-skill" "$FIX/skills/shallow-skill"
for d in "$FIX/providers/agent-plugins/plugin/skills/deep-skill:deep-skill" \
         "$FIX/skills/shallow-skill:shallow-skill"; do
  dir="${d%%:*}"; name="${d##*:}"
  printf -- '---\nname: %s\ndescription: fixture\n---\n\nbody\n' "$name" > "$dir/SKILL.md"
  printf '%s\n' "$APACHE" > "$dir/LICENSE.txt"
done
# A symlink OUTSIDE the skills subtree, dangling the way stripe/ai's four are. The
# fetch must never reach it.
ln -s LICENSE "$FIX/providers/LICENSE"

git -c init.defaultBranch=main init -q "$FIX"
git -C "$FIX" config uploadpack.allowFilter true
git -C "$FIX" add -A
git -C "$FIX" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -qm fixture
PIN="$(git -C "$FIX" rev-parse HEAD)"

export SOLANA_AI_KIT_PACK_MIRROR="$TEMP_DIR/mirror"

# --- A project config dir with a registry naming that pack ---
write_registry() {  # write_registry <skills_root-line> <skill-name>
  local rootline="$1" skill="$2"
  mkdir -p "$CFG/skills"
  cat > "$CFG/skills/skill-registry.json" <<JSON
{
  "version": "1.2",
  "entries": [
    {
      "id": "nested-pack",
      "name": "Nested Pack",
      "type": "skill",
      "tier": "extension",
      "domain": "testing-qa",
      "path": ".claude/skills",
      "commit": "$PIN",
      "skills": ["$skill"],${rootline}
      "description": "fixture",
      "triggers": ["fixture"],
      "source": "https://example.invalid/nested-pack",
      "install": { "method": "kit", "command": "bash .claude/bin/skills.sh add nested-pack", "env": [] },
      "license": "Apache-2.0",
      "maintainer": "test",
      "signal": { "stars": 0, "last_commit": "2026-01-01", "reputability": "org" },
      "default_installed": false,
      "safety": "fixture",
      "tags": ["fixture"]
    }
  ]
}
JSON
}

run_add() { bash "$SKILLS_SH" add nested-pack; }

# 1. A nested root installs to skills/<name>/ anyway.
CFG="$TEMP_DIR/p1/.claude"
mkdir -p "$CFG/bin" && cp "$SKILLS_SH" "$CFG/bin/skills.sh"
SKILLS_SH="$CFG/bin/skills.sh"
write_registry $'\n      "skills_root": "providers/agent-plugins/plugin/skills",' deep-skill
check "a nested skills_root fetches and installs" run_add
check "it lands at skills/<name>/, not under the nested path" \
  test -f "$CFG/skills/deep-skill/SKILL.md"
check "its LICENSE.txt travels with the copy" \
  test -f "$CFG/skills/deep-skill/LICENSE.txt"
refute "nothing outside the skills subtree is copied" \
  test -e "$CFG/skills/deep-skill/../providers"

# 2. No skills_root still means skills/.
CFG="$TEMP_DIR/p2/.claude"
mkdir -p "$CFG/bin" && cp "$REPO_ROOT/.claude/bin/skills.sh" "$CFG/bin/skills.sh"
SKILLS_SH="$CFG/bin/skills.sh"
write_registry "" shallow-skill
check "an entry with no skills_root defaults to skills/" run_add
check "the default-root skill installs" test -f "$CFG/skills/shallow-skill/SKILL.md"

# 3. A traversing or absolute root is refused before any fetch.
for bad in "../escape" "/etc" "a b"; do
  CFG="$TEMP_DIR/p-bad/.claude"
  rm -rf "$TEMP_DIR/p-bad"
  mkdir -p "$CFG/bin" && cp "$REPO_ROOT/.claude/bin/skills.sh" "$CFG/bin/skills.sh"
  SKILLS_SH="$CFG/bin/skills.sh"
  write_registry $'\n      "skills_root": "'"$bad"$'",' deep-skill
  refute "skills_root '$bad' is refused" run_add
done

# 4. Every registry entry that declares skills_root is a folder-fetch pack (has
#    a skills list), since the field is meaningless otherwise.
REG="$REPO_ROOT/.claude/skills/skill-registry.json"
BAD_ROOT="$(python3 - "$REG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(e["id"] for e in d["entries"]
                if "skills_root" in e and "skills" not in e))
PY
)"
TOTAL=$((TOTAL + 1))
if [ -z "$BAD_ROOT" ]; then
  echo "  PASS: no entry declares skills_root without a skills list"
  PASS=$((PASS + 1))
else
  echo "  FAIL: skills_root on a non-folder-fetch entry: $BAD_ROOT"
  FAIL=$((FAIL + 1))
fi

print_summary
