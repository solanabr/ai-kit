#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_local_skills] Kit-owned skills (.claude/skills/<name>/SKILL.md): frontmatter, links, hub route..."

# Claude Code, Codex and opencode list every <name>/SKILL.md by its frontmatter, so the
# name must match the directory and the description must exist (Agent Skills caps it
# at 1024 chars) and the body stays within its 500-line guidance. Relative links in the
# skill's files must resolve; ../ext/ targets need the submodules (CI checks them out).
# The hub must route to each skill. The .md files sitting directly in .claude/skills/
# (the hub, backend-async, deployment) fall outside the */SKILL.md glob, so their links
# are walked separately at the end.
while IFS=$'\t' read -r status message; do
  TOTAL=$((TOTAL + 1))
  if [ "$status" = "PASS" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message"
    FAIL=$((FAIL + 1))
  fi
done < <(python3 - "$REPO_ROOT" <<'PY'
import glob, os, re, sys

root = sys.argv[1]
skills = os.path.join(root, ".claude", "skills")
hub = open(os.path.join(skills, "SKILL.md"), encoding="utf-8").read()
link_re = re.compile(r"\]\(([^)\s]+)\)")

def report(ok, msg):
    print(("PASS" if ok else "FAIL") + "\t" + msg)

def broken_links(path, base):
    broken, checked = [], 0
    for target in link_re.findall(open(path, encoding="utf-8").read()):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue
        checked += 1
        if not os.path.exists(os.path.normpath(os.path.join(base, target.split("#", 1)[0]))):
            broken.append(f"{os.path.relpath(path, skills)} -> {target}")
    return broken, checked

for skill_md in sorted(glob.glob(os.path.join(skills, "*", "SKILL.md"))):
    skill_dir = os.path.dirname(skill_md)
    name = os.path.basename(skill_dir)
    if name == "ext":
        continue
    text = open(skill_md, encoding="utf-8").read()
    front = ""
    body = text
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            front = text[4:end]
            body = text[end + len("\n---"):]
    report(bool(front), f"{name}: SKILL.md starts with a frontmatter block")
    m = re.search(r"^name:\s*(.+)$", front, re.M)
    fm_name = m.group(1).strip().strip("\"'") if m else ""
    report(fm_name == name and re.fullmatch(r"[a-z0-9-]{1,64}", name) is not None,
           f"{name}: frontmatter name matches the directory")
    m = re.search(r"^description:\s*(.+)$", front, re.M)
    desc = m.group(1).strip().strip("\"'") if m else ""
    report(0 < len(desc) <= 1024, f"{name}: description present and <= 1024 chars ({len(desc)})")
    report(f"({name}/SKILL.md)" in hub, f"{name}: routed from .claude/skills/SKILL.md")
    lines = len(body.splitlines())
    report(lines <= 500, f"{name}: SKILL.md body within the 500-line guidance ({lines})")

    broken = []
    checked = 0
    for dirpath, _dirs, files in os.walk(skill_dir):
        for fname in sorted(files):
            if not fname.endswith(".md"):
                continue
            file_broken, file_checked = broken_links(os.path.join(dirpath, fname), dirpath)
            broken += file_broken
            checked += file_checked
    report(not broken, f"{name}: {checked} relative links resolve" +
           ("" if not broken else " (broken: " + "; ".join(broken[:5]) + ")"))

# The hub and the shared references (backend-async.md, deployment.md) live directly in
# .claude/skills/, so the glob above never reaches them.
broken = []
checked = 0
for path in sorted(glob.glob(os.path.join(skills, "*.md"))):
    file_broken, file_checked = broken_links(path, skills)
    broken += file_broken
    checked += file_checked
report(not broken, f".claude/skills/*.md: {checked} relative links resolve" +
       ("" if not broken else " (broken: " + "; ".join(broken[:5]) + ")"))
PY
)

print_summary
