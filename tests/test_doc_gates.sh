#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Every gate the documentation promises has to resolve to a mechanism that enforces it.
#
# The defect this closes: docs/firewall.md advertised approval prompts for a family of
# destructive commands where permissions.ask was empty at every tier and no hook covered
# them — seven wrong claims across three files, the worst of them an agent overwriting
# the user's default wallet keypair with no prompt at the default tier. No test could
# catch it, because no test read the documentation at all: `grep -rln docs/firewall.md
# tests/` returned nothing.
#
# The obvious repair is to pin the rule strings in a test beside the docs, and that is
# the failure mode this replaces rather than a fix for it — a second hand-maintained list
# drifts from the first exactly as silently. So this suite PARSES the sentence a reader
# actually reads, out of the table's own mechanism column, and resolves it:
#
#   1. Every row of docs/firewall.md's gate table must name at least one mechanism in its
#      "Where" cell, from a closed vocabulary — a *-guard.sh script, an unnamed
#      "PreToolUse hook", deny/allow/ask rules, `sandbox`, a `.claude/*.json` config
#      file, a /command, or another tool's own hooks. A row that names none FAILS, and
#      that is what makes this check non-drifting: the only way to add a promise to the
#      docs is to name the thing that keeps it.
#   2. Every backticked literal in the row's "Gate" cell must be covered by one of those
#      mechanisms — a rule mechanism by glob-matching or appearing inside a generated
#      permissions.<kind> entry at exactly the tiers the Where cell claims (all four when
#      it names none), a guard mechanism by appearing in that guard's comment-stripped
#      source — and every mechanism a row names must be exercised by at least one of its
#      literals, so a mechanism cannot be named for cover.
#   3. A row promising an "approval prompt" must name a hook, because permissions.ask is
#      empty at every tier by design (an ask is a hard failure under `claude -p`, so the
#      prompts live in the hooks). README.md's Firewall-tiers table is held to the weaker
#      half of the same contract: every backticked literal in its on-chain/destructive
#      column must resolve to a deny rule at that row's own tier, or to some guard.
#
# Backticks in the gate table therefore mean "literal command text some mechanism must
# cover". Metasyntax — a metavariable, the name of a command form — stays outside them,
# which is why the table reads `npx` and "a versioned package" rather than `pkg@version`.
#
# Nothing here needs an ext/ pack, so there is nothing to skip: it reads the two tables,
# the generator's output and the guard sources, all of them tracked files.
echo "[test_doc_gates] Every documented gate resolves to a mechanism that enforces it"
echo ""

DOC="$REPO_ROOT/docs/firewall.md"
README="$REPO_ROOT/README.md"
FIREWALL="$REPO_ROOT/.claude/bin/firewall.sh"
SECURITY="$REPO_ROOT/.claude/security.json"

assert_file_exists "$DOC" "docs/firewall.md exists"
assert_file_exists "$README" "README.md exists"
assert_file_exists "$FIREWALL" ".claude/bin/firewall.sh exists"
if [ ! -f "$DOC" ] || [ ! -f "$README" ] || [ ! -f "$FIREWALL" ]; then
  echo "  (the resolver needs both documents and the generator; nothing to resolve yet)"
  print_summary
fi

WORK="$(new_tmp)" || exit 1
# An unguarded empty temp path truncated a tracked file once; never write without this.
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
  echo "  FAIL: could not create a temp dir (mktemp -d returned '${WORK:-}')"
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

# ── generate the four tiers in an isolated project ──────────────────────────
# Same fixture shape as tests/test_firewall.sh, never the repo's own settings.json. The
# `git init` matters: firewall.sh emits an absolute path for a git common dir sitting
# outside the project, and a fixture that is its own repository keeps that out of here.
mkdir -p "$WORK/proj/.claude/bin"
cp "$REPO_ROOT/.claude/settings.json" "$WORK/proj/.claude/settings.json"
cp "$SECURITY" "$WORK/proj/.claude/security.json"
cp "$FIREWALL" "$WORK/proj/.claude/bin/firewall.sh"
chmod +x "$WORK/proj/.claude/bin/firewall.sh"
(cd "$WORK/proj" && git init -q)

