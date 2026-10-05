#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

REGISTRY="$REPO_ROOT/.claude/skills/skill-registry.json"
HUB="$REPO_ROOT/.claude/skills/SKILL.md"
SKILLS_SH="$REPO_ROOT/.claude/bin/skills.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

# One core pack (anthropic-skills) is fetched from its own upstream rather than vendored
# from a kit submodule. helpers.sh points its source at a path that does not exist, so the
# install must warn and carry on, which is asserted below. The success path for that pack
# lives in tests/test_anthropic_skills.sh, which builds a real mirror.

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
# Core packs that land in ext/. A core pack with a "skills" list installs top-level
# instead (skills/<name>/), so comparisons against ext/ must not expect it there.
KIT_CORE="$(python3 - "$REGISTRY" <<'PY2'
import json, sys
reg = json.load(open(sys.argv[1]))
print(" ".join(sorted(e["id"] for e in reg["entries"] if e.get("tier") == "core" and "skills" not in e)))
PY2
)"
# Extensions vendored from a kit submodule into ext/. A pack with a "skills" list is
# fetched from its upstream repo into top-level skill folders instead
# (tests/test_anthropic_skills.sh). Every pack, both kinds, carries a "commit".
KIT_EXTENSIONS="$(python3 - "$REGISTRY" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
print(" ".join(sorted(e["id"] for e in reg["entries"] if e.get("tier") == "extension" and "skills" not in e)))
PY
)"

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
    # Two statements of one fact: installers read the tier, humans read the flag.
    if e.get("default_installed") is not (e["tier"] == "core"):
        out.append(f"{i}: default_installed must agree with tier {e['tier']}")
    # The pin a user project carries. validate.sh checks a submodule's against the gitlink;
    # skills.sh asserts an upstream pack's against FETCH_HEAD.
    if not re.fullmatch(r"[0-9a-f]{40}", e.get("commit", "")):
        out.append(f"{i}: needs a 40-character commit")
    if "skills" in e:
        # Either tier may be an upstream pack; skills.sh fetches core ones through
        # wanted_upstream(), since only extensions reach it through "keep".
        if e.get("path") != ".claude/skills":
            out.append(f"{i}: a pack with a skills list must have path .claude/skills")
    elif e.get("path") != f".claude/skills/ext/{i}":
        out.append(f"{i}: path must be .claude/skills/ext/{i}")
    for sub, sha in (e.get("vendored") or {}).items():
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            out.append(f"{i}: vendored {sub} needs a 40-character commit")
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
    if "skills" not in e and e.get("path") not in paths:
        out.append(f"{e['id']}: not a submodule in .gitmodules")
print("\n".join(out) or "OK")
PY
)"
assert_eq "OK" "$PROBLEMS" "Every submodule has one registry entry (tier, path, triggers, install command) and vice versa"
# A renamed upstream keeps working through GitHub's redirect until the old name is reused,
# so .gitmodules must clone the repo the registry names, not a redirect to it.
URL_DRIFT="$(python3 - "$REGISTRY" "$REPO_ROOT/.gitmodules" <<'PY'
import json, re, sys
reg = json.load(open(sys.argv[1]))
src = {e.get("path"): e.get("source", "") for e in reg["entries"] if "tier" in e}
norm = lambda u: re.sub(r"(\.git)?/*$", "", u.strip()).lower()
out = []
for sec in re.split(r"^\[submodule ", open(sys.argv[2]).read(), flags=re.M)[1:]:
    path = re.search(r"^\s*path\s*=\s*(\S+)", sec, re.M)
    url = re.search(r"^\s*url\s*=\s*(\S+)", sec, re.M)
    if path and url and path.group(1) in src and norm(url.group(1)) != norm(src[path.group(1)]):
        out.append(f"{path.group(1)}: .gitmodules url {url.group(1)} != registry source {src[path.group(1)]}")
print("\n".join(out) or "OK")
PY
)"
assert_eq "OK" "$URL_DRIFT" "Every .gitmodules url matches its registry source (ignoring .git and trailing /)"
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
assert_eq "$KIT_CORE" "$(ext_dirs "$P1/.claude/skills/ext")" "Default install carries only the core packs"
assert_file_exists "$P1/.claude/skills/extensions.txt" "Install writes the project's extension list"
assert_eq "" "$(grep -v '^#' "$P1/.claude/skills/extensions.txt" || true)" "No extensions recorded by default"
assert_contains "$OUT" "skills.sh add <id>" "Install output says how to add an extension"
assert_contains "$OUT" "anthropic-skills was not installed" "An unreachable core upstream pack warns..."
assert_contains "$OUT" "Installation complete!" "...and the install still finishes, unlike a core submodule pack that fails to fetch"

