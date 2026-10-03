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

# ── the never-allowed set varies only where it provably can ─────────────────
# Deny is merge-monotonic: lists union across settings sources and there is no un-deny,
# so a deny that reaches a user or managed file cannot be taken back on the way down a
# tier. That is why every Bash deny is identical at every tier, and the assertion below
# is what keeps it that way.
#
# The one sanctioned exception is MCP tool-name denies. They are safe because MCP rules
# have no argument form at all (a parenthesised mcp__ rule is skipped on load), so a
# tool-name deny is the only expressible gate, and because firewall.sh writes one file
# and subtracts exactly its recorded ruleIds -- which the relaxed -> high -> relaxed
# byte-identity test above is the proof of. Anything else that starts varying by tier
# here is the bug this test exists to catch.
echo "[never-allowed set]"
DENY_DRIFT="$(python3 -c "
import json
base = None
drift = []
for t in '$TIERS'.split():
    deny = (json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}).get('deny') or []
    bash_only = sorted(r for r in deny if not r.startswith('mcp__'))
    if base is None:
        base = bash_only
    elif bash_only != base:
        drift.append(t)
print(';'.join(drift) or 'none')" 2>/dev/null)"
assert_eq "none" "$DENY_DRIFT" "every non-MCP permissions.deny entry is identical across all four tiers"

MCP_BY_TIER="$(python3 -c "
import json
out = []
for t in '$TIERS'.split():
    deny = (json.load(open('$WORK/gen.%s.json' % t)).get('permissions') or {}).get('deny') or []
    out.append('%s=%d' % (t, len([r for r in deny if r.startswith('mcp__')])))
print(' '.join(out))" 2>/dev/null)"
assert_eq "off=0 relaxed=0 medium=5 high=5" "$MCP_BY_TIER" \
  "only medium and high deny MCP tools by name (off and relaxed rely on the hooks)"

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
if [ "$DENY_DRIFT" != "none" ]; then
  printf '    non-MCP deny drifted at: %s\n' "$DENY_DRIFT"
  printf '    mcp denies per tier: %s\n' "$MCP_BY_TIER"
fi
# A few members of that set, spot-checked once (the full list lives in the generator).
DENY_LIVE="$(python3 -c "
import json
print('\n'.join((json.load(open('$WORK/gen.relaxed.json')).get('permissions') or {}).get('deny') or []))" 2>/dev/null)"
for r in "Bash(claude *)" "Bash(env *)" "Bash(git -c *)" "Bash(git -C *)" "Bash(security *)"; do
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$DENY_LIVE" | grep -qxF "$r"; then
    echo "  PASS: the never-allowed set denies $r"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: the never-allowed set is missing $r"
    FAIL=$((FAIL + 1))
  fi
done
# Self-protection uses Edit(...), not Read(...): a Read deny also blocks Edit and Write
# but leaves NotebookEdit open, and would stop the kit reading its own config.
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$DENY_LIVE" | grep -qF 'Edit(/.claude/security.json)' \
   && ! printf '%s\n' "$DENY_LIVE" | grep -qF 'Read(/.claude/security.json)'; then
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