echo "[tier generation]"
GENERATED=0
for t in off relaxed medium high; do
  if (cd "$WORK/proj" && CLAUDE_PROJECT_DIR="$WORK/proj" \
      bash .claude/bin/firewall.sh apply "$t") > "$QUIET_LOG" 2>&1; then
    cp "$WORK/proj/.claude/settings.json" "$WORK/gen.$t.json"
    GENERATED=$((GENERATED + 1))
  else
    echo "  FAIL: firewall.sh could not generate tier '$t'"
    tail -5 "$QUIET_LOG" 2>/dev/null | sed 's/^/      /' || true
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
  fi
done
assert_eq "4" "$GENERATED" "all four tiers generated into the fixture"
if [ "$GENERATED" -ne 4 ]; then
  echo "  (a tier that did not generate has no rules to resolve against)"
  print_summary
fi

# ── resolve ─────────────────────────────────────────────────────────────────
# The resolver writes one "PASS|<message>" or "FAIL|<message>" line per check, plus
# "ROWS|<table>|<n>" lines so a table that silently stopped parsing cannot read as a
# clean run. The counters stay this suite's own.
VERDICTS="$WORK/verdicts.txt"
set +e
python3 - "$DOC" "$README" "$REPO_ROOT" "$WORK" > "$VERDICTS" 2>"$WORK/resolver.err" <<'PY'
import fnmatch
import json
import os
import re
import sys

DOC, README, ROOT, WORK = sys.argv[1:5]
TIERS = ("off", "relaxed", "medium", "high")
HOOKS_DIR = os.path.join(ROOT, ".claude/hooks")
GUARD_RE = re.compile(r"\b([a-z0-9]+(?:-[a-z0-9]+)*-guard\.sh)\b")
RULE_RE = re.compile(r"^([A-Za-z]+)\((.*)\)$")


def ok(msg):
    print("PASS|" + msg)


def bad(msg):
    print("FAIL|" + msg)


def table(path, header_cell):
    """(headers, rows) of the markdown table whose first header cell is header_cell."""
    headers, rows, inside = [], [], False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s.startswith("|"):
                inside = False
                continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if not inside:
                if cells and cells[0] == header_cell:
                    headers, inside = cells, True
                continue
            if set("".join(cells)) <= set("-: "):
                continue            # the ---|--- separator, or an empty row
            rows.append(cells)
    return headers, rows


_settings = {}


def gen(tier):
    if tier not in _settings:
        with open(os.path.join(WORK, "gen.%s.json" % tier), encoding="utf-8") as fh:
            _settings[tier] = json.load(fh)
    return _settings[tier]


def rules(tier, kind):
    return (gen(tier).get("permissions") or {}).get(kind) or []


def rule_covers(lit, rule_list):
    """Does some rule in rule_list decide on this literal?

    Two ways, because the table's literals are a mix of whole commands and fragments.
    A fragment is covered when a rule string contains it (`/*` inside Bash(rm -rf /*)).
    A whole command is covered when a rule's glob matches it, either exactly or with one
    more word after it — which is how `git reset --hard` resolves to its only live rule,
    Bash(git reset --ha*), long-option abbreviation and all.
    """
    for rule in rule_list:
        if lit in rule:
            return True
        m = RULE_RE.match(rule)
        if not m:
            continue
        pat = m.group(2)
        if fnmatch.fnmatchcase(lit, pat) or fnmatch.fnmatchcase(lit + " x", pat):
            return True
    return False