# A core-only install must not leave dead references: every ext/ link in the installed
# kit markdown resolves, or its line gives the install command for that pack.
DEAD="$(python3 - "$P1" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
cfg = os.path.join(root, ".claude")
files = [os.path.join(root, "CLAUDE.md")]
for pattern in ("agents/*.md", "commands/*.md", "skills/*.md", "skills/*/SKILL.md"):
    files += glob.glob(os.path.join(cfg, pattern))
checked, uninit, dead = 0, 0, []

def not_checked_out(resolved):
    """A pack folder that is present but empty: the submodule was never checked out, so
    the install vendored nothing. A pack that IS there with the file missing is not this
    case and stays dead."""
    m = re.match(r"(.*/skills/ext/[^/]+)(?:/|$)", resolved)
    return bool(m) and os.path.isdir(m.group(1)) and not os.listdir(m.group(1))

for f in files:
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        given = set()
        for ids in re.findall(r"skills\.sh add ((?:[a-z0-9-]+ ?)+)", line):
            given |= set(ids.split())
        for link in re.findall(r"\]\(([^)\s]*ext/[^)\s]*)\)", line):
            if link.startswith("http"):
                continue
            resolved = os.path.normpath(os.path.join(os.path.dirname(f), link.split("#")[0]))
            if os.path.exists(resolved):
                checked += 1
                continue
            if not_checked_out(resolved):
                uninit += 1
                continue
            checked += 1
            pack = re.search(r"ext/([a-z0-9-]+)", link).group(1)
            if pack not in given:
                dead.append(f"{os.path.relpath(f, root)}:{n} -> {link}")
print(f"checked={checked} not-checked-out={uninit}")
print("\n".join(dead) or "OK")
PY
)"
assert_eq "OK" "$(printf '%s\n' "$DEAD" | tail -n +2)" "Core-only install: every ext/ link resolves or its line gives the install command ($(printf '%s\n' "$DEAD" | head -1))"
UNINIT_LINKS="$(printf '%s\n' "$DEAD" | sed -nE '1s/.*not-checked-out=([0-9]+).*/\1/p')"
if [ "${UNINIT_LINKS:-0}" -gt 0 ]; then
  skip "Core-only install: $UNINIT_LINKS ext/ links into core packs that are not checked out"
fi

# Everything from here on copies real pack content: skills.sh refuses an empty pack
# outright ("<id> is empty in <repo> (run: git submodule update --init there)"), so
# without a checkout these blocks can only report that, and the suite used to die here
# under set -e with no summary at all. The blocks above need no pack content and have
# already run. One skip line stands for the whole region rather than per check, because
# the checks are never reached to be counted.
if ext_packs_uninitialized; then
  skip "[add] onwards: adding, updating and pruning packs needs the ext/ packs checked out"
  SUMMARY_RC=0
  print_summary || SUMMARY_RC=$?
  exit "$SUMMARY_RC"
fi

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

# A partial pack counts as installed; add --force reinstalls it
rm -f "$P1/.claude/skills/ext/solana-game/skill/SKILL.md"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add --force solana-game) >/dev/null 2>&1
assert_file_exists "$P1/.claude/skills/ext/solana-game/skill/SKILL.md" "skills.sh add --force restores a truncated pack"
assert_eq "1" "$(grep -cx solana-game "$P1/.claude/skills/extensions.txt")" "...and records it once"

# The copy goes through a staging folder: a failed or killed copy leaves no ext/<id>
SHIM="$TEMP_DIR/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\n/bin/cp "$@"\nexit 1\n' > "$SHIM/cp"
chmod +x "$SHIM/cp"
TOTAL=$((TOTAL + 1))
if (cd "$P1" && PATH="$SHIM:$PATH" SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add sendai) >/dev/null 2>&1; then
  echo "  FAIL: skills.sh add reported success after its copy failed"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: skills.sh add fails when its copy fails"
  PASS=$((PASS + 1))
fi
assert_dir_not_exists "$P1/.claude/skills/ext/sendai" "A failed copy leaves no ext/sendai"
assert_eq "" "$(ls -A "$P1/.claude/skills/ext" | grep partial || true)" "A failed copy leaves no staging folder"
assert_file_not_contains "$P1/.claude/skills/extensions.txt" "sendai" "A failed copy is not recorded"
# SIGKILL mid-copy: no trap runs, so the staging folder stays, but ext/sendai does not exist
printf '#!/bin/sh\n/bin/cp "$@"\nkill -9 $PPID\n' > "$SHIM/cp"
(cd "$P1" && PATH="$SHIM:$PATH" SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add sendai) >/dev/null 2>&1 || true
assert_dir_not_exists "$P1/.claude/skills/ext/sendai" "A killed copy leaves no ext/sendai"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/skills.sh add sendai) >/dev/null 2>&1
assert_dir_exists "$P1/.claude/skills/ext/sendai" "The next add installs the pack a killed copy left out"
assert_eq "" "$(ls -A "$P1/.claude/skills/ext" | grep partial || true)" "...and removes the staging folder the kill left"
rm -rf "$P1/.claude/skills/ext/sendai"
grep -vx sendai "$P1/.claude/skills/extensions.txt" > "$TEMP_DIR/ext.txt" && mv "$TEMP_DIR/ext.txt" "$P1/.claude/skills/extensions.txt"

