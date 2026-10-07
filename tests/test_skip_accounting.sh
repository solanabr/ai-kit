#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# The skip mechanism itself. An uninitialized ext/ pack is setup state, so the suites
# record those checks as skipped rather than failed (tests/helpers.sh). Nothing else
# holds that in place: a skip put back as a hard FAIL, a suite whose skips stop being
# counted, or — the one that actually costs coverage — a skip widened to swallow a
# missing file in a pack that IS checked out, which is the upstream-rename case the
# checks exist for.
#
# Everything here runs against fixtures built in a temp dir, never against this repo's
# own submodule state, so it holds in CI (submodules checked out) and in a bare worktree
# alike. The counters are probed in child shells: this suite shares PASS/FAIL/TOTAL/SKIP
# with the code it measures, so measuring in-process would corrupt both.
echo "[test_skip_accounting] skip(), print_summary, run_all.sh classification, and what must still fail"
echo ""

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

CONVERTED="test_install_agents_only test_local_skills test_resync test_skill_extensions test_skills"

# probe <name> <body> — run <body> in a child shell with helpers.sh sourced, and print
# everything it wrote plus a final "COUNTS <pass> <fail> <total> <skip>" line.
probe() {
  local f="$TEMP_DIR/probe-$1.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'source "%s"\n' "$SCRIPT_DIR/helpers.sh"
    printf '%s\n' "$2"
    printf 'echo "COUNTS $PASS $FAIL $TOTAL $SKIP"\n'
  } > "$f"
  # SAK_SKIP_REPORT cleared: a fixture's skips are the thing under test, not setup state
  # for a user to fix, so they must not reach run_all.sh's run-wide report.
  SAK_SKIP_REPORT= bash "$f" 2>&1 || true
}

# counts <name> <body> — just the counters that body left behind.
counts() {
  probe "$@" | sed -n 's/^COUNTS //p'
}

# --- skip() touches the skip counter and nothing else -------------------------------
echo "[skip]"
assert_eq "0 0 0 1" "$(counts one 'skip "a check that needs a pack"')" \
  "skip records a skip and leaves passed, failed and total alone"
assert_eq "0 0 0 3" "$(counts three 'skip a; skip b; skip c')" \
  "every skip is counted on its own"
assert_eq "1 0 1 1" "$(counts mixed 'assert_eq a a "p"; skip "s"')" \
  "a skip beside a pass adds to neither the pass count nor the total"
assert_eq "1 1 2 1" "$(counts all 'assert_eq a a "p"; assert_eq a b "f"; skip "s"')" \
  "a skip beside a pass and a failure leaves both their counters alone"
assert_contains "$(probe says 'skip "its ext/ pack is not checked out"')" \
  "SKIP: its ext/ pack is not checked out" "skip names the check it stands for"

# --- print_summary reports the skips, and the three counts add up to its total -------
echo "[print_summary]"
# <pass>+<fail>+<skip> == the total print_summary states, whatever the shape.
summary_adds_up() {
  python3 - "$1" <<'PY'
import re, sys
lines = [l for l in sys.argv[1].splitlines() if l.startswith("Results:")]
if len(lines) != 1:
    print("expected one Results line, got %d" % len(lines))
    raise SystemExit
m = re.match(r"^Results: (\d+) passed, (\d+) failed(?:, (\d+) skipped)? \(of (\d+) checks\)$", lines[0])
if not m:
    print("unparsed: " + lines[0])
    raise SystemExit
p, f, s, t = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0), int(m.group(4))
print("adds up" if p + f + s == t else "%d+%d+%d != %d" % (p, f, s, t))
PY
}
SUM_SKIPS="$(probe sum-skips 'assert_eq a a "p"; assert_eq a b "f"; skip "s1"; skip "s2"; print_summary || true')"
assert_contains "$SUM_SKIPS" "Results: 1 passed, 1 failed, 2 skipped (of 4 checks)" \
  "print_summary states the skip count and folds it into the total"
assert_eq "adds up" "$(summary_adds_up "$SUM_SKIPS")" \
  "passed + failed + skipped equals the total print_summary states"
