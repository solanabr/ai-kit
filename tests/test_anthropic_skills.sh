#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

REGISTRY="$REPO_ROOT/.claude/skills/skill-registry.json"
SKILLS_SH="$REPO_ROOT/.claude/bin/skills.sh"
PACK="anthropic-skills"
# anthropics/skills ships these under terms that rule out installing them here:
# docx, pdf, pptx and xlsx are proprietary, doc-coauthoring has no license.
DENIED="docx pdf pptx xlsx doc-coauthoring"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_anthropic_skills] Anthropic's Apache-2.0 skills as a cross-agent extension"
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

field() {  # field <registry> <key>: the pack entry's value, arrays space-separated
  python3 - "$1" "$2" "$PACK" <<'PY'
import json, sys
entry = next(e for e in json.load(open(sys.argv[1], encoding="utf-8"))["entries"] if e["id"] == sys.argv[3])
value = entry.get(sys.argv[2], "")
print(" ".join(value) if isinstance(value, list) else value)
PY
}

set_field() {  # set_field <registry> <key> <JSON value>: rewrite that line of the pack entry, layout kept
  python3 - "$1" "$2" "$3" "$PACK" <<'PY'
import re, sys
path, key, value, pack = sys.argv[1:]
text = open(path, encoding="utf-8").read()
start = text.index('"id": "%s"' % pack)
end = text.index("\n    }", start)
entry, n = re.subn(r'^(      "%s": ).*?(,?)$' % re.escape(key), lambda m: m.group(1) + value + m.group(2),
                   text[start:end], count=1, flags=re.M)
assert n == 1, key
open(path, "w", encoding="utf-8").write(text[:start] + entry + text[end:])
PY
}

is_sha() { printf '%s\n' "$1" | grep -qxE '[0-9a-f]{40}'; }
not_listed() { case " $2 " in *" $1 "*) return 1 ;; esac; }
top_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//'; }
sorted() { printf '%s\n' "$@" | awk 'NF' | sort | tr '\n' ' ' | sed 's/ $//'; }

ALLOW="$(field "$REGISTRY" skills)"
FIRST="${ALLOW%% *}"
COMMIT="$(field "$REGISTRY" commit)"

# --- The registry entry: opt-in, pinned, allowlisted ---
echo "[registry]"
assert_eq "extension" "$(field "$REGISTRY" tier)" "$PACK is an extension, installed only on request"
check "$PACK is pinned to a full 40-character commit ($COMMIT)" is_sha "$COMMIT"
assert_eq "https://github.com/anthropics/skills" "$(field "$REGISTRY" source)" "$PACK comes from anthropics/skills"
assert_eq ".claude/skills" "$(field "$REGISTRY" path)" "$PACK installs top-level skills (.claude/skills/<name>/)"
check "$PACK lists the skills it installs" test -n "$ALLOW"
for name in $DENIED; do
  check "$name is not on the $PACK allowlist" not_listed "$name" "$ALLOW"
  check "skills.sh denies $name in code (DENIED_SKILLS)" grep -qE "^DENIED_SKILLS=\"([^\"]* )?$name( [^\"]*)?\"$" "$SKILLS_SH"
done
check "$PACK is not a submodule: nothing from anthropics/skills sits in the kit repo" test -z "$(grep 'anthropics/skills' "$REPO_ROOT/.gitmodules" || true)"
for name in $ALLOW; do
  assert_dir_not_exists "$REPO_ROOT/.claude/skills/$name" "The kit repo carries no copy of $name"
done
check "The kit ships no skills/*.lock (per-project state)" test -z "$(find "$REPO_ROOT/.claude/skills" -maxdepth 1 -name '*.lock')"

