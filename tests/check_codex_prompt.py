#!/usr/bin/env python3
"""Assert what Codex actually puts in its prompt for a bridge install.

Usage: codex debug prompt-input "hello" > out.json && python3 check_codex_prompt.py out.json

Codex injects only a skill's name and description, never its body, and splits one
metadata budget across every registered skill. Registering the vendored ext/ packs
drives each share to zero, so every description arrives empty with no warning --
that silent truncation is what this guards.
"""
import re
import sys

raw = open(sys.argv[1], encoding="utf-8").read()
problems = []

if "solana-builder" not in raw:
    problems.append("AGENTS.md was not loaded")
if "Solana development reference hub" not in raw:
    problems.append("router skill missing, or its description was truncated")
if "routing hub is" in raw:
    problems.append("router BODY leaked into the prompt (only name+description should)")

entries = re.findall(r"- ([\w:.\-]+): (.*?)\(file:", raw)
# Codex does not drop excess skills; it shrinks every description toward zero.
# The observed regime before emptiness is mid-word stumps of ~31-37 chars, so
# asserting "not empty" alone would pass a prompt where nothing is readable.
MIN = 60
short = [(n, len(d.strip())) for n, d in entries if len(d.strip()) < MIN]
if short:
    problems.append(
        f"{len(short)}/{len(entries)} skill descriptions are under {MIN} chars "
        f"(truncated by Codex's metadata budget): {short[:5]}"
    )

if problems:
    for p in problems:
        print(f"::error::{p}")
    print(raw[:3000])
    sys.exit(1)

print(f"OK: AGENTS.md loaded, router listed, {len(entries)} skills, none truncated")
