#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Split out of tests/test_update.sh: the firewall tier migration /update runs, and the
# fixed scratch-file names its JSON rewrites must never write through. Its own install,
# so it runs beside test_update.sh rather than after it.
FW_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$FW_DIR"' EXIT

echo "[test_update_firewall] update.sh: firewall tier migration and JSON scratch files"
echo ""

# --- Firewall tier migration: the three ways it can resolve ------------------
# No security.json means a pre-firewall install. What happens next depends only on
# whether the permissions block is still the one the kit shipped.
echo "[firewall tier migration]"
(cd "$FW_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$FW_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"
FW_SETTINGS="$FW_DIR/.claude/settings.json"
FW_SECURITY="$FW_DIR/.claude/security.json"
# A settings.json the kit really shipped, straight from its tag, so the baseline hash in
# update.sh is matched by construction rather than by a copy that drifts.
#
# The tag is not present in a shallow clone, which is what `actions/checkout` produces by
# default — so try to fetch it, and if it still is not there, skip this section loudly
# instead of failing. A test that needs network or full history must say so rather than
# reporting a feature as broken.
FW_TAG_OK=yes
if ! git -C "$REPO_ROOT" show v2.1.0:.claude/settings.json > "$FW_DIR/pre-firewall.json" 2>/dev/null; then
  fetch_tag v2.1.0 || true
  git -C "$REPO_ROOT" show v2.1.0:.claude/settings.json > "$FW_DIR/pre-firewall.json" 2>/dev/null || FW_TAG_OK=no
fi
if [ "$FW_TAG_OK" = no ]; then
  echo "  SKIP: firewall tier migration needs the v2.1.0 tag (shallow clone and no network)"
else
assert_json_valid "$FW_DIR/pre-firewall.json" "a pre-firewall settings.json is available from the v2.1.0 tag"

# The frozen byte range, asserted here because the tag is in hand. update.sh's copy loop
# overwrites the running script and bash resumes reading by byte offset, so a change in
# lines 1-93 breaks self-update for every existing install. Nothing else checked this.
assert_eq "$(git -C "$REPO_ROOT" show v2.1.0:.claude/bin/update.sh | head -93 | shasum | cut -d' ' -f1)" \
  "$(head -93 "$REPO_ROOT/.claude/bin/update.sh" | shasum | cut -d' ' -f1)" \
  "update.sh lines 1-93 are byte-identical to v2.1.0 (the frozen range)"

fw_reset() {  # fw_reset <settings source> — back to a pre-firewall install
  rm -f "$FW_SECURITY" "$FW_SETTINGS"
  cp "$1" "$FW_SETTINGS"
}
fw_tier() {
  python3 -c "
import json
try: print(json.load(open('$FW_SECURITY')).get('tier', '__MISSING__'))
except Exception: print('__NOFILE__')" 2>/dev/null
}
fw_update() {
  (cd "$FW_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@" 2>&1) || true
}

# (1) baseline permissions -> adopt relaxed
fw_reset "$FW_DIR/pre-firewall.json"
FW_DRY="$(fw_update --dry-run)"
assert_contains "$FW_DRY" "[would set] .claude/security.json: tier relaxed" \
  "--dry-run reports adopting relaxed on a pre-firewall install"
assert_eq "__NOFILE__" "$(fw_tier)" "--dry-run writes no security.json"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" ".claude/security.json: tier relaxed" "a baseline install adopts relaxed"
assert_eq "relaxed" "$(fw_tier)" "security.json records tier relaxed"
assert_json_valid "$FW_SETTINGS" "settings.json is still valid JSON after the migration"
# Running again must not re-resolve: /firewall owns the tier once it is recorded.
python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); d["tier"] = "high"
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SECURITY"
fw_update >/dev/null
assert_eq "high" "$(fw_tier)" "a recorded tier is never re-resolved by a later update"