# --- Offline stand-in for anthropics/skills with every license case ---
# SKILL.md bodies mention .claude/ so the --agents path rewrite would show up in a diff.
FIX="$TEMP_DIR/mirror/$PACK"
# The full Apache-2.0 text, and frontend-design's variant: the same text cut off
# before the APPENDIX.
APACHE="$(cat "$SCRIPT_DIR/fixtures/apache-2.0-LICENSE.txt")"
APACHE_NO_APPENDIX="$(sed '/END OF TERMS AND CONDITIONS/q' "$SCRIPT_DIR/fixtures/apache-2.0-LICENSE.txt")"
PROPRIETARY="(c) 2025 Anthropic, PBC. All rights reserved."
fixture_skill() {  # fixture_skill <folder> <LICENSE.txt text, empty for none> [frontmatter name]
  mkdir -p "$FIX/skills/$1"
  printf -- '---\nname: %s\ndescription: Fixture copy of %s.\n---\n\nSee .claude/skills/ for more.\n' "${3:-$1}" "${3:-$1}" > "$FIX/skills/$1/SKILL.md"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$FIX/skills/$1/LICENSE.txt"; fi
}
for name in $ALLOW theme-factory; do fixture_skill "$name" "$APACHE"; done
fixture_skill "${ALLOW##* }" "$APACHE_NO_APPENDIX"
mkdir -p "$FIX/skills/$FIRST/scripts" && printf 'print("fixture")\n' > "$FIX/skills/$FIRST/scripts/helper.py"
for name in docx pdf pptx xlsx; do fixture_skill "$name" "$PROPRIETARY"; done
fixture_skill doc-coauthoring ""
fixture_skill mit-skill "MIT License"
fixture_skill renamed "$APACHE" other-name
# Licenses that name Apache 2.0 without being it: a denial, and the real text plus a reservation.
fixture_skill denies-apache "This work is NOT offered under the Apache License. Version 2.0 of our PROPRIETARY terms applies. No redistribution."
fixture_skill apache-reserved "$(printf '%s\n\n%s' "$APACHE" "Copyright 2026 Example Corp. All rights reserved.")"
fixture_skill apache-copyright "$(printf '%s\n' "$APACHE" | sed 's/Copyright \[yyyy\] \[name of copyright owner\]/Copyright 2026 Anthropic, PBC./')"
fixture_skill apache-copyright-prose "$(printf '%s\n' "$APACHE" | sed 's/Copyright \[yyyy\] \[name of copyright owner\]/Copyright 2026 Anthropic, PBC. NOT LICENSED for use outside Anthropic products. Proprietary and confidential./')"
# Nested folders travel with the copy: a denied skill, or another license, inside an Apache one.
fixture_skill nests-docx "$APACHE"
fixture_skill nests-docx/vendor/docx "$PROPRIETARY" docx
fixture_skill nests-license "$APACHE"
mkdir -p "$FIX/skills/nests-license/lib" && printf 'MIT License\n' > "$FIX/skills/nests-license/lib/LICENSE"
fixture_commit() {
  git -C "$FIX" add -A
  git -C "$FIX" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -qm "$1"
  git -C "$FIX" rev-parse HEAD
}
git -c init.defaultBranch=main init -q "$FIX"
git -C "$FIX" config uploadpack.allowFilter true
PIN="$(fixture_commit fixture)"
export SOLANA_AI_KIT_PACK_MIRROR="$TEMP_DIR/mirror"

