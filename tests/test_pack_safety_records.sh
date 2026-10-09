#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Each pinned pack's `safety` field in skill-registry.json is the kit's only record of
# what that third party actually ships, and the only thing a reader has before an install
# puts the tree on their machine. Prose cannot be trusted to stay true across a pin bump,
# so the mechanically checkable half of it is checked here: a record that says a pack has
# no executables, no hooks.json, no .claude/settings.json, no .mcp.json or no symlinks
# must correspond to a pack that has none. The scan a pin is supposed to get (the
# checklist in docs/skill-packs.md) is a person reading code; this is the regression
# guard under it, so a bump that adds a script to a pack whose record says there are none
# fails CI instead of shipping a false record.
#
# The other half of the rule is the asymmetry that made the record useless in the first
# place: a pack shipping executables must not be described as "clean". Enumerating them
# is a judgement call a test cannot make, but opening the record with that word is not.
#
# "Executable" here means exactly what the scan means: a regular file with the owner
# execute bit, which is the `find -perm -u+x -type f` definition the records are written
# against. A shell script shipped mode 644 is not one — position-manager-skill ships two
# such installers and its record says so in those terms.
#
# A pack's OWN nested submodules are excluded, because no kit installer fetches them and
# so they never reach a project (install.sh and skills.sh never recurse; update.sh clones
# --recurse-submodules and prunes them after the copy). Their paths come from the pack's
# own .gitmodules on disk rather than the registry's `vendored` field, so this stays
# correct even where that field is incomplete.

REGISTRY="$REPO_ROOT/.claude/skills/skill-registry.json"

echo "[test_pack_safety_records] registry safety records vs what each pinned pack ships"
echo ""

assert_file_exists "$REGISTRY" "skill-registry.json is present to check the packs against"

# One line per pinned pack, PASS/FAIL/SKIP + a message. Guarded so a crash in the checker
# is one reported failure rather than a suite that exits under set -e.
echo "[a record's mechanical claims vs the tree]"
REPORT="$(python3 - "$REGISTRY" "$REPO_ROOT" <<'PY' || printf 'FAIL\tthe safety-record checker ran clean (it crashed; see stderr)\n'
import json, os, re, sys

registry, repo_root = sys.argv[1], sys.argv[2]
reg = json.load(open(registry, encoding="utf-8"))

# claim -> (regex that spots the claim, counter name)
CLAIMS = [
    ("executables", re.compile(r"no executables|zero executables|no executable code"
                               r"|no scripts or binaries|markdown only", re.I)),
    ("hooks.json", re.compile(r"no hooks\.json", re.I)),
    (".claude/settings.json", re.compile(r"no \.claude/settings\.json", re.I)),
    (".mcp.json", re.compile(r"no \.mcp\.json", re.I)),
    ("symlinks", re.compile(r"no symlinks|zero symlinks", re.I)),
]
OPENS_CLEAN = re.compile(r"^\s*clean\b", re.I)


def submodule_paths(root):
    """Paths of the pack's OWN submodules, from its .gitmodules. Never fetched by an
    installer, so never part of what a record describes."""
    f = os.path.join(root, ".gitmodules")
    out = []
    if os.path.isfile(f):
        for line in open(f, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line.startswith("path"):
                out.append(os.path.normpath(os.path.join(root, line.split("=", 1)[1].strip())))
    return out


def survey(roots):
    """Count the mechanical categories across a pack's own tree."""
    found = {k: [] for k, _ in CLAIMS}
    vend = []
    for root in roots:
        vend.extend(submodule_paths(root))
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            if any(dirpath == v or dirpath.startswith(v + os.sep) for v in vend):
                dirnames[:] = []
                continue
            for d in list(dirnames):
                full = os.path.join(dirpath, d)
                if os.path.islink(full):
                    found["symlinks"].append(os.path.relpath(full, root))
                    dirnames.remove(d)
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, root)
                if fn == ".git":
                    continue
                if os.path.islink(full):
                    found["symlinks"].append(rel)
                    continue
                try:
                    mode = os.stat(full).st_mode
                except OSError:
                    continue
                if mode & 0o100:
                    found["executables"].append(rel)
                if fn == "hooks.json":
                    found["hooks.json"].append(rel)
                if fn == "settings.json" and os.path.basename(dirpath) == ".claude":
                    found[".claude/settings.json"].append(rel)
                if fn in (".mcp.json", "mcp.json"):
                    found[".mcp.json"].append(rel)
    return found