assert_contains "$SUM_SKIPS" "submodule update --init" "print_summary names the remedy for a skip"
SUM_NONE="$(probe sum-none 'assert_eq a a "p"; assert_eq a a "q"; print_summary')"
assert_contains "$SUM_NONE" "Results: 2 passed, 0 failed (of 2 checks)" \
  "with nothing skipped the Results line is the one it always was"
assert_eq "adds up" "$(summary_adds_up "$SUM_NONE")" \
  "passed + failed equals the total when nothing is skipped"
printf '%s\n' "$SUM_NONE" > "$TEMP_DIR/sum-none.out"
assert_file_not_contains "$TEMP_DIR/sum-none.out" "submodule update --init" \
  "with nothing skipped print_summary says nothing about submodules"

# --- print_summary's return value: 1 for a failure, 2 for skips only, 0 otherwise ----
echo "[exit codes]"
rc_of() {
  local rc=0
  SAK_SKIP_REPORT= bash "$1" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
write_suite() {
  local path="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'source "$(dirname "$0")/helpers.sh"\n'
    printf '%s\n' "$body"
    printf 'print_summary\n'
  } > "$path"
}

SUITES="$TEMP_DIR/suites"
mkdir -p "$SUITES"
cp "$SCRIPT_DIR/helpers.sh" "$SCRIPT_DIR/run_all.sh" "$SUITES/"
# run_all.sh refuses to run at all without these two, so the fixture carries them.
write_suite "$SUITES/test_firewall.sh" 'assert_eq a a "firewall stub"'
write_suite "$SUITES/test_egress_guard.sh" 'assert_eq a a "egress stub"'
write_suite "$SUITES/test_skiponly.sh" 'skip "the only thing this suite did"'

assert_eq "2" "$(rc_of "$SUITES/test_skiponly.sh")" \
  "print_summary returns 2 for a suite that recorded nothing but skips"
assert_eq "0" "$(rc_of "$SUITES/test_firewall.sh")" "...0 for a suite that passed"
cp "$SCRIPT_DIR/helpers.sh" "$TEMP_DIR/"
write_suite "$TEMP_DIR/failing.sh" 'assert_eq a b "f"; skip "s"'
assert_eq "1" "$(rc_of "$TEMP_DIR/failing.sh")" \
  "...and 1 for a suite that failed, skips or no skips"

# --- run_all.sh counts a skip-only suite on its own line, not as a pass --------------
echo "[run_all]"
run_suites() {
  local out rc=0
  out="$(cd "$1" && SAK_SKIP_REPORT= bash ./run_all.sh 2>&1)" || rc=$?
  printf '%s\nRUNALL_RC=%s\n' "$out" "$rc"
}
SKIPONLY_RUN="$(run_suites "$SUITES")"
assert_contains "$SKIPONLY_RUN" "Suites: 2 passed, 0 failed, 1 skipped (of 3)" \
  "run_all.sh does not count a skip-only suite as a pass"
assert_contains "$SKIPONLY_RUN" "Suites that checked nothing but skips:" \
  "run_all.sh says which suites checked nothing but skips"
# Leading spaces kept: a needle starting with '-' reaches grep as an option.
assert_contains "$SKIPONLY_RUN" "  - test_skiponly" "...and names it"
assert_contains "$SKIPONLY_RUN" "Skipped 1 checks across 1 suite(s)" \
  "run_all.sh totals the skipped checks across the run"
assert_contains "$SKIPONLY_RUN" "RUNALL_RC=0" "A skip-only run is not a failed run"

# A suite that failed stays failed: it must not be absorbed into the skip classification.
FAILING="$TEMP_DIR/failing-suites"
mkdir -p "$FAILING"
cp "$SCRIPT_DIR/helpers.sh" "$SCRIPT_DIR/run_all.sh" "$FAILING/"
write_suite "$FAILING/test_firewall.sh" 'assert_eq a a "firewall stub"'
write_suite "$FAILING/test_egress_guard.sh" 'assert_eq a a "egress stub"'
write_suite "$FAILING/test_broken.sh" 'assert_eq a b "a real failure"; skip "and a skip"'
FAILING_RUN="$(run_suites "$FAILING")"
assert_contains "$FAILING_RUN" "Suites: 2 passed, 1 failed (of 3)" \
  "A suite that failed is counted as failed even when it also skipped"