# (2) hand-edited permissions -> adopt off, say so, and touch nothing
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d.setdefault("permissions", {}).setdefault("allow", []).append("Bash(my-own-tool *)")
json.dump(d, open(sys.argv[2], "w"), indent=2)' "$FW_DIR/pre-firewall.json" "$FW_DIR/tuned.json"
fw_reset "$FW_DIR/tuned.json"
cp "$FW_SETTINGS" "$FW_DIR/tuned.before"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "tier off (permissions were tuned here)" \
  "a hand-edited policy adopts off instead of being rewritten"
assert_contains "$FW_OUT" "Run /firewall relaxed to adopt the kit set" \
  "the notice says how to opt in"
assert_eq "off" "$(fw_tier)" "security.json records tier off"
# What tier off promises is the permission policy, not the whole file: the same run also
# registers the kit hooks this pre-firewall install never had (issue #91), which is a
# different surface and an append rather than a rewrite. So compare the two blocks the
# notice is actually about, and assert the hooks landed beside them.
fw_policy() {  # fw_policy <settings file> — the permissions + sandbox blocks, canonical
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps({k: d.get(k) for k in ('permissions', 'sandbox')}, sort_keys=True))" "$1"
}
assert_eq "$(fw_policy "$FW_DIR/tuned.before")" "$(fw_policy "$FW_SETTINGS")" \
  "a tuned permissions and sandbox policy is left byte-identical"
assert_file_contains "$FW_SETTINGS" "Bash(my-own-tool *)" "the user's own rule survives"
assert_file_contains "$FW_SETTINGS" "secrets-guard.sh" \
  "the kit's guards are registered even where the tier backs off to off"

# (3) symlinked settings.json -> skipped, nothing written
fw_reset "$FW_DIR/pre-firewall.json"
mv "$FW_SETTINGS" "$FW_DIR/real-settings.json"
ln -s "$FW_DIR/real-settings.json" "$FW_SETTINGS"
cp "$FW_DIR/real-settings.json" "$FW_DIR/link.before"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "[skipped] firewall tier:" "a symlinked settings.json is reported as skipped"
assert_contains "$FW_OUT" "symlink" "the skip message says why"
assert_eq "__NOFILE__" "$(fw_tier)" "no security.json is written when settings.json is a symlink"
assert_cmd_success "cmp -s '$FW_DIR/link.before' '$FW_DIR/real-settings.json'" \
  "the symlink target is left byte-identical"
rm -f "$FW_SETTINGS"

# (4) MCP gating reaches an install that already has a security.json.
#
# This is the case the pre-firewall migration above deliberately skips, so without the
# catch-up it is the case that never receives a rule change. Two independent things have
# to land: the PreToolUse matcher in settings.json (which update.sh never overwrites and
# firewall.sh never manages) and the regenerated rule block (which needs the
# ruleSetVersion comparison to fire).
echo "[MCP gating migration]"
# The fixture is a CURRENT install, not the v2.1.0 one used above: at that tag the hook
# bodies were still inline in settings.json, so none of its entries name a guard script
# and the migration correctly declines to touch them — which would make every assertion
# below pass for the wrong reason. (It did, before this comment existed.)
cp "$REPO_ROOT/.claude/settings.json" "$FW_SETTINGS"
cp "$REPO_ROOT/.claude/security.json" "$FW_SECURITY"
assert_eq "3" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {}).get('PreToolUse') or []
print(len([e for e in hooks
           if e.get('matcher') == 'Bash|mcp__context-mode__.*'
           and any(g in ' '.join(h.get('command','') for h in e.get('hooks') or [])
                  for g in ('secrets-guard','onchain-guard','egress-guard'))]))" 2>/dev/null)" \
  "the fixture really has three kit guard registrations to migrate"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["tier"] = "high"
