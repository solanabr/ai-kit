#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

REGISTRY="$REPO_ROOT/.claude/skills/skill-registry.json"
HUB="$REPO_ROOT/.claude/skills/SKILL.md"
SKILLS_SH="$REPO_ROOT/.claude/bin/skills.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_skill_extensions] Core and extension skill packs"
echo ""

# ids of one tier, sorted, space-separated
tier_ids() {
  python3 - "$REGISTRY" "$1" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
print(" ".join(sorted(e["id"] for e in reg["entries"] if e.get("tier") == sys.argv[2])))
PY
}
ext_dirs() { ls "$1" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
sorted() { printf '%s\n' "$@" | awk 'NF' | sort | tr '\n' ' ' | sed 's/ $//'; }

CORE="$(tier_ids core)"
EXTENSIONS="$(tier_ids extension)"

# --- The registry and .gitmodules describe the same packs ---
echo "[registry]"
assert_json_valid "$REGISTRY" "skill-registry.json is valid JSON"
PROBLEMS="$(python3 - "$REGISTRY" "$REPO_ROOT/.gitmodules" <<'PY'
import json, re, sys
reg = json.load(open(sys.argv[1]))
paths = re.findall(r"^\s*path\s*=\s*(\S+)\s*$", open(sys.argv[2]).read(), re.M)
kit = [e for e in reg["entries"] if "tier" in e]
ids = [e["id"] for e in kit]
out = []
if len(ids) != len(set(ids)):
    out.append("duplicate pack ids")
for e in kit:
    i = e["id"]
    if e["tier"] not in ("core", "extension"):
        out.append(f"{i}: tier must be core or extension")
    if e.get("path") != f".claude/skills/ext/{i}":
        out.append(f"{i}: path must be .claude/skills/ext/{i}")
    if e.get("default_installed") is not (e["tier"] == "core"):
        out.append(f"{i}: default_installed must be true for core, false for extensions")
    if (e.get("install") or {}).get("command") != f"bash .claude/bin/skills.sh add {i}":
        out.append(f"{i}: install command must be bash .claude/bin/skills.sh add {i}")
    trig = e.get("triggers") or []
    if not trig or any(("," in t or '"' in t) for t in trig):
        out.append(f"{i}: needs triggers without commas or quotes")
for p in paths:
    if p not in [e.get("path") for e in kit]:
        out.append(f".gitmodules path {p} has no registry entry with a tier")
for e in kit:
    if e.get("path") not in paths:
        out.append(f"{e['id']}: not a submodule in .gitmodules")
print("\n".join(out) or "OK")
PY
)"
assert_eq "OK" "$PROBLEMS" "Every submodule has one registry entry (tier, path, triggers, install command) and vice versa"
TOTAL=$((TOTAL + 1))
if [ -n "$CORE" ] && [ -n "$EXTENSIONS" ]; then
  echo "  PASS: registry has core packs ($CORE) and extensions"
  PASS=$((PASS + 1))
else
  echo "  FAIL: registry needs both core packs and extensions"
  FAIL=$((FAIL + 1))
fi

# skills.sh parses the registry with awk (no jq or python on user machines), so its view
# must match a JSON parser's. A reformatted registry (keys not one per line) fails here.
LISTED="$(bash "$SKILLS_SH" list | awk '$2 == "core" || $2 == "extension" { print $1 "/" $2 }' | sort | tr '\n' ' ' | sed 's/ $//')"
EXPECTED="$(python3 - "$REGISTRY" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
print(" ".join(sorted(f'{e["id"]}/{e["tier"]}' for e in reg["entries"] if "tier" in e)))
PY
)"
assert_eq "$EXPECTED" "$LISTED" "skills.sh list reads the same packs and tiers as a JSON parser"
NO_TRIGGERS="$(bash "$SKILLS_SH" list | awk '($2 == "core" || $2 == "extension") && NF < 4 { print $1 }')"
assert_eq "" "$NO_TRIGGERS" "skills.sh list shows each pack's triggers"

# update.sh copies skills/ over the project's copy, so shipping the list would erase it
assert_file_not_exists "$REPO_ROOT/.claude/skills/extensions.txt" "The kit ships no skills/extensions.txt (it is per-project state)"

# --- The hub tells an agent when and how to install each extension ---
echo "[hub]"
for id in $EXTENSIONS; do
  assert_file_contains "$HUB" "| $id |" "Hub Extensions table has a row for $id"
  assert_file_contains "$HUB" "bash .claude/bin/skills.sh add $id\`" "Hub gives the install command for $id"
done
for id in $CORE; do
  assert_file_contains "$HUB" "$id" "Hub names core pack $id"
done

# --- Default install: core packs only ---
echo "[default install]"
P1="$TEMP_DIR/core-only"
mkdir -p "$P1" && (cd "$P1" && git init -q)
OUT="$(SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$P1" 2>&1)"
assert_eq "$CORE" "$(ext_dirs "$P1/.claude/skills/ext")" "Default install carries only the core packs"
assert_file_exists "$P1/.claude/skills/extensions.txt" "Install writes the project's extension list"
assert_eq "" "$(grep -v '^#' "$P1/.claude/skills/extensions.txt" || true)" "No extensions recorded by default"
assert_contains "$OUT" "skills.sh add <id>" "Install output says how to add an extension"

