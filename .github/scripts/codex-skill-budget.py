#!/usr/bin/env python3
"""Fail when Codex shortened the description of a skill it registered from a project.

Usage: codex-skill-budget.py <codex-debug-prompt-input.json> <project>/.agents/skills [min-entries]

Codex lists each skill as `- <name>: <description> (file: rN/<path>)` and splits one
shared description budget across every entry, cutting each to its share with no marker
once roughly 50 are registered; well past that it drops descriptions entirely (#212).
So a non-empty description proves nothing. This compares each entry under the project's
skills root with the `description` in the SKILL.md it points at: the emitted text must
be at least as long as the source, capped at PER_SKILL_CAP, below Codex's own per-skill
clip (~1024 chars), which is a fixed limit and not the budget.

Exit 0: every entry whole. Exit 1: at least one shortened. Exit 2: nothing to check
(no skills block, or fewer than min-entries project entries), so a Codex output-format
change fails loudly instead of passing on zero rows.
"""
import json
import os
import re
import sys

PER_SKILL_CAP = 1000


def strings(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for v in x.values():
            yield from strings(v)
    elif isinstance(x, list):
        for v in x:
            yield from strings(v)


def norm(s):
    return " ".join(s.split())


def source_description(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    if not text.startswith("---"):
        return ""
    front = text[3:].split("\n---", 1)[0]
    try:
        import yaml
        fm = yaml.safe_load(front) or {}
        return norm(str(fm.get("description") or ""))
    except Exception:
        # No PyYAML: a plain or quoted scalar, or a block scalar's indented lines.
        m = re.search(r"^description:[ \t]*(.*)\n((?:[ \t]+.*\n?)*)", front + "\n", re.M)
        if not m:
            return ""
        head = m.group(1).strip()
        if head[:1] in (">", "|"):
            return norm(m.group(2))
        return norm((head + " " + m.group(2)).strip().strip("\"'"))


def main():
    prompt, skills_dir = sys.argv[1], os.path.realpath(sys.argv[2])
    min_entries = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    block = next((s for s in strings(json.load(open(prompt))) if "### Available skills" in s), "")
    roots = {k: os.path.realpath(v) for k, v in re.findall(r"^- `(r\d+)` = `([^`]+)`", block, re.M)}
    checked, short = 0, []
    for line in block.splitlines():
        m = re.match(r"^- (.+?) \(file: (r\d+)/(.+)\)$", line)
        if not m or roots.get(m.group(2)) != skills_dir:
            continue
        name, _, desc = m.group(1).partition(": ")
        want = min(len(source_description(skills_dir + "/" + m.group(3))), PER_SKILL_CAP)
        got = len(norm(desc))
        checked += 1
        if got < want:
            short.append(f"{name}: {got} of {want} chars ({m.group(3)})")
    print(f"{checked} project skills registered by Codex, {len(short)} with a shortened description")
    for s in short:
        print("  " + s)
    if checked < min_entries:
        print(f"expected at least {min_entries} project skills in the Codex prompt")
        return 2
    return 1 if short else 0


if __name__ == "__main__":
    sys.exit(main())