assert_contains "$FAILING_RUN" "RUNALL_RC=1" "...and the run fails"
assert_contains "$FAILING_RUN" "Skipped 1 checks across 1 suite(s)" \
  "...while its skips are still reported"

# run_all.sh collects the per-suite counts through SAK_SKIP_REPORT, which is why the
# fixtures above run with it cleared. Assert the mechanism itself, so that clearing it
# cannot be mistaken for breaking it.
REPORT="$TEMP_DIR/skip-report"
: > "$REPORT"
write_suite "$TEMP_DIR/reports.sh" 'skip "one"; skip "two"'
SAK_SKIP_REPORT="$REPORT" bash "$TEMP_DIR/reports.sh" >/dev/null 2>&1 || true
assert_eq "$(printf 'reports\t2')" "$(cat "$REPORT")" \
  "print_summary appends '<suite> <skips>' to run_all.sh's run-wide report"

# A new suite needs no registration: run_all.sh globs the directory. If that ever
# becomes a list, this suite has to be added to it.
assert_file_contains "$SCRIPT_DIR/run_all.sh" 'for test_file in "$SCRIPT_DIR"/test_*.sh' \
  "run_all.sh discovers suites by glob, so a new test_*.sh is picked up on its own"

# --- ext_pack_empty: present AND empty, nothing else --------------------------------
echo "[ext_pack_empty]"
PACKS="$TEMP_DIR/packs"
mkdir -p "$PACKS/empty" "$PACKS/full" "$PACKS/dotfile-only"
: > "$PACKS/full/SKILL.md"
: > "$PACKS/dotfile-only/.git"
assert_cmd_success "ext_pack_empty '$PACKS/empty'" \
  "ext_pack_empty: true when the pack directory is present and empty"
assert_cmd_fails "ext_pack_empty '$PACKS/absent'" \
  "...false when the directory is not there at all"
assert_cmd_fails "ext_pack_empty '$PACKS/full'" \
  "...false when the pack is populated"
assert_cmd_fails "ext_pack_empty '$PACKS/dotfile-only'" \
  "...false for a pack holding only a dotfile, which is what a checkout leaves"

# --- in_uninitialized_submodule: the climb-out, the segment, and the populated case --
echo "[in_uninitialized_submodule]"
TREE="$TEMP_DIR/tree"
mkdir -p "$TREE/.claude/agents" "$TREE/.claude/commands" "$TREE/.claude/skills/a-skill" \
  "$TREE/.claude/skills/ext/emptypack" "$TREE/.claude/skills/ext/fullpack" \
  "$TREE/.agents/skills/ext/emptypack"
: > "$TREE/.claude/skills/ext/fullpack/SKILL.md"
assert_cmd_success "in_uninitialized_submodule '$TREE/.claude/skills/ext/emptypack/skill/SKILL.md'" \
  "in_uninitialized_submodule: true for an absolute path into an empty pack"
assert_cmd_success "in_uninitialized_submodule '$TREE/.claude/agents/../skills/ext/emptypack/x.md'" \
  "...resolves the dir/.. climb-out an agent or command link uses"
assert_cmd_success "in_uninitialized_submodule '$TREE/.claude/skills/a-skill/../ext/emptypack/x.md'" \
  "...and the ../ext/ form a skill folder uses"
assert_cmd_success "in_uninitialized_submodule '$TREE/.agents/skills/ext/emptypack/x.md'" \
  "...matches the skills/ext/<pack> segment in an .agents/ install too"
assert_cmd_success "(cd '$TREE/.claude' && in_uninitialized_submodule 'skills/ext/emptypack/x.md')" \
  "...and a path relative to the cwd"
