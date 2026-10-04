#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# A task should surface the pack it needs without the user knowing the catalogue. The map
# lives in .claude/skills/skill-packs/SKILL.md (work to pack, read on demand) and is reached
# three ways: the skill listing every session, the hub, and the agent whose domain owns the
# work. No trigger string is matched against prompt text anywhere -- the model does that
# matching -- so what a test can hold is that the map exists, stays truthful against the
# registry, and is reachable from each entry point.
#
# The three cases are the maintainer's: program work surfaces qedgen, a landing page
# surfaces the design packs, animation surfaces the animation packs.
#
# Every python block below is a command substitution, not `done < <(python3 ... <<'PY')`:
# on bash 3.2 a heredoc nested in a process substitution loses its body to brace expansion
# the moment the python contains a `{...}` comprehension (verified: the line arrives at
# python split on its commas, and the next heredoc in the file receives the pieces).

PACKS="$REPO_ROOT/.claude/skills/skill-packs/SKILL.md"
REGISTRY="$REPO_ROOT/.claude/skills/skill-registry.json"
HUB="$REPO_ROOT/.claude/skills/SKILL.md"
AGENTS="$REPO_ROOT/.claude/agents"

echo "[test_pack_routing] Work-to-pack routing: the map, its truthfulness, its entry points"
echo ""

echo "[the map exists]"
assert_file_exists "$PACKS" "the work-to-pack map exists at .claude/skills/skill-packs/SKILL.md"
assert_file_exists "$REGISTRY" "skill-registry.json is present to check the map against"

# --- The map agrees with the registry, and covers the three cases ---
# The table is hand-maintained because the registry has no field for "offer this pack for
# this kind of work" (its `triggers` are named-request phrases, and nothing matches on them).
# This block is what keeps a hand-maintained table from drifting: every id must exist, sit in
# the column its tier dictates, and carry the env keys its entry lists.
echo "[the map vs the registry]"
# Guarded so a crash in the checker is one reported failure rather than a suite that exits
# under set -e with the remaining entry-point checks unrun.
REPORT="$(python3 - "$PACKS" "$REGISTRY" <<'PY' || printf 'FAIL\tthe map-vs-registry checker ran clean (it crashed; see stderr)\n'
import json, re, sys

text = open(sys.argv[1], encoding="utf-8").read()
reg = json.load(open(sys.argv[2], encoding="utf-8"))
entries = dict((e["id"], e) for e in reg["entries"])

def report(ok, msg):
    print(("PASS" if ok else "FAIL") + "\t" + msg)

def ids(cell):
    return re.findall(r"`([a-z0-9][a-z0-9._-]*)`", cell)

# Only the work-to-pack table: the table above it backticks commands, not pack ids.
section = re.search(r"^## Work to packs\s*$(.*?)^## ", text, re.M | re.S)
report(bool(section), "the map has a 'Work to packs' section")
if not section:
    raise SystemExit

rows = []
for line in section.group(1).splitlines():
    line = line.strip()
    if not line.startswith("|"):
        continue
    cells = [c.strip() for c in line.strip("|").split("|")]
    if len(cells) != 3 or cells[0] == "Work" or set(cells[0]) <= set("- "):
        continue
    rows.append((cells[0], ids(cells[1]), ids(cells[2])))

report(len(rows) >= 10, "the table has a row per work domain (%d rows)" % len(rows))

unknown, miscolumned = [], []
for work, pinned, addons in rows:
    for pid in pinned:
        if pid not in entries:
            unknown.append("%s (pinned column, row '%s')" % (pid, work[:28]))
        elif entries[pid].get("tier") != "extension":
            miscolumned.append("%s is tier %s, not a pinned extension"
                               % (pid, entries[pid].get("tier") or "none"))
    for aid in addons:
        if aid not in entries:
            unknown.append("%s (add-on column, row '%s')" % (aid, work[:28]))
        elif entries[aid].get("tier"):
            miscolumned.append("%s is tier %s, so it belongs in the pinned column"
                               % (aid, entries[aid]["tier"]))
report(not unknown, "every pack the map names exists in the registry"
       + ("" if not unknown else ": unknown " + ", ".join(sorted(set(unknown)))))
report(not miscolumned, "every pack sits in the column its registry tier dictates"
       + ("" if not miscolumned else ": " + ", ".join(sorted(set(miscolumned)))))

named = set()
for _work, pinned, addons in rows:
    named.update(pinned)
    named.update(addons)

# A pack whose entry lists env keys is inert, or partly inert, without them. The map has to
# name the key, or it offers something that cannot run.
missing_env = []
for pid in sorted(named & set(entries)):
    for raw in (entries[pid].get("install") or {}).get("env") or []:
        key = re.match(r"[A-Z][A-Z0-9_]+", raw)
        if key and key.group(0) not in text:
            missing_env.append("%s needs %s" % (pid, key.group(0)))
report(not missing_env, "every env key the registry lists for a named pack appears in the map"
       + ("" if not missing_env else ": " + ", ".join(missing_env)))