def strip_comments(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


_corpus = {}


def guard_corpus(script):
    """A guard's own decision logic: its script plus the siblings sharing its stem.

    Comment lines are stripped, so a gate that exists only as prose in a header does not
    satisfy the claim that the guard covers it. The shared libs (lib-tokenize.awk,
    lib-headless.sh) are deliberately out: they are plumbing every guard loads, not this
    guard's corpus, and folding them in would let any guard claim any other's coverage.
    """
    if script not in _corpus:
        stem = script[:-3] if script.endswith(".sh") else script
        parts = []
        for name in sorted(os.listdir(HOOKS_DIR)):
            if name == script or name.startswith(stem + "."):
                with open(os.path.join(HOOKS_DIR, name), encoding="utf-8") as fh:
                    parts.append(strip_comments(fh.read()))
        _corpus[script] = "\n".join(parts)
    return _corpus[script]


def registered(path):
    """The guard scripts a settings/hooks file actually wires into PreToolUse."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    found = []
    for entry in (data.get("hooks") or {}).get("PreToolUse") or []:
        for hook in entry.get("hooks") or []:
            found += GUARD_RE.findall(hook.get("command") or "")
    return sorted(set(found))


def guard_covers(lit, corpus):
    """The literal verbatim, or every one of its tokens.

    Token by token because the guards hold their corpora as regex alternations:
    `spl-token transfer` is in onchain-guard.sh as spl-token (transfer|burn|close|
    authorize), so the whole literal is semantically present and textually absent.
    A metavariable contributes no token, which is why the table keeps metasyntax
    outside its backticks.
    """
    if lit in corpus:
        return True
    toks = [t for t in re.sub(r"<[^>]*>", " ", lit).split() if t]
    return bool(toks) and all(t in corpus for t in toks)


def mechanisms(where):
    """The closed vocabulary. An empty result is a failing row, never a skipped one."""
    found = ["hook:" + g for g in GUARD_RE.findall(where)]
    if re.search(r"PreToolUse hooks?", where):
        found.append("hook:any")
    for kind in ("deny", "allow", "ask"):
        if re.search(r"\b%s rules?\b" % kind, where):
            found.append("rules:" + kind)
    if "`sandbox`" in where:
        found.append("sandbox")
    found += ["config:" + c for c in re.findall(r"`(\.claude/[A-Za-z0-9_.-]+\.json)`", where)]
    found += ["command:" + c for c in re.findall(r"`/([a-z][a-z0-9-]*)`", where)]
    if re.search(r"[Ii]ts own\b.*\bhooks\b", where):
        found.append("plugin")
    return found


def claimed_tiers(where):
    """The tiers the mechanism column claims, defaulting to every tier."""
    named = tuple(t for t in TIERS if re.search(r"\b%s\b" % t.capitalize(), where))
    return named or TIERS


def label(cell):
    return re.sub(r"\s+", " ", cell.replace("`", "").replace("*", ""))[:52]


# ── docs/firewall.md: the gate table ───────────────────────────────────────
_, gate_rows = table(DOC, "Gate")
print("ROWS|gate|%d" % len(gate_rows))

all_guards = registered(os.path.join(ROOT, ".claude/settings.json"))
any_corpus = "\n".join(guard_corpus(g) for g in all_guards)

named_guards, named_configs, named_commands = set(), set(), set()
plugin_rows, prompt_rows = [], 0

for n, cells in enumerate(gate_rows, 1):
    gate, where = cells[0], (cells[1] if len(cells) > 1 else "")
    what = cells[2] if len(cells) > 2 else ""
    tag = "gate row %d (%s)" % (n, label(gate))
    mech = mechanisms(where)
    if not mech:
        bad("%s names no mechanism in its Where cell: %r" % (tag, where))
        continue
    ok("%s names a mechanism: %s" % (tag, ", ".join(mech)))

    tiers = claimed_tiers(where)
    for m in mech:
        if m.startswith("hook:") and m != "hook:any":
            named_guards.add(m.split(":", 1)[1])
        elif m.startswith("config:"):
            named_configs.add(m.split(":", 1)[1])
        elif m.startswith("command:"):
            named_commands.add(m.split(":", 1)[1])
        elif m == "plugin":
            plugin_rows.append(gate)

    # A promised prompt can only come from a hook: permissions.ask is empty at every
    # tier (asserted below), so a row that promises one and names no hook is exactly
    # the class of wrong claim this suite exists for.
    if re.search(r"approval prompt", what, re.I):
        prompt_rows += 1
        if any(m.startswith("hook:") for m in mech):
            ok("%s promises an approval prompt and names a hook for it" % tag)
        else:
            bad("%s promises an approval prompt but names no hook (%s); permissions.ask "
                "is empty at every tier, so nothing would prompt" % (tag, ", ".join(mech)))

    lits = re.findall(r"`([^`]+)`", gate)
    if not lits:
        continue                    # a row about the tier knob itself, or the sandbox

    uncovered, tier_drift, exercised = [], [], set()
    for lit in lits:
        covered = False
        for m in mech:
            if m.startswith("rules:"):
                kind = m.split(":", 1)[1]
                have = tuple(t for t in TIERS if rule_covers(lit, rules(t, kind)))
                if have:
                    covered = True
                    exercised.add(m)
                    if have != tiers:
                        tier_drift.append("`%s` is in permissions.%s at %s, the row claims %s"
                                          % (lit, kind, ",".join(have), ",".join(tiers)))
            elif m.startswith("hook:"):
                g = m.split(":", 1)[1]
                if guard_covers(lit, any_corpus if g == "any" else guard_corpus(g)):
                    covered = True
                    exercised.add(m)
            elif m == "sandbox":
                if any(lit in json.dumps(gen(t).get("sandbox") or {}) for t in tiers):
                    covered = True
                    exercised.add(m)
        if not covered:
            uncovered.append(lit)

    if uncovered:
        bad("%s promises a gate no mechanism covers: %s (tried %s)"
            % (tag, ", ".join("`%s`" % u for u in uncovered), ", ".join(mech)))
    else:
        ok("%s: all %d gated literals resolve to %s" % (tag, len(lits), ", ".join(mech)))

    if tier_drift:
        bad("%s claims the wrong tiers: %s" % (tag, "; ".join(tier_drift)))
    else:
        ok("%s: every rule it rests on is emitted at exactly %s" % (tag, ",".join(tiers)))

    idle = [m for m in mech
            if m not in exercised and not m.startswith(("config:", "command:")) and m != "plugin"]
    if idle:
        bad("%s names %s, which covers none of its own literals"
            % (tag, ", ".join(idle)))
    else:
        ok("%s: every mechanism it names covers at least one of its literals" % tag)

# ── the mechanisms the table named, checked once each ──────────────────────
for guard in sorted(named_guards):
    path = os.path.join(HOOKS_DIR, guard)
    if not os.path.isfile(path):
        bad("the gate table names %s, which does not exist under .claude/hooks/" % guard)
        continue
    if guard not in all_guards:
        bad("%s exists but .claude/settings.json does not wire it into PreToolUse" % guard)
        continue
    if guard not in registered(os.path.join(ROOT, "plugin/hooks/hooks.json")):
        bad("%s is wired in .claude/settings.json but missing from plugin/hooks/hooks.json "
            "(a plugin install would never run it)" % guard)
        continue
    ok("%s exists and is wired into PreToolUse in both settings.json and the plugin" % guard)

for cfg in sorted(named_configs):
    if os.path.isfile(os.path.join(ROOT, cfg)):
        ok("the gate table names %s, and it exists" % cfg)
    else:
        bad("the gate table names %s, which does not exist" % cfg)

for cmd in sorted(named_commands):
    if os.path.isfile(os.path.join(ROOT, ".claude/commands/%s.md" % cmd)):
        ok("the gate table names /%s, and .claude/commands/%s.md exists" % (cmd, cmd))
    else:
        bad("the gate table names /%s, but .claude/commands/%s.md does not exist" % (cmd, cmd))

if plugin_rows:
    try:
        with open(os.path.join(ROOT, ".claude/settings.json"), encoding="utf-8") as fh:
            enabled = json.load(fh).get("enabledPlugins") or {}
    except (OSError, ValueError):
        enabled = {}
    for gate in plugin_rows:
        wanted = re.findall(r"\[([A-Za-z0-9_.-]+)\]", gate) or [label(gate)]
        missing = [w for w in wanted
                   if not any(k == w or k.startswith(w + "@") for k in enabled)]
        if missing:
            bad("the gate table credits %s with its own hooks, but %s is not in "
                "enabledPlugins" % (gate, ", ".join(missing)))
        else:
            ok("%s is enabled in settings.json, so its own hooks do run" % ", ".join(wanted))

# The precondition the prompt rule rests on, and the reason every prompt is a hook.
for tier in TIERS:
    n = len(rules(tier, "ask"))
    if n:
        bad("%s emits %d permissions.ask entries; the gate table's prompts are documented "
            "as hooks because ask is empty and hard-fails headless" % (tier, n))
    else:
        ok("%s emits no permissions.ask entries (so a documented prompt must be a hook)" % tier)

# ── README.md: the Firewall-tiers table ───────────────────────────────────
heads, tier_rows = table(README, "Tier")
print("ROWS|readme|%d" % len(tier_rows))
COL = "On-chain and destructive"
if COL not in heads:
    bad("README's Firewall-tiers table has no %r column (headers: %s)" % (COL, heads))
else:
    idx = heads.index(COL)
    for cells in tier_rows:
        tier = next((t for t in TIERS if re.search(r"\b%s\b" % t, cells[0], re.I)), None)
        if tier is None:
            bad("a README Firewall-tiers row names no tier: %r" % cells[0])
            continue
        lits = re.findall(r"`([^`]+)`", cells[idx] if idx < len(cells) else "")
        if not lits:
            bad("README's %s row promises nothing in its %s column, so nothing is pinned"
                % (tier, COL))
            continue
        miss = [l for l in lits
                if not rule_covers(l, rules(tier, "deny")) and not guard_covers(l, any_corpus)]
        if miss:
            bad("README's %s row promises a gate nothing covers at that tier: %s"
                % (tier, ", ".join("`%s`" % m for m in miss)))
        else:
            ok("README's %s row: all %d gated commands resolve to a %s deny rule or a guard"
               % (tier, len(lits), tier))
PY
RESOLVER_RC=$?
set -e

echo "[resolver]"
TOTAL=$((TOTAL + 1))
if [ "$RESOLVER_RC" -eq 0 ]; then
  echo "  PASS: the resolver ran to completion"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the resolver exited $RESOLVER_RC"
  tail -20 "$WORK/resolver.err" 2>/dev/null | sed 's/^/      /' || true
  FAIL=$((FAIL + 1))
  print_summary
fi

# A parser that silently stops finding rows would otherwise report a clean run over an
# empty set, which is the one way this suite could pass for having checked nothing.
GATE_ROWS="$(sed -n 's/^ROWS|gate|//p' "$VERDICTS")"
README_ROWS="$(sed -n 's/^ROWS|readme|//p' "$VERDICTS")"
TOTAL=$((TOTAL + 1))
if [ "${GATE_ROWS:-0}" -ge 10 ] 2>/dev/null; then
  echo "  PASS: the gate table parsed into $GATE_ROWS rows"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the gate table parsed into ${GATE_ROWS:-no} rows (expected at least 10)"
  FAIL=$((FAIL + 1))
fi
assert_eq "4" "${README_ROWS:-0}" "README's Firewall-tiers table parsed into one row per tier"

VERDICT_COUNT="$(grep -cE '^(PASS|FAIL)\|' "$VERDICTS" 2>/dev/null || true)"
TOTAL=$((TOTAL + 1))
if [ "${VERDICT_COUNT:-0}" -ge 40 ] 2>/dev/null; then
  echo "  PASS: the resolver reached a verdict on $VERDICT_COUNT claims"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the resolver reached only ${VERDICT_COUNT:-0} verdicts (expected at least 40)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "[documented gates vs enforcing mechanisms]"
while IFS='|' read -r verdict message; do
  case "$verdict" in
    PASS)
      TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
      echo "  PASS: $message" ;;
    FAIL)
      TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
      echo "  FAIL: $message" ;;
  esac
done < "$VERDICTS"

print_summary