# The one that actually matters: a pack that IS checked out with the file gone is a
# failure, not a skip. That is the upstream-rename case the link checks exist for.
assert_cmd_fails "in_uninitialized_submodule '$TREE/.claude/skills/ext/fullpack/renamed.md'" \
  "...FALSE for a missing file in a pack that is checked out"
assert_cmd_fails "in_uninitialized_submodule '$TREE/.claude/agents/../skills/ext/fullpack/renamed.md'" \
  "...false through the climb-out as well"
assert_cmd_fails "in_uninitialized_submodule '$TREE/.claude/skills/ext/nosuchpack/x.md'" \
  "...false when the pack directory is absent entirely"
assert_cmd_fails "in_uninitialized_submodule '$TREE/.claude/commands/doctor.md'" \
  "...false for a path with no skills/ext/ segment"

# --- ext_packs_uninitialized: the gate the pack-dependent regions sit behind ---------
echo "[ext_packs_uninitialized]"
# helpers.sh reads the ext/ packs of the repo it sits in, so a copy inside a fixture
# tree answers for that tree instead of for this one.
gate_probe() {
  mkdir -p "$1/tests"
  cp "$SCRIPT_DIR/helpers.sh" "$1/tests/"
  {
    printf 'set -euo pipefail\n'
    printf 'source "$(dirname "$0")/helpers.sh"\n'
    printf 'ext_packs_uninitialized\n'
  } > "$1/tests/gate.sh"
}
GATE_FULL="$TEMP_DIR/gate-full"
mkdir -p "$GATE_FULL/.claude/skills/ext/fullpack" "$GATE_FULL/.claude/skills/ext/alsofull"
: > "$GATE_FULL/.claude/skills/ext/fullpack/SKILL.md"
: > "$GATE_FULL/.claude/skills/ext/alsofull/SKILL.md"
gate_probe "$GATE_FULL"
assert_cmd_fails "bash '$GATE_FULL/tests/gate.sh'" \
  "ext_packs_uninitialized: false when every pack is populated, so a gated region runs for real"
GATE_ONE="$TEMP_DIR/gate-one-empty"
mkdir -p "$GATE_ONE/.claude/skills/ext/fullpack" "$GATE_ONE/.claude/skills/ext/emptypack"
: > "$GATE_ONE/.claude/skills/ext/fullpack/SKILL.md"
gate_probe "$GATE_ONE"
assert_cmd_success "bash '$GATE_ONE/tests/gate.sh'" \
  "...true when one pack is empty, since the gated blocks copy the whole ext/ tree"

# --- A broken link into a populated pack fails, in the suites that check links -------
echo "[a broken link into a populated pack]"
# test_skills.sh reads the hub of the repo it sits in, so a fixture repo holding one
# empty pack and one populated pack exercises both branches whatever this repo's
# submodules are doing.
LINKS="$TEMP_DIR/links"
mkdir -p "$LINKS/tests" "$LINKS/.claude/skills/ext/emptypack" "$LINKS/.claude/skills/ext/fullpack"
cp "$SCRIPT_DIR/helpers.sh" "$SCRIPT_DIR/test_skills.sh" "$LINKS/tests/"
: > "$LINKS/.claude/skills/ext/fullpack/placeholder.md"
: > "$LINKS/.claude/skills/local.md"
printf '# hub\n\n- [local](local.md)\n- [not checked out](ext/emptypack/x.md)\n- [renamed upstream](ext/fullpack/x.md)\n' \
  > "$LINKS/.claude/skills/SKILL.md"
LINKS_OUT="$(SAK_SKIP_REPORT= bash "$LINKS/tests/test_skills.sh" 2>&1 || true)"
assert_contains "$LINKS_OUT" "SKIP: ext/emptypack/x.md" \
  "test_skills.sh skips a link into a pack that is not checked out"
assert_contains "$LINKS_OUT" "FAIL: Broken link -> ext/fullpack/x.md" \
  "test_skills.sh FAILS a link into a pack that is checked out"
assert_contains "$LINKS_OUT" "Results: 2 passed, 1 failed, 1 skipped (of 4 checks)" \
  "...and the skip and the failure land in one total"