# A kit checkout pinning the fixture: the real .claude/ with only the core packs in ext/.
KIT="$TEMP_DIR/kit"
mkdir -p "$KIT/.claude/skills/ext"
for f in "$REPO_ROOT"/.claude/*; do [ "$(basename "$f")" = skills ] || cp -R "$f" "$KIT/.claude/"; done
for f in "$REPO_ROOT"/.claude/skills/*; do [ "$(basename "$f")" = ext ] || cp -R "$f" "$KIT/.claude/skills/"; done
CORE="$(python3 -c 'import json, sys; print(" ".join(e["id"] for e in json.load(open(sys.argv[1]))["entries"] if e.get("tier") == "core"))' "$REGISTRY")"
for id in $CORE; do cp -R "$REPO_ROOT/.claude/skills/ext/$id" "$KIT/.claude/skills/ext/"; done
cp "$REPO_ROOT/CLAUDE-solana.md" "$REPO_ROOT/.mcp.json" "$REPO_ROOT/.env.example" "$REPO_ROOT/.gitmodules" "$KIT/"
set_field "$KIT/.claude/skills/skill-registry.json" commit "\"$PIN\""
install_kit() { SOLANA_AI_KIT_LOCAL_SRC="$KIT" bash "$REPO_ROOT/install.sh" "$@" >/dev/null 2>&1; }
new_project() { mkdir -p "$TEMP_DIR/$1" && git -C "$TEMP_DIR/$1" init -q && echo "$TEMP_DIR/$1"; }

# --- Default install: top-level skills in .claude/skills/, copied unchanged ---
echo "[install --with $PACK]"
P1="$(new_project default)"
install_kit --with "$PACK" "$P1"
for name in $ALLOW; do
  check "$name is installed as a top-level skill in .claude/skills/" test -f "$P1/.claude/skills/$name/SKILL.md"
  check "$name is an unchanged copy, LICENSE.txt included" diff -r "$FIX/skills/$name" "$P1/.claude/skills/$name"
done
for name in $DENIED; do
  assert_eq "" "$(grep -rl "Fixture copy of $name\." "$P1" || true)" "No copy of $name anywhere in the project"
done
for name in theme-factory mit-skill renamed; do
  assert_dir_not_exists "$P1/.claude/skills/$name" "$name is not on the allowlist, so it is not installed"
done
assert_dir_not_exists "$P1/.claude/skills/ext/$PACK" "$PACK is not vendored under ext/"
assert_file_contains "$P1/.claude/skills/extensions.txt" "$PACK" "$PACK is recorded, so /update keeps it"
assert_file_contains "$P1/.claude/skills/$PACK.lock" "commit $PIN" "The lock records the pinned commit"
assert_contains "$(bash "$P1/.claude/bin/skills.sh" list | grep "^$PACK ")" "installed" "skills.sh list shows $PACK installed"
assert_contains "$(bash "$P1/.claude/bin/skills.sh" add "$PACK" 2>&1)" "already installed" "skills.sh add skips $PACK when it is at the pin"

# --- --agents: .agents/skills/<name>/ for Codex and the other Agent Skills clients ---
echo "[install --agents --with $PACK]"
P2="$(new_project agents)"
install_kit --agents --with="$PACK" "$P2"
for name in $ALLOW; do
  check "$name is installed in .agents/skills/" test -f "$P2/.agents/skills/$name/SKILL.md"
  check "$name is unchanged in --agents mode (no .claude/ path rewrite)" diff -r "$FIX/skills/$name" "$P2/.agents/skills/$name"
done
assert_dir_not_exists "$P2/.claude" "--agents install writes nothing under .claude/"

# --- On demand, then through update.sh ---
echo "[skills.sh add + update.sh]"
P3="$(new_project on-demand)"
install_kit "$P3"
assert_dir_not_exists "$P3/.claude/skills/$FIRST" "A default install carries no $PACK skill"
bash "$P3/.claude/bin/skills.sh" add "$PACK" >/dev/null 2>&1
for name in $ALLOW; do
  check "skills.sh add installs $name" test -f "$P3/.claude/skills/$name/SKILL.md"
done
SOLANA_AI_KIT_LOCAL_SRC="$KIT" bash "$P3/.claude/bin/update.sh" >/dev/null 2>&1
check "update.sh keeps $PACK" diff -r "$FIX/skills/$FIRST" "$P3/.claude/skills/$FIRST"
printf '\nRevised upstream.\n' >> "$FIX/skills/$FIRST/SKILL.md"
PIN2="$(fixture_commit revise)"
set_field "$KIT/.claude/skills/skill-registry.json" commit "\"$PIN2\""
SOLANA_AI_KIT_LOCAL_SRC="$KIT" bash "$P3/.claude/bin/update.sh" >/dev/null 2>&1
check "update.sh moves $PACK to the commit the new kit pins" diff -r "$FIX/skills/$FIRST" "$P3/.claude/skills/$FIRST"
assert_file_contains "$P3/.claude/skills/$PACK.lock" "commit $PIN2" "...and records it in the lock"
grep -vx "$PACK" "$P3/.claude/skills/extensions.txt" > "$TEMP_DIR/extensions.txt" || true
cp "$TEMP_DIR/extensions.txt" "$P3/.claude/skills/extensions.txt"
SOLANA_AI_KIT_LOCAL_SRC="$KIT" bash "$P3/.claude/bin/update.sh" >/dev/null 2>&1
assert_dir_not_exists "$P3/.claude/skills/$FIRST" "update.sh removes $PACK's skills once the project drops it from extensions.txt"
assert_file_not_exists "$P3/.claude/skills/$PACK.lock" "...and its lock"

# --- Refusals: the denylist lives in code, and licenses and names are checked ---
echo "[refusals]"
P4="$(new_project refusals)"
install_kit "$P4"
REG4="$P4/.claude/skills/skill-registry.json"
try_add() {  # try_add <key> <JSON value>: set that registry field in P4, then add the pack
  set_field "$REG4" "$1" "$2"
  bash "$P4/.claude/bin/skills.sh" add "$PACK" 2>&1
}
refused() {  # refused <message> <expected output> <key> <JSON value>
  local out status=0
  out="$(try_add "$3" "$4")" || status=$?
  TOTAL=$((TOTAL + 1))
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$2"; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (exit $status: $out)"
    FAIL=$((FAIL + 1))
  fi
}
# The denylist answers before any fetch, so its message differs from the license check's.
for name in $DENIED; do
  refused "skills.sh add refuses $name even when the registry lists it" "refusing $name: its license" skills "[\"$FIRST\", \"$name\"]"
  assert_dir_not_exists "$P4/.claude/skills/$name" "...installs no $name"
  assert_dir_not_exists "$P4/.claude/skills/$FIRST" "...and nothing else from the pack"
done
refused "skills.sh add refuses a skill without an Apache-2.0 LICENSE.txt" "no Apache-2.0 LICENSE.txt" skills '["mit-skill"]'
assert_dir_not_exists "$P4/.claude/skills/mit-skill" "...and installs nothing"
refused "skills.sh add refuses a LICENSE.txt that names Apache 2.0 but is not its text" "no Apache-2.0 LICENSE.txt" skills '["denies-apache"]'
refused "skills.sh add refuses the Apache-2.0 text with \"All rights reserved\" added" "reserves rights" skills '["apache-reserved"]'
assert_dir_not_exists "$P4/.claude/skills/apache-reserved" "...and installs nothing"
refused "skills.sh add refuses the Apache-2.0 text with prose added to its copyright line" "no Apache-2.0 LICENSE.txt" skills '["apache-copyright-prose"]'
assert_dir_not_exists "$P4/.claude/skills/apache-copyright-prose" "...and installs nothing"
refused "skills.sh add refuses a denied skill nested inside an allowed folder" "contains vendor/docx/SKILL.md, a skill the kit refuses" skills '["nests-docx"]'
assert_dir_not_exists "$P4/.claude/skills/nests-docx" "...and installs nothing"
refused "skills.sh add refuses a nested license file that is not Apache-2.0" "lib/LICENSE is not an Apache-2.0 license" skills '["nests-license"]'
check "skills.sh add accepts the Apache-2.0 text with its copyright line filled in" try_add skills '["apache-copyright"]'
check "...and installs it" test -f "$P4/.claude/skills/apache-copyright/SKILL.md"
rm -rf "${P4:?}/.claude/skills/apache-copyright" "$P4/.claude/skills/$PACK.lock"
grep -vx "$PACK" "$P4/.claude/skills/extensions.txt" > "$TEMP_DIR/extensions.txt" || true
cp "$TEMP_DIR/extensions.txt" "$P4/.claude/skills/extensions.txt"
refused "skills.sh add refuses a folder whose SKILL.md carries another name" "is named 'other-name'" skills '["renamed"]'
refused "skills.sh add refuses a name that is not a plain skill name" "invalid skill name" skills '["../escape"]'
mkdir -p "$P4/.claude/skills/$FIRST" && printf 'mine\n' > "$P4/.claude/skills/$FIRST/SKILL.md"
refused "skills.sh add will not replace a $FIRST folder the kit did not install" "was not installed by the kit" skills "[\"$FIRST\"]"
assert_eq "mine" "$(cat "$P4/.claude/skills/$FIRST/SKILL.md")" "...and leaves that folder as it was"
rm -rf "${P4:?}/.claude/skills/$FIRST"
refused "skills.sh add needs a full commit SHA" "full 40-character SHA" commit '"8a1541c"'
refused "skills.sh add fails cleanly when the pinned commit is not upstream" "could not fetch" commit '"0000000000000000000000000000000000000000"'
assert_dir_not_exists "$P4/.claude/skills/$FIRST" "...and installs nothing"
check "No refused attempt is recorded as installed" test -z "$(grep -x "$PACK" "$P4/.claude/skills/extensions.txt" || true)"

# --- Lock state: an unfinished copy, and a denied skill the lock claims ---
echo "[lock state]"
list_state() { bash "$1/.claude/bin/skills.sh" list | awk -v p="$PACK" '$1 == p { print $3 }'; }
P6="$(new_project lock-state)"
install_kit --with "$PACK" "$P6"
LOCK6="$P6/.claude/skills/$PACK.lock"
sed 's/^commit .*/commit pending/' "$LOCK6" > "$TEMP_DIR/pending.lock" && cp "$TEMP_DIR/pending.lock" "$LOCK6"
rm -rf "${P6:?}/.claude/skills/$FIRST"
assert_eq "-" "$(list_state "$P6")" "skills.sh list does not report a pack whose lock is still pending as installed"
P7="$(new_project denied-lock)"
install_kit --with "$PACK" "$P7"
set_field "$P7/.claude/skills/skill-registry.json" skills "[$(for n in $ALLOW docx; do printf '"%s", ' "$n"; done | sed 's/, $//')]"
printf 'skill docx\n' >> "$P7/.claude/skills/$PACK.lock"
fixture_skill docx "$PROPRIETARY" && cp -R "$FIX/skills/docx" "$P7/.claude/skills/docx"
PRUNE="$(bash "$P7/.claude/bin/skills.sh" prune 2>&1 || true)"
assert_contains "$PRUNE" "refusing docx" "A registry and lock that both list docx do not pass as current"
assert_dir_not_exists "$P7/.claude/skills/docx" "...and the docx folder the lock claimed is removed"