# The three maintainer cases: the row for that work names the pack.
cases = [
    ("program work surfaces qedgen", r"\bprogram work\b", ["qedgen"], []),
    ("a landing page surfaces the design packs", r"landing page",
     ["vercel", "solana-new"], ["anydesign"]),
    ("animation surfaces the animation packs", r"\banimation\b",
     ["solana-new"], ["emilkowalski-skill"]),
]
for label, pattern, want_pinned, want_addons in cases:
    match = None
    for row in rows:
        if re.search(pattern, row[0], re.I):
            match = row
            break
    if match is None:
        report(False, "%s: no row matches /%s/" % (label, pattern))
        continue
    work, pinned, addons = match
    gap = sorted(set(want_pinned) - set(pinned)) + sorted(set(want_addons) - set(addons))
    report(not gap, "%s (row '%s')" % (label, work[:40])
           + ("" if not gap else ": missing " + ", ".join(gap)))

# Add-on install commands vary by method (submodule, clone, npx, claude mcp add), so the map
# sends the reader to the entry instead of carrying a copy that goes stale unnoticed.
report("install.command" in text, "the map sends the reader to the registry entry for an add-on's command")
report("git submodule add" not in text, "the map hardcodes no add-on install command")
report("bash .claude/bin/skills.sh add" in text, "the map gives the pinned-extension install command")

# It suggests; the user installs.
report("on a yes" in text, "the map installs only on the user's yes")
report("safe-ai-skill add skill" in text, "an add-on goes through the safe-ai-skill gate first")
report("env-keys.sh" in text and "never a value" in text,
       "key presence is checked with the names-and-presence helper, not by reading .env")

# This description loads in every session and every subagent, so it carries a tighter budget
# than the 1024-char Agent Skills cap, and has to name the three domains to fire on them.
front = text[4:text.find("\n---", 4)] if text.startswith("---\n") else ""
m = re.search(r"^description:\s*(.+)$", front, re.M)
desc = m.group(1).strip() if m else ""
report(0 < len(desc) <= 600,
       "always-loaded description within the kit's 600-char budget (%d)" % len(desc))
for word in ("program", "design", "animation"):
    report(word in desc.lower(), "the description names '%s', so that work reaches the map" % word)
PY
)"
while IFS=$'\t' read -r status message; do
  [ -n "$status" ] || continue
  TOTAL=$((TOTAL + 1))
  if [ "$status" = "PASS" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message"
    FAIL=$((FAIL + 1))
  fi
done <<< "$REPORT"

# --- Entry points: the skill listing, the hub, the domain agents ---
# The skill listing itself is covered by tests/test_local_skills.sh, which requires the
# frontmatter name, the description cap and a hub route for every .claude/skills/<name>/.
echo "[entry points]"
assert_file_contains "$HUB" "(skill-packs/SKILL.md)" "the hub routes to the map"
assert_file_contains "$REPO_ROOT/.claude/commands/add-skill.md" "skill-packs/SKILL.md" "/add-skill routes to the map"

# Cases 1 to 3 again at the agent layer: the agent that owns the work names the pack, so a
# spawned agent surfaces it even when nothing reads the map. Harnesses with no skill listing
# have only this path.
for agent in anchor-engineer pinocchio-engineer; do
  assert_file_contains "$AGENTS/$agent.md" "skills.sh add qedgen" "$agent offers qedgen for program work"
  assert_file_contains "$AGENTS/$agent.md" "MISTRAL_API_KEY" "$agent names the key qedgen needs"
  assert_file_contains "$AGENTS/$agent.md" "skill-packs/SKILL.md" "$agent routes on to the map"
done
FE="$AGENTS/solana-frontend-engineer.md"
assert_file_contains "$FE" "anthropic-skills" "solana-frontend-engineer offers a design pack for a landing page"
assert_file_contains "$FE" "emilkowalski-skill" "solana-frontend-engineer names the animation add-on"
assert_file_contains "$FE" "skill-packs/SKILL.md" "solana-frontend-engineer routes on to the map"

# --- Repo-wide: no kit file offers a pack the registry does not pin ---
# The reverse of test_skill_extensions' hub check. An id that drifts out of the registry, or
# a typo, would otherwise ship as an install command that fails in a user's session.
echo "[offered ids are real]"
BAD_IDS="$(python3 - "$REPO_ROOT" <<'PY'
import glob, json, os, re, sys
root = sys.argv[1]
reg = json.load(open(os.path.join(root, ".claude/skills/skill-registry.json"), encoding="utf-8"))
ext = set(e["id"] for e in reg["entries"] if e.get("tier") == "extension")
files = [os.path.join(root, "CLAUDE-solana.md")]
for pattern in ("agents/*.md", "commands/*.md", "skills/*.md", "skills/*/SKILL.md"):
    files += glob.glob(os.path.join(root, ".claude", pattern))
bad = []
for path in files:
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        for group in re.findall(r"skills\.sh add (?:--force )?((?:[a-z0-9-]+ ?)+)", line):
            for pid in group.split():
                if pid not in ext and pid != "id":
                    bad.append("%s:%d offers '%s'" % (os.path.relpath(path, root), n, pid))
print("\n".join(sorted(set(bad))) or "OK")
PY
)"
assert_eq "OK" "$BAD_IDS" "every skills.sh add command in the kit's markdown names a pinned extension"

print_summary