# --- update.sh keeps what the project has, adds no other extensions ---
echo "[update]"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_eq "$(sorted $KIT_CORE solana-game)" "$(ext_dirs "$P1/.claude/skills/ext")" "update.sh keeps core packs and installed extensions, adds none"

# An install from before the split has every pack and no list: update keeps them all
echo "[legacy install]"
cp -R "$REPO_ROOT/.claude/skills/ext/." "$P1/.claude/skills/ext/"
rm -f "$P1/.claude/skills/extensions.txt"
(cd "$P1" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) >/dev/null 2>&1
assert_eq "$(sorted $KIT_CORE $KIT_EXTENSIONS)" "$(ext_dirs "$P1/.claude/skills/ext")" "Update keeps every pack of a pre-split install"
assert_eq "$(sorted $KIT_EXTENSIONS)" "$(grep -v '^#' "$P1/.claude/skills/extensions.txt" | sort | tr '\n' ' ' | sed 's/ $//')" "...and records them as its extensions"

# --- install.sh --with ---
echo "[--with]"
P2="$TEMP_DIR/with"
mkdir -p "$P2" && (cd "$P2" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --with sendai,jupiter "$P2" >/dev/null 2>&1
assert_eq "$(sorted $KIT_CORE sendai jupiter)" "$(ext_dirs "$P2/.claude/skills/ext")" "install.sh --with a,b adds those extensions"
TOTAL=$((TOTAL + 1))
if SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --with no-such-pack "$TEMP_DIR/bad" >/dev/null 2>&1; then
  echo "  FAIL: install.sh accepted an unknown --with pack"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: install.sh rejects an unknown --with pack"
  PASS=$((PASS + 1))
fi

# --- A pack the registry no longer lists goes; folders the user made stay ---
echo "[orphans]"
assert_file_not_exists "$REPO_ROOT/.claude/skills/kit-packs.txt" "The kit ships no skills/kit-packs.txt (it is per-project state)"
assert_eq "$(sorted $CORE sendai jupiter)" "$(grep -v '^#' "$P2/.claude/skills/kit-packs.txt" | sort | tr '\n' ' ' | sed 's/ $//')" "Install records the packs it put in the project"
mkdir -p "$P2/.claude/skills/ext/old-core/x" "$P2/.claude/skills/ext/old-ext/x" "$P2/.claude/skills/ext/my-pack/x" "$P2/.claude/skills/ext/jupiter.partial.AbC123/x"
echo old-core >> "$P2/.claude/skills/kit-packs.txt"
echo old-ext >> "$P2/.claude/skills/extensions.txt"
mkdir -p "$P2/.claude/skills/old-skill" "$P2/.claude/skills/my-skill"
printf '# old-up: skill folders bin/skills.sh copied unchanged\n# from x at the commit below. skills.sh and update.sh manage this file.\ncommit %s\nskill old-skill\n' "$(printf '0%.0s' $(seq 40))" > "$P2/.claude/skills/old-up.lock"
printf 'commit 1\nskill my-skill\n' > "$P2/.claude/skills/mine.lock"
PRUNE_OUT="$(cd "$P2" && bash .claude/bin/skills.sh prune 2>&1)"
assert_dir_not_exists "$P2/.claude/skills/ext/old-core" "prune removes a pack kit-packs.txt lists and the registry dropped"
assert_dir_not_exists "$P2/.claude/skills/ext/old-ext" "prune removes an extension extensions.txt lists and the registry dropped"
assert_dir_not_exists "$P2/.claude/skills/ext/jupiter.partial.AbC123" "prune removes the staging folder a killed add left"
assert_dir_exists "$P2/.claude/skills/ext/my-pack" "prune keeps an ext/ folder the kit did not install"
assert_dir_not_exists "$P2/.claude/skills/old-skill" "prune removes an upstream pack the registry dropped, by its lock"
assert_file_not_exists "$P2/.claude/skills/old-up.lock" "...and its lock"
assert_dir_exists "$P2/.claude/skills/my-skill" "prune leaves a .lock the kit did not write alone"
assert_contains "$PRUNE_OUT" "Removed old-core" "prune says which packs it removed"
assert_eq "$(sorted $KIT_CORE sendai jupiter my-pack)" "$(ext_dirs "$P2/.claude/skills/ext")" "prune keeps the core packs and recorded extensions"

# --- A hand-edited extensions.txt is cleaned, not glob-expanded or propagated ---
echo "[extensions.txt]"
# A project-root folder named like a pack: an unquoted '*' would turn it into a recorded
# extension, and the next update would keep that pack (#112, #117).
mkdir -p "$P2/cloudflare"
printf '# mine\n  jupiter  \nJUPITER\nSendAI\r\n*\nno-such-pack\n\n' > "$P2/.claude/skills/extensions.txt"
cp -R "$REPO_ROOT/.claude/skills/ext/." "$P2/.claude/skills/ext/"
HOSTILE_OUT="$(cd "$P2" && bash .claude/bin/skills.sh prune 2>&1)"
assert_eq "jupiter sendai" "$(grep -v '^#' "$P2/.claude/skills/extensions.txt" | tr '\n' ' ' | sed 's/ $//')" "prune trims, lowercases and dedupes extensions.txt, and drops '*' and unknown ids"
assert_contains "$HOSTILE_OUT" "ignoring 'no-such-pack'" "prune warns about an id that is not an extension"
assert_contains "$HOSTILE_OUT" "ignoring '*'" "prune warns about a glob line instead of expanding it"
assert_eq "$(sorted $KIT_CORE sendai jupiter my-pack)" "$(ext_dirs "$P2/.claude/skills/ext")" "A glob in extensions.txt adds no pack, even with a project folder named like one"
cp -R "$REPO_ROOT/.claude/skills/ext/." "$P2/.claude/skills/ext/"
(cd "$P2" && bash .claude/bin/skills.sh prune) >/dev/null 2>&1
assert_eq "$(sorted $KIT_CORE sendai jupiter my-pack)" "$(ext_dirs "$P2/.claude/skills/ext")" "...and the next update keeps the same subset"
printf 'jupiter\n*\n' > "$P2/.claude/skills/extensions.txt"
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$P2" >/dev/null 2>&1
assert_eq "jupiter" "$(grep -v '^#' "$P2/.claude/skills/extensions.txt" | tr '\n' ' ' | sed 's/ $//')" "install.sh re-run (select) drops a glob line too"
ADD_GLOB="$(cd "$P2" && bash .claude/bin/skills.sh add '*' 2>&1 || true)"
assert_contains "$ADD_GLOB" "unknown skill pack '*'" "skills.sh add '*' names the '*', not a file it expanded to"
rmdir "$P2/cloudflare"

# --- A reformatted registry is refused rather than read as zero packs ---
echo "[registry layout]"
P5="$TEMP_DIR/reformatted"
mkdir -p "$P5/.claude/bin" "$P5/.claude/skills/ext"
cp "$SKILLS_SH" "$P5/.claude/bin/"
python3 -c 'import json, sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=4)' "$REGISTRY" "$P5/.claude/skills/skill-registry.json"
for cmd in list prune uninstalled "add jupiter"; do
  TOTAL=$((TOTAL + 1))
  # shellcheck disable=SC2086
  if OUT="$(cd "$P5" && bash .claude/bin/skills.sh $cmd 2>&1)"; then
    echo "  FAIL: skills.sh $cmd accepted a reformatted registry"
    FAIL=$((FAIL + 1))
  elif printf '%s\n' "$OUT" | grep -q "lost the layout"; then
    echo "  PASS: skills.sh $cmd refuses a reformatted registry and says why"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: skills.sh $cmd failed on a reformatted registry without naming the layout: $OUT"
    FAIL=$((FAIL + 1))
  fi
done
P6="$TEMP_DIR/reformatted-kit"
mkdir -p "$P6/kit/skills/ext/jupiter" "$P6/project"
cp "$P5/.claude/skills/skill-registry.json" "$P6/kit/skills/"
TOTAL=$((TOTAL + 1))
if bash "$SKILLS_SH" select "$P6/kit" "$P6/project/.claude" >/dev/null 2>&1; then
  echo "  FAIL: skills.sh select kept every pack of a kit whose registry it could not read"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: skills.sh select refuses a kit registry it cannot read"
  PASS=$((PASS + 1))
fi

# --- --agents installs use .agents/bin/skills.sh and .agents/skills/ext ---
echo "[--agents]"
P3="$TEMP_DIR/agents"
mkdir -p "$P3" && (cd "$P3" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents --with=solana-mobile "$P3" >/dev/null 2>&1
assert_eq "$(sorted $KIT_CORE solana-mobile)" "$(ext_dirs "$P3/.agents/skills/ext")" "--agents install carries core packs plus --with"
(cd "$P3" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/skills.sh add metaplex) >/dev/null 2>&1
assert_dir_exists "$P3/.agents/skills/ext/metaplex" ".agents/bin/skills.sh add installs into .agents/skills/ext"
assert_dir_not_exists "$P3/.claude" "--agents skills.sh writes nothing under .claude/"

print_summary
