#!/usr/bin/env bash
set -euo pipefail

# Every registry entry promises a working install command. A `kit` entry is covered by
# its pin (skills.sh pins --write, checked by validate.sh), but the other methods had
# nothing verifying them: v2.2.0 shipped a pyth-pro-mcp entry whose command installed
# @pythnetwork/pyth-mcp, a package that has never existed on npm, with a `source` URL
# pointing at its nonexistent npm page. A pin protects an entry that exists; it cannot
# notice one that was invented. This suite is the existence check.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

REGISTRY="$REPO_ROOT/.claude/skills/skill-registry.json"

echo "[test_registry_installability] every install command names something that exists"
echo ""

# --- Declared: every entry has an install object at all ---------------------------
# The three checks below walk entries whose `install` is a dict, so an entry with
# `"install": null` was skipped by all of them. That is how `gmem` sat in the registry
# with a null install, no tier and an unverified licence while passing every check:
# the suite caught a *fabricated* install command but not a *missing* one.
DECLARED="$(python3 - "$REGISTRY" <<'PY'
import json, sys

problems = []
def walk(node):
    if isinstance(node, dict):
        if node.get("id"):
            install = node.get("install")
            # `type: aggregator` is a scouting pointer -- an index to read, not a pack to
            # install -- so a null install is correct there and all six say so. Every
            # other type promises something installable.
            if node.get("type") == "aggregator":
                if isinstance(install, dict):
                    problems.append(f"{node['id']}: type aggregator but it declares an install")
            elif not isinstance(install, dict):
                problems.append(
                    f"{node['id']}: type {node.get('type')!r} with install"
                    f" {type(install).__name__} -- an entry the registry cannot serve"
                    " belongs in prose or as an aggregator, not as a pack")
            else:
                for key in ("method", "command"):
                    if not install.get(key):
                        problems.append(f"{node['id']}: install.{key} is missing or empty")
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(open(sys.argv[1])))

print("\n".join(problems) or "OK")
PY
)"
assert_eq "OK" "$DECLARED" "Every registry entry declares an install object with a method and a command"

# --- Shape: the command has to match the method it claims -------------------------
SHAPE="$(python3 - "$REGISTRY" <<'PY'
import json, re, sys

entries = []
def walk(node):
    if isinstance(node, dict):
        if node.get("id") and isinstance(node.get("install"), dict):
            entries.append(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(open(sys.argv[1])))

# method -> a regex the command must match, so a mislabelled method is a failure rather
# than a silently wrong routing hint.
SHAPES = {
    "kit":                 r"^bash \.claude/bin/skills\.sh add \S+$",
    "submodule":           r"^git submodule add https://\S+ \.claude/skills/ext/\S+$",
    "git-clone":           r"^git clone ",
    "plugin-marketplace":  r"^/plugin marketplace add \S+$",
    # Claude Code registers the official Anthropic marketplace itself, so an entry there
    # installs directly and a "marketplace add" step would be noise. (No apostrophes in
    # this heredoc: bash 3.2 mis-parses one inside a $(...) command substitution.)
    "plugin-install":      r"^/plugin install \S+@\S+$",
    "npx":                 r"(?:^|\s)(?:npx|dlx|bunx)\s",
    "remote-http-mcp":     r"--transport http\b.*\bhttps://",
}

problems = []
for entry in entries:
    install = entry["install"]
    method, command = install.get("method"), install.get("command", "")
    if method not in SHAPES:
        problems.append(f"{entry['id']}: unknown install.method {method!r}")
        continue
    if not re.search(SHAPES[method], command):
        problems.append(f"{entry['id']}: method {method!r} but command is {command[:70]!r}")
    # A kit entry is only as good as its pin.
    if method == "kit" and not entry.get("commit"):
        problems.append(f"{entry['id']}: method 'kit' with no commit pin")

print("\n".join(problems) or "OK")
PY
)"
assert_eq "OK" "$SHAPE" "Every install.command matches the install.method it declares (and every kit entry is pinned)"

# --- Consistency: an npm source URL must name the package the command installs ------
CONSISTENT="$(python3 - "$REGISTRY" <<'PY'
import json, re, sys

entries = []
def walk(node):
    if isinstance(node, dict):
        if node.get("id") and isinstance(node.get("install"), dict):
            entries.append(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(open(sys.argv[1])))

problems = []
for entry in entries:
    install = entry["install"]
    if install.get("method") != "npx":
        continue
    match = re.search(r"(?:npx|dlx|bunx)\s+(?:-y\s+)?(@?[\w.-]+(?:/[\w.-]+)?)", install.get("command", ""))
    if not match:
        problems.append(f"{entry['id']}: cannot read a package name out of the command")
        continue
    package = match.group(1)
    source = entry.get("source", "")
    if "npmjs.com/package/" in source:
        named = source.split("npmjs.com/package/", 1)[1].rstrip("/")
        if named != package:
            problems.append(f"{entry['id']}: source names {named!r}, command installs {package!r}")

print("\n".join(problems) or "OK")
PY
)"
assert_eq "OK" "$CONSISTENT" "An npmjs.com source URL names the same package the command installs"

# --- Existence: the npm packages actually resolve ----------------------------------
# Offline this is skipped; in CI it is a hard failure. The structural checks above run
# either way, but only this one catches a package that was never published.
PACKAGES="$(python3 - "$REGISTRY" <<'PY'
import json, re, sys

entries = []
def walk(node):
    if isinstance(node, dict):
        if node.get("id") and isinstance(node.get("install"), dict):
            entries.append(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(open(sys.argv[1])))

for entry in entries:
    install = entry["install"]
    if install.get("method") != "npx":
        continue
    match = re.search(r"(?:npx|dlx|bunx)\s+(?:-y\s+)?(@?[\w.-]+(?:/[\w.-]+)?)", install.get("command", ""))
    if match:
        print(f"{entry['id']}\t{match.group(1)}")
PY
)"

if [ -n "${CI:-}" ] || curl -fsS --max-time 10 https://registry.npmjs.org/ -o /dev/null 2>/dev/null; then
  MISSING=""
  while IFS=$'\t' read -r entry_id package; do
    [ -n "$package" ] || continue
    # Scoped names are one path segment on the registry: @scope/name -> @scope%2Fname
    encoded="${package/\//%2F}"
    if ! curl -fsS --max-time 20 "https://registry.npmjs.org/$encoded" -o /dev/null 2>/dev/null; then
      MISSING="$MISSING$entry_id ($package) "
    fi
  done <<< "$PACKAGES"
  assert_eq "" "$MISSING" "Every npx-method package resolves on the npm registry"
else
  echo "  SKIP: registry.npmjs.org is unreachable here; CI runs the existence check"
fi

print_summary