# --- The real anthropics/skills at the pinned commit (network) ---
echo "[anthropics/skills at the pin]"
unset SOLANA_AI_KIT_PACK_MIRROR
P5="$TEMP_DIR/upstream"
mkdir -p "$P5/.claude/bin" "$P5/.claude/skills"
cp "$SKILLS_SH" "$P5/.claude/bin/"
cp "$REGISTRY" "$P5/.claude/skills/"
upstream_add() { bash "$P5/.claude/bin/skills.sh" add "$PACK" >/dev/null 2>&1; }
if upstream_add || upstream_add; then
  assert_file_contains "$P5/.claude/skills/$PACK.lock" "commit $COMMIT" "The pinned commit $COMMIT resolves in anthropics/skills"
  assert_eq "$(sorted $ALLOW)" "$(top_dirs "$P5/.claude/skills")" "Only the allowlisted skills are installed from anthropics/skills"
  VALID="$(python3 - "$P5/.claude/skills" $ALLOW <<'PY'
import os, re, sys

def frontmatter(text):
    m = re.match(r"---\r?\n(.*?)\r?\n---\r?\n", text, re.S)
    if not m:
        return None
    fields, key = {}, None
    for line in m.group(1).splitlines():
        if line[:1] in (" ", "\t"):
            if key:
                fields[key] = (fields[key] + " " + line.strip()).strip()
            continue
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        fields[key] = "" if value in (">", "|", ">-", "|-") else value.strip("\"'")
    return fields