assert_eq "1" "$(rc_of "$LINKS/tests/test_skills.sh")" "...and the suite fails"

# The other two link checks are Python embedded in their suites. Extract and run the
# suite's own code against a fixture rather than restating the rule here, where a copy
# could drift from what the suite actually does.
extract_py() {
  python3 - "$1" "$2" "$3" <<'PY'
import io, sys
src, needle, out = sys.argv[1:4]
lines = io.open(src, encoding="utf-8").read().split("\n")
try:
    start = next(i for i, l in enumerate(lines) if needle in l and l.rstrip().endswith("<<'PY'"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip() == "PY")
except StopIteration:
    print("no heredoc starting with: " + needle)
    raise SystemExit(0)
io.open(out, "w", encoding="utf-8").write("\n".join(lines[start + 1:end]) + "\n")
print("ok")
PY
}

LOCAL_PY="$TEMP_DIR/local_skills_links.py"
assert_eq "ok" "$(extract_py "$SCRIPT_DIR/test_local_skills.sh" 'python3 - "$REPO_ROOT"' "$LOCAL_PY")" \
  "test_local_skills.sh's link check can be run against a fixture tree"
FIXL="$TEMP_DIR/local-fixture"
mkdir -p "$FIXL/.claude/skills/demo" "$FIXL/.claude/skills/ext/emptypack" "$FIXL/.claude/skills/ext/fullpack"
: > "$FIXL/.claude/skills/ext/fullpack/placeholder.md"
printf '# hub\n\n- [demo](demo/SKILL.md)\n' > "$FIXL/.claude/skills/SKILL.md"
printf -- '---\nname: demo\ndescription: a fixture skill\n---\n\n- [not checked out](../ext/emptypack/x.md)\n- [renamed upstream](../ext/fullpack/x.md)\n' \
  > "$FIXL/.claude/skills/demo/SKILL.md"
LOCAL_OUT="$(python3 "$LOCAL_PY" "$FIXL" | tr '\t' ' ')"
assert_contains "$LOCAL_OUT" "SKIP demo: 1 links into ext/ packs that are not checked out" \
  "test_local_skills.sh skips a skill link into a pack that is not checked out"
assert_contains "$LOCAL_OUT" "FAIL demo: 1 relative links resolve (broken: demo/SKILL.md -> ../ext/fullpack/x.md)" \
  "test_local_skills.sh FAILS a skill link into a pack that is checked out"

EXT_PY="$TEMP_DIR/skill_extensions_links.py"
assert_eq "ok" "$(extract_py "$SCRIPT_DIR/test_skill_extensions.sh" 'python3 - "$P1"' "$EXT_PY")" \
  "test_skill_extensions.sh's ext/ link check can be run against a fixture project"
FIXE="$TEMP_DIR/installed-fixture"
mkdir -p "$FIXE/.claude/agents" "$FIXE/.claude/skills/ext/emptypack" "$FIXE/.claude/skills/ext/fullpack"
: > "$FIXE/.claude/skills/ext/fullpack/placeholder.md"
printf '# project\n\nSee [renamed upstream](.claude/skills/ext/fullpack/x.md).\n' > "$FIXE/CLAUDE.md"
printf '# agent\n\nSee [not checked out](../skills/ext/emptypack/x.md).\n' > "$FIXE/.claude/agents/a.md"
DEAD_OUT="$(python3 "$EXT_PY" "$FIXE")"
assert_contains "$DEAD_OUT" "checked=1 not-checked-out=1" \
  "test_skill_extensions.sh counts a link into a pack that is not checked out separately"
assert_contains "$DEAD_OUT" "CLAUDE.md:3 -> .claude/skills/ext/fullpack/x.md" \
  "...and reports a link into a pack that is checked out as dead"

# --- Every skip in the suite tree is gated on a present-and-empty pack --------------
echo "[every skip is gated]"
GATES='in_uninitialized_submodule|ext_pack_empty|ext_packs_uninitialized|not_checked_out'
# Naming one of those helpers is not gating on one, and a grep for the name anywhere in the
# file passed on a mention in a comment or inside a string. What has to be there is a line
# that BRANCHES on the test — `if`, `elif`, `&&` or `||` — so the skip decision really does
# come from a present-and-empty pack. Full-line comments come off first; what is left has
# to carry both the helper and the branch.
branches_on_gate() {
  local hits
  hits="$(grep -vE '^[[:space:]]*#' "$1" | grep -E "$GATES" \
    | grep -cE '(^[[:space:]]*(el)?if[^a-z_]|&&|[|][|])' || true)"
  [ "${hits:-0}" -gt 0 ]
}
# calls_skip <file> — the file calls skip() outside a comment.
calls_skip() {
  [ "$(grep -vE '^[[:space:]]*#' "$1" | grep -cF 'skip "' || true)" != 0 ]
}
for suite in $CONVERTED; do
  assert_cmd_success "branches_on_gate '$SCRIPT_DIR/$suite.sh'" \
    "$suite branches on a present-and-empty pack test to decide its skips"
done
# print_summary's note names the submodule remedy, so a skip for any other reason would
# print the wrong fix. Derived over the whole tree rather than listed, so a suite added
# later is held to it too. This suite is the one exception: its own skip calls sit inside
# fixture strings that child shells run, which is the behaviour under test, not a gate.
UNGATED=""
for suite in "$SCRIPT_DIR"/test_*.sh; do
  case "$(basename "$suite")" in test_skip_accounting.sh) continue ;; esac
  calls_skip "$suite" || continue
  branches_on_gate "$suite" || UNGATED="$UNGATED $(basename "$suite" .sh)"
done
assert_eq "" "$UNGATED" \
  "Every suite that calls skip branches on a present-and-empty pack test, since the remedy it prints is the submodule one"

# --- test_skill_extensions.sh's pack-gated region routes every check through one wrapper
echo "[pack-gated region]"
# What keeps that region's skip count equal to its check count is that every check goes
# through pack_check. A check written straight into the region would run in a checked-out
# tree and vanish from the accounting in an uninitialised one, which is the bug #211 left
# and this says cannot come back. The guard is static, over the region's source text, so
# the region's own full-line comments come off first: prose about assert_*, PASS or FAIL is
# not a check. A trailing comment carrying one of those would still trip it; failing is the
# safe direction.
REGION="$TEMP_DIR/region.sh"
awk '/^# --- From here on every check needs the ext\/ packs checked out/ {f = 1} f' \
  "$SCRIPT_DIR/test_skill_extensions.sh" > "$REGION"
assert_cmd_success "[ -s '$REGION' ]" \
  "test_skill_extensions.sh still marks where its pack-gated region begins"
REGION_CODE="$TEMP_DIR/region-code.sh"
grep -vE '^[[:space:]]*#' "$REGION" > "$REGION_CODE" || true
# Everything below asserts an absence, which an empty region would satisfy for free.
assert_cmd_success "grep -q '^pack_check assert_' '$REGION_CODE'" \
  "...and still holds pack_check checks, so the guards below are not vacuous"
# A check written by hand is the same defect in another shape: it counts itself, or prints
# its own result line, instead of going through a helper. Matched on the counter prefix
# rather than the whole `TOTAL=$((TOTAL + 1))` line, so a spacing variant is caught too.
for literal in 'TOTAL=$((TOTAL' 'PASS=$((PASS' 'FAIL=$((FAIL' 'echo "  PASS' 'echo "  FAIL'; do
  assert_file_not_contains "$REGION_CODE" "$literal" \
    "...and counts no check there by hand ($literal)"
done
# '^assert_' alone missed an indented call — one inside an `if`, say — which is that same
# defect again. Every assert_* in the region has to be the command word of a pack_check.
assert_eq "" \
  "$(grep -nE 'assert_[a-z_]+' "$REGION_CODE" | grep -vE '^[0-9]+:[[:space:]]*pack_check assert_' || true)" \
  "...so every assert_* in it goes through pack_check and is counted in either state"

print_summary