def report(verdict, root, msg):
    print(verdict + "\t" + root + "\t" + msg)


for entry in reg["entries"]:
    path = entry.get("path")
    if not path:
        continue  # an opt-in add-on: nothing pinned, nothing to survey
    # An upstream pack (a `skills` list) is fetched from its own host at install time and
    # is absent from this repo by construction, not by setup. There is no tree here to
    # check it against and "run git submodule update --init" would be the wrong remedy,
    # so it is out of scope rather than skipped. tests/test_anthropic_skills.sh is where
    # that pack is checked, against the commit it pins.
    if entry.get("skills"):
        continue
    pid = entry["id"]
    root = os.path.join(repo_root, path)

    # Present but empty is setup state (a clone without `--init`): nothing to survey, so
    # the check is recorded as skipped. The bash side re-tests that condition before
    # accepting the skip, so a pack that IS checked out can never slip through as one.
    if not (os.path.isdir(root) and os.listdir(root)):
        report("SKIP", root, "%s: safety record matches its tree" % pid)
        continue
    roots = [root]

    safety = (entry.get("safety") or "").strip()
    found = survey(roots)
    problems = []
    if not safety:
        problems.append("the record is empty")
    for name, rx in CLAIMS:
        hits = found[name]
        if rx.search(safety) and hits:
            problems.append("claims no %s, tree has %d (%s)"
                            % (name, len(hits), ", ".join(sorted(hits)[:3])))
    if OPENS_CLEAN.match(safety) and found["executables"]:
        n = len(found["executables"])
        problems.append("opens \"clean\" while shipping %d executable%s"
                        % (n, "" if n == 1 else "s"))

    if problems:
        report("FAIL", root, "%s: safety record matches its tree — %s" % (pid, "; ".join(problems)))
    else:
        report("PASS", root, "%s: safety record matches its tree" % pid)
PY
)"

# A SKIP is only honoured when the pack really is present-and-empty — the same condition
# helpers.sh gates on, re-tested here rather than taken on the checker's word. A pack
# that IS checked out and still came back unsurveyable is a failure, which is the case
# worth catching: it is how an upstream rename or a permissions problem would otherwise
# disappear into a green run.
while IFS=$'\t' read -r verdict root message; do
  [ -n "$verdict" ] || continue
  case "$verdict" in
    PASS)
      TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  PASS: $message" ;;
    SKIP)
      if ext_pack_empty "$root" || [ ! -d "$root" ]; then
        skip "$message (its ext/ pack is not checked out)"
      else
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        echo "  FAIL: $message (unsurveyable, but $root is not an empty pack directory)"
      fi
      ;;
    *)
      TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  FAIL: $message" ;;
  esac
done <<< "$REPORT"

# The checker must have had something to say about every submodule pack, passed or
# skipped. Without this a change that drops the loop, or a `path` spelling it stops
# matching, would report nothing and still exit green — the vacuous-test shape #215 was
# written for.
echo "[the checker covered every submodule pack]"
PINNED="$(python3 -c "
import json, sys
reg = json.load(open(sys.argv[1], encoding='utf-8'))
print(sum(1 for e in reg['entries'] if e.get('path') and not e.get('skills')))
" "$REGISTRY")"
REPORTED="$(printf '%s\n' "$REPORT" | grep -cE '^(PASS|FAIL|SKIP)'"$(printf '\t')" || true)"
assert_eq "$PINNED" "$REPORTED" "every submodule pack got a verdict ($PINNED pinned)"

print_summary