root, problems = sys.argv[1], []
for name in sys.argv[2:]:
    folder = os.path.join(root, name)
    lic = os.path.join(folder, "LICENSE.txt")
    text = open(lic, encoding="utf-8").read() if os.path.isfile(lic) else ""
    if "Apache License" not in text or "Version 2.0" not in text:
        problems.append(f"{name}: LICENSE.txt is not the Apache License 2.0")
    fm = frontmatter(open(os.path.join(folder, "SKILL.md"), encoding="utf-8").read())
    if fm is None:
        problems.append(f"{name}: SKILL.md has no frontmatter")
        continue
    if fm.get("name") != name:
        problems.append(f"{name}: frontmatter name is {fm.get('name')!r}")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name) or len(name) > 64:
        problems.append(f"{name}: not a valid Agent Skills name")
    if not 1 <= len(fm.get("description", "")) <= 1024:
        problems.append(f"{name}: description is {len(fm.get('description', ''))} chars, not 1-1024")
    for top, dirs, files in os.walk(folder):
        problems += [f"{name}: symlink {os.path.join(top, x)}" for x in dirs + files if os.path.islink(os.path.join(top, x))]
print("\n".join(problems) or "OK")
PY
)"
  assert_eq "OK" "$VALID" "At the pin, each skill has an Apache-2.0 LICENSE.txt and Agent Skills frontmatter (name = folder, description <= 1024 chars)"
elif [ -n "${CI:-}" ] || git ls-remote https://github.com/anthropics/skills.git HEAD >/dev/null 2>&1; then
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: skills.sh add $PACK from github.com at $COMMIT"
  bash "$P5/.claude/bin/skills.sh" add "$PACK" 2>&1 | sed 's/^/    /' || true
elif [ "${ALLOW_OFFLINE:-}" = 1 ]; then
  echo "  SKIP: github.com is unreachable here (ALLOW_OFFLINE=1); the pin $COMMIT is NOT checked"
else
  # A pin bump is checked here; passing without the network would bless a commit that may not exist.
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: github.com is unreachable, so the pin $COMMIT was not checked (ALLOW_OFFLINE=1 skips this)"
fi

print_summary
