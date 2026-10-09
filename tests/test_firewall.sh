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
if [ "$LINK_RC" -ne 0 ] || printf '%s' "$LINK_OUT" | grep -qiE 'symlink|symbolic|skip'; then
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

# ── every two-wildcard rule has a zero-gap twin ─────────────────────────────
# A mid-pattern * does not match an empty string: Bash(anchor * --final*) did not stop
# `anchor --final`, and Bash(git push * -f *) did not stop `git push origin -f`.
echo "[zero-gap twins]"
for t in $TIERS; do
  GAPS="$(python3 -c "
import fnmatch, json, re, sys

def inner(rule):
    return rule[5:-1] if rule.startswith('Bash(') and rule.endswith(')') else None

def zero_gap(pat):
    'every spelling of pat with one mid-pattern * collapsed away'
    out = []
    for i, ch in enumerate(pat):
        if ch != '*' or i == 0 or i == len(pat) - 1:
            continue
        cand = re.sub(r' +', ' ', pat[:i] + pat[i + 1:]).strip()
        if cand and cand != pat:
            out.append(cand)
    return out

def probe(pat):
    'the shortest command the pattern describes: trailing * -> empty, mid * -> a token'
    p = pat[:-1] if pat.endswith('*') else pat
    return re.sub(r' +', ' ', p.replace('*', 'ZZZ')).strip()

bad = []
perms = json.load(open('$WORK/gen.$t.json')).get('permissions') or {}
for key in ('deny', 'ask'):
    rules = perms.get(key) or []
    pats = [inner(r) for r in rules]
    pats = [p for p in pats if p]
    have = set(pats)
    for pat in pats:
        if pat.count('*') < 2:
            continue
        for twin in zero_gap(pat):
            if twin in have:
                continue
            cmd = probe(twin)
            if any(fnmatch.fnmatchcase(cmd, other) for other in pats if other != pat):
                continue
            bad.append(f'{key}:{pat} -> missing Bash({twin})')
print('; '.join(sorted(set(bad))[:6]) or 'none')" 2>/dev/null)"
  assert_eq "none" "$GAPS" "$t: every two-wildcard rule has a zero-gap twin (or another rule covers it)"
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
# Three sanctioned exceptions, all safe for the same reason: firewall.sh writes one file
# and subtracts exactly its recorded ruleIds, which the relaxed -> high -> relaxed and
# high -> medium byte-identity tests above are the proof of.
#   * MCP tool-name denies -- MCP rules have no argument form at all (a parenthesised
#     mcp__ rule is skipped on load), so a tool-name deny is the only expressible gate.
#   * The self-protection Edit denies, High only, because below High the kit defers to a
#     user customizing their own installation.
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
ALLOWED = {'Bash(gh api *)'}
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
  "only MCP tool-name denies, self-protection Edit denies and the one named Bash rule vary by tier"

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
assert_eq "off=0 relaxed=0 medium=5 high=6" "$MCP_BY_TIER" \
  "only medium and high deny MCP tools by name (off and relaxed rely on the hooks)"

# ── which MCP executor each tier refuses ────────────────────────────────────
# context-mode ships on by default, so both gated tiers have to speak for a user who
# never chose it. Cloudflare is opt-in behind a user-scoped API token, so attaching it is
# itself a decision: Medium respects that, High does not, because "no arbitrary executor
# is reachable" is High's whole proposition. This is the only place the two gated tiers'
# deny sets differ, which is why it is asserted by exact tool name rather than by count.
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
done
assert_eq "yes" "$(mcp_denied medium mcp__context-mode__ctx_execute)" \
  "medium denies context-mode's ctx_execute (a default-on executor)"
assert_eq "no" "$(mcp_denied medium mcp__cloudflare__execute)" \
  "medium leaves cloudflare's execute callable (opt-in, so attaching it is the user's choice)"
for tool in mcp__context-mode__ctx_execute mcp__cloudflare__execute; do
  assert_eq "yes" "$(mcp_denied high "$tool")" "high denies $tool"
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
for r in "Bash(claude *)" "Bash(env *)" "Bash(git -c *)" "Bash(git -C *)" "Bash(security *)" \
         "Edit(/.safe-ai-skill/**)"; do
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$DENY_LIVE" | grep -qxF "$r"; then
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

# gh api's per-tier assertion used to sit here, pinned as deny at medium|high and allow
# at off|relaxed. It is gone because two checks already hold it from both directions: the
# BASH_VARY assertion above pins the exact rule string to the exact tier set, and
# tests/test_doc_gates.sh reads "deny rule, **Medium and High only**" out of the gate
# table itself and requires the covered tier set to equal exactly that.
#
# Self-protection uses Edit(...), not Read(...): a Read deny also blocks Edit and Write
# but leaves NotebookEdit open, and would stop the kit reading its own config. Checked
# against High, the only tier that carries the self-protection group at all.
DENY_HIGH="$(python3 -c "
import json
print('\n'.join((json.load(open('$WORK/gen.high.json')).get('permissions') or {}).get('deny') or []))" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$DENY_HIGH" | grep -qF 'Edit(/.claude/security.json)' \
   && ! printf '%s\n' "$DENY_HIGH" | grep -qF 'Read(/.claude/security.json)'; then
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

print_summary