# A core-only install must not leave dead references: every ext/ link in the installed
# kit markdown resolves, or its line gives the install command for that pack.
DEAD="$(python3 - "$P1" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
cfg = os.path.join(root, ".claude")
files = [os.path.join(root, "CLAUDE.md")]
for pattern in ("agents/*.md", "commands/*.md", "skills/*.md", "skills/*/SKILL.md"):
    files += glob.glob(os.path.join(cfg, pattern))
checked, dead = 0, []
for f in files:
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        given = set()
        for ids in re.findall(r"skills\.sh add ((?:[a-z0-9-]+ ?)+)", line):
            given |= set(ids.split())
        for link in re.findall(r"\]\(([^)\s]*ext/[^)\s]*)\)", line):
            if link.startswith("http"):
                continue
            checked += 1
            if os.path.exists(os.path.normpath(os.path.join(os.path.dirname(f), link.split("#")[0]))):
                continue
            pack = re.search(r"ext/([a-z0-9-]+)", link).group(1)
            if pack not in given:
                dead.append(f"{os.path.relpath(f, root)}:{n} -> {link}")
print(f"checked={checked}")
print("\n".join(dead) or "OK")
PY
)"
assert_eq "OK" "$(printf '%s\n' "$DEAD" | tail -n +2)" "Core-only install: every ext/ link resolves or its line gives the install command ($(printf '%s\n' "$DEAD" | head -1))"

# --- Installing an extension on demand ---
echo "[add]"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add solana-game) >/dev/null 2>&1
assert_file_exists "$P1/.claude/skills/ext/solana-game/skill/SKILL.md" "skills.sh add installs an extension"
assert_file_contains "$P1/.claude/skills/extensions.txt" "solana-game" "The added extension is recorded"
assert_eq "0" "$(find "$P1/.claude/skills/ext/solana-game" -name .git | wc -l | tr -d ' ')" "Added pack carries no submodule gitfiles"
LIST_OUT="$(cd "$P1" && bash .claude/bin/skills.sh list)"
assert_contains "$(printf '%s\n' "$LIST_OUT" | grep '^solana-game ')" "installed" "skills.sh list shows solana-game installed"
AGAIN="$(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add solana-game 2>&1)"
assert_contains "$AGAIN" "already installed" "skills.sh add skips a pack that is already installed"
TOTAL=$((TOTAL + 1))
if (cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add no-such-pack) >/dev/null 2>&1; then
  echo "  FAIL: skills.sh add accepted an unknown pack"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: skills.sh add rejects an unknown pack"
  PASS=$((PASS + 1))
fi

# --- update.sh keeps what the project has, adds no other extensions ---
echo "[update]"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_eq "$(sorted $CORE solana-game)" "$(ext_dirs "$P1/.claude/skills/ext")" "update.sh keeps core packs and installed extensions, adds none"

# An install from before the split has every pack and no list: update keeps them all
echo "[legacy install]"
cp -R "$REPO_ROOT/.claude/skills/ext/." "$P1/.claude/skills/ext/"
rm -f "$P1/.claude/skills/extensions.txt"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_eq "$(sorted $CORE $EXTENSIONS)" "$(ext_dirs "$P1/.claude/skills/ext")" "Update keeps every pack of a pre-split install"
assert_eq "$(sorted $EXTENSIONS)" "$(grep -v '^#' "$P1/.claude/skills/extensions.txt" | sort | tr '\n' ' ' | sed 's/ $//')" "...and records them as its extensions"

# --- install.sh --with ---
echo "[--with]"
P2="$TEMP_DIR/with"
mkdir -p "$P2" && (cd "$P2" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --with sendai,jupiter "$P2" >/dev/null 2>&1
assert_eq "$(sorted $CORE sendai jupiter)" "$(ext_dirs "$P2/.claude/skills/ext")" "install.sh --with a,b adds those extensions"
TOTAL=$((TOTAL + 1))
if SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --with no-such-pack "$TEMP_DIR/bad" >/dev/null 2>&1; then
  echo "  FAIL: install.sh accepted an unknown --with pack"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: install.sh rejects an unknown --with pack"
  PASS=$((PASS + 1))
fi

# --- --agents installs use .agents/bin/skills.sh and .agents/skills/ext ---
echo "[--agents]"
P3="$TEMP_DIR/agents"
mkdir -p "$P3" && (cd "$P3" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents --with=solana-mobile "$P3" >/dev/null 2>&1
assert_eq "$(sorted $CORE solana-mobile)" "$(ext_dirs "$P3/.agents/skills/ext")" "--agents install carries core packs plus --with"
(cd "$P3" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/skills.sh add metaplex) >/dev/null 2>&1
assert_dir_exists "$P3/.agents/skills/ext/metaplex" ".agents/bin/skills.sh add installs into .agents/skills/ext"
assert_dir_not_exists "$P3/.claude" "--agents skills.sh writes nothing under .claude/"

print_summary