# An install generated by the previous rule set, with the old Bash-only matcher.
(d.get("enforced") or {})["ruleSetVersion"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SECURITY"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
pre = (d.get("hooks") or {}).get("PreToolUse", [])
# That install predates the Read|Grep entry too.
pre[:] = [e for e in pre if e.get("matcher") != "Read|Grep"]
for e in pre:
    e["matcher"] = "Bash"
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SETTINGS"

# The rule-set version this kit ships; the catch-up goes from 1 to it.
FW_RS="$(awk -F= '/^RULE_SET_VERSION[[:space:]]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$REPO_ROOT/.claude/bin/firewall.sh")"
FW_DRY="$(fw_update --dry-run)"
assert_contains "$FW_DRY" "PreToolUse matcher" "--dry-run reports the matcher migration"
assert_contains "$FW_DRY" "firewall rule set v1 -> v$FW_RS" "--dry-run reports the rule-set catch-up"
assert_eq "Bash" "$(python3 -c "
import json
print((json.load(open('$FW_SETTINGS')).get('hooks') or {})['PreToolUse'][0]['matcher'])" 2>/dev/null)" \
  "--dry-run rewrites no matcher"

FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "PreToolUse matcher" "the matcher migration is reported"
assert_json_valid "$FW_SETTINGS" "settings.json is still valid JSON after the matcher rewrite"
assert_eq "0" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {}).get('PreToolUse') or []
bad = [e for e in hooks
       if any(g in ' '.join(h.get('command','') for h in e.get('hooks') or [])
              for g in ('secrets-guard','onchain-guard','egress-guard'))
       and e.get('matcher') not in ('Bash|mcp__context-mode__.*', 'Read|Grep')]
print(len(bad))" 2>/dev/null)" \
  "every kit guard now matches Bash and context-mode's MCP tools"
assert_eq "1" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {}).get('PreToolUse') or []
print(len([e for e in hooks if e.get('matcher') == 'Read|Grep'
           and 'secrets-guard' in ' '.join(h.get('command','') for h in e.get('hooks') or [])]))" 2>/dev/null)" \
  "the same update registers secrets-guard on Read and Grep (hook set 3)"
# The rule-set catch-up has to have re-applied High, which is what adds the tool denies:
# context-mode's five and Playwright's two, plus mcp__cloudflare__execute and
# mcp__playwright__browser_evaluate, which only High carries.
assert_eq "9" "$(python3 -c "
import json
p = json.load(open('$FW_SETTINGS')).get('permissions') or {}
print(len([r for r in (p.get('deny') or []) if r.startswith('mcp__')]))" 2>/dev/null)" \
  "re-applying High on an older rule set adds the MCP executor denies"
assert_eq "$FW_RS" "$(python3 -c "
import json
print((json.load(open('$FW_SECURITY')).get('enforced') or {}).get('ruleSetVersion'))" 2>/dev/null)" \
  "security.json records the new rule-set version"
assert_eq "high" "$(fw_tier)" "the declared tier is preserved by the catch-up"
# Idempotent: a second run has nothing to say and changes nothing.
cp "$FW_SETTINGS" "$FW_DIR/mcp.before"
FW_OUT="$(fw_update)"
assert_eq "no" "$(grep -q 'PreToolUse matcher' <<<"$FW_OUT" && echo yes || echo no)" \
  "a second update does not report the matcher migration again"
assert_eq "no" "$(grep -q 'firewall rule set v' <<<"$FW_OUT" && echo yes || echo no)" \
  "a second update does not report the rule-set catch-up again"
assert_cmd_success "cmp -s '$FW_DIR/mcp.before' '$FW_SETTINGS'" \
  "a second update leaves settings.json byte-identical"
