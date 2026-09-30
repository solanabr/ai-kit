#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_local_skills] Kit-owned skills (.claude/skills/<name>/SKILL.md): frontmatter, links, hub route..."

# Claude Code, Codex and opencode list every <name>/SKILL.md by its frontmatter, so the
# name must match the directory and the description must exist (Agent Skills caps it
# at 1024 chars). Relative links in the skill's files must resolve; ../ext/ targets need
# the submodules (CI checks them out). The hub must route to each skill.
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

for skill_md in sorted(glob.glob(os.path.join(skills, "*", "SKILL.md"))):
    skill_dir = os.path.dirname(skill_md)
    name = os.path.basename(skill_dir)
    if name == "ext":
        continue
    text = open(skill_md, encoding="utf-8").read()
    front = ""
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        front = text[4:end] if end != -1 else ""
    report(bool(front), f"{name}: SKILL.md starts with a frontmatter block")
    m = re.search(r"^name:\s*(.+)$", front, re.M)
    fm_name = m.group(1).strip().strip("\"'") if m else ""
    report(fm_name == name and re.fullmatch(r"[a-z0-9-]{1,64}", name) is not None,
           f"{name}: frontmatter name matches the directory")
    m = re.search(r"^description:\s*(.+)$", front, re.M)
    desc = m.group(1).strip().strip("\"'") if m else ""
    report(0 < len(desc) <= 1024, f"{name}: description present and <= 1024 chars ({len(desc)})")
    report(f"({name}/SKILL.md)" in hub, f"{name}: routed from .claude/skills/SKILL.md")

    broken = []
    checked = 0
    for dirpath, _dirs, files in os.walk(skill_dir):
        for fname in files:
            if not fname.endswith(".md"):
                continue
            path = os.path.join(dirpath, fname)
            for target in link_re.findall(open(path, encoding="utf-8").read()):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                    continue
                checked += 1
                resolved = os.path.normpath(os.path.join(dirpath, target.split("#", 1)[0]))
                if not os.path.exists(resolved):
                    broken.append(f"{os.path.relpath(path, skills)} -> {target}")
    report(not broken, f"{name}: {checked} relative links resolve" +
           ("" if not broken else " (broken: " + "; ".join(broken[:5]) + ")"))
PY
)

print_summary