# A matcher the user narrowed themselves is theirs, not the kit's to widen.
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d.setdefault("hooks", {}).setdefault("PreToolUse", []).append(
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-audit-hook"}]})
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SETTINGS"
fw_update >/dev/null
assert_eq "Bash" "$(python3 -c "
import json
hooks = (json.load(open('$FW_SETTINGS')).get('hooks') or {})['PreToolUse']
print([e['matcher'] for e in hooks if 'my-own-audit-hook' in ' '.join(h.get('command','') for h in e['hooks'])][0])" 2>/dev/null)" \
  "a non-kit Bash hook keeps its own matcher"

# (5) /update never carries a project onto the maintainer tier, nor re-applies it. A
# project that declares it (copied out of a kit checkout) is reported, not regenerated,
# even with a rule set behind the shipped one — the case that otherwise re-applies.
echo "[maintainer tier is never re-applied]"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["tier"] = "maintainer"
(d.get("enforced") or {})["ruleSetVersion"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$FW_SECURITY"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "declares the maintainer tier" "a declared maintainer tier is reported by /update"
assert_eq "no" "$(printf '%s' "$FW_OUT" | grep -q 'firewall rule set v' && echo yes || echo no)" \
  "/update does not re-apply the maintainer tier on an older rule set"
assert_eq "maintainer" "$(fw_tier)" "/update leaves the declared tier for the user to change"
assert_eq "no" "$(grep -q '"git submodule \*"' "$FW_SETTINGS" && echo yes || echo no)" \
  "/update writes no maintainer rule into settings.json"

# #308: the same file on one line (json.dump's default). A line match read the last
# "tier" on it, enforced.tier, and glued every digit on the line into the rule set, so
# a declared maintainer was missed and the catch-up compared against a garbage number.
echo "[one-line security.json: the declared tier and the recorded rule set]"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["tier"] = "maintainer"
d.setdefault("enforced", {})["tier"] = "relaxed"
d["enforced"]["ruleSetVersion"] = 1
json.dump(d, open(sys.argv[1], "w"))' "$FW_SECURITY"
assert_eq "1" "$(awk 'END { print NR }' "$FW_SECURITY")" "control: the fixture security.json is one line"
assert_eq "relaxed" "$(awk '/"tier"[[:space:]]*:/{t=$0; sub(/.*"tier"[^"]*"/,"",t); sub(/".*/,"",t); print t; exit}' "$FW_SECURITY")" \
  "control: the old line match reads enforced.tier off it"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "declares the maintainer tier" "one line: a declared maintainer tier is still reported"
assert_eq "no" "$(printf '%s' "$FW_OUT" | grep -q 'firewall.sh apply failed' && echo yes || echo no)" \
  "one line: no failed apply is reported for a declared maintainer tier"
assert_eq "maintainer" "$(fw_tier)" "one line: the declared maintainer tier is left alone"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["tier"] = "high"
d["enforced"]["tier"] = "relaxed"
d["enforced"]["ruleSetVersion"] = 1
json.dump(d, open(sys.argv[1], "w"))' "$FW_SECURITY"
FW_OUT="$(fw_update)"
assert_contains "$FW_OUT" "firewall rule set v1 -> v" "one line: the catch-up reads enforced.ruleSetVersion 1"
assert_contains "$FW_OUT" "(high re-applied)" "one line: the catch-up re-applies the top-level tier, not the record"
assert_eq "high" "$(fw_tier)" "one line: the declared high tier survives the catch-up"
rm -f "$FW_SETTINGS" "$FW_SECURITY"
fi  # FW_TAG_OK

# The JSON rewrites went through fixed names as well, so a repo could plant a link at
# any of them. A fresh install's first /update rewrites security.json and settings.json,
# and a firewall apply rewrites them again.
echo "[json scratch files]"
JP="$(new_tmp)" || exit 1
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$JP" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"
PLANTED="security.json.firewall.tmp settings.json.mcp.tmp security.json.hooks.tmp settings.json.hooks.tmp .settings.json.firewall.tmp .security.json.firewall.tmp"
for n in $PLANTED; do printf 'PRECIOUS\n' > "$FW_DIR/victim-$n"; ln -s "$FW_DIR/victim-$n" "$JP/.claude/$n"; done
(cd "$JP" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
(cd "$JP" && CLAUDE_PROJECT_DIR="$JP" bash .claude/bin/firewall.sh apply relaxed) > "$QUIET_LOG" 2>&1 || quiet_fail "firewall.sh apply"
HIT=""
for n in $PLANTED; do [ "$(cat "$FW_DIR/victim-$n")" = PRECIOUS ] || HIT="$HIT $n"; done
assert_eq "" "$HIT" "neither /update nor firewall.sh writes through a link planted at a fixed scratch-file name"
rm -rf "$JP"

print_summary
