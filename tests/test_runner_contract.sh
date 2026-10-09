#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_runner_contract] run_all.sh treats a suite that never reports as a failure"
echo ""

# tests/test_skill_extensions.sh once exited under set -e before print_summary. It printed
# no "Results:" line at all, and the run read as silence: Ubuntu stayed green while macOS
# was red for two sessions (#216). run_all.sh now fails a suite that does not report.
# This exercises that rule on a throwaway tests/ directory rather than on the real one,
# so it stays fast and cannot recurse.

FAKE="${TMPDIR:-/tmp}/sak-runner-contract.$$"
mkdir -p "$FAKE/tests"
trap 'rm -rf "$FAKE"' EXIT

cp "$SCRIPT_DIR/run_all.sh" "$FAKE/tests/run_all.sh"

summary() { printf '#!/usr/bin/env bash\necho "checking"\necho "Results: 1 passed, 0 failed (of 1 checks)"\n' > "$1"; }
# run_all.sh refuses to run at all without the suites named in its own `required` list,
# so the fixture stubs exactly those -- read out of run_all.sh rather than mirrored here,
# because a mirrored list silently breaks every assertion below the moment a suite joins
# the real one. (It did: the fetch-and-execute guard became required and this fixture,
# written in parallel, still named two.) Same derivation as test_skip_accounting.sh.
REQUIRED="$(sed -n 's/^for required in \(.*\); do$/\1/p' "$SCRIPT_DIR/run_all.sh")"
NREQ=0
for r in $REQUIRED; do
  summary "$FAKE/tests/$r.sh"
  NREQ=$((NREQ + 1))
done
assert_cmd_success "[ $NREQ -ge 2 ]" "run_all.sh's required-suite list was found and is non-trivial"
summary "$FAKE/tests/test_aa_reports.sh"

# The fixture holds the required stubs plus test_aa_reports (all reporting) and the two
# offenders below, so the counts follow from NREQ rather than from a literal.
EXP_PASS=$((NREQ + 1))
EXP_TOTAL=$((NREQ + 3))

# Dies under set -e the way the real failure did: a command fails, the shell exits, and
# print_summary is never reached.
cat > "$FAKE/tests/test_bb_dies_early.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "  PASS: something"
false
echo "Results: 1 passed, 0 failed (of 1 checks)"
EOF

# The worse shape: exits 0 and still never reports, which no exit code would reveal.
cat > "$FAKE/tests/test_cc_silent_pass.sh" <<'EOF'
#!/usr/bin/env bash
echo "  PASS: something"
exit 0
EOF

RC=0
OUT="$(bash "$FAKE/tests/run_all.sh" 2>&1)" || RC=$?

assert_eq "1" "$RC" "run_all.sh exits 1 when a suite never printed its summary"
assert_contains "$OUT" "NO SUMMARY: test_bb_dies_early" "a suite that dies before print_summary is named"
assert_contains "$OUT" "NO SUMMARY: test_cc_silent_pass" "a suite that exits 0 without reporting is named"
FAILED_BLOCK="${OUT##*Failed suites:}"
assert_contains "$FAILED_BLOCK" "test_bb_dies_early" "the dying suite is listed under Failed suites"
assert_contains "$FAILED_BLOCK" "test_cc_silent_pass" "the silent suite is listed under Failed suites"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c 'NO SUMMARY: test_aa_reports' || true)" \
  "a suite that does report is not flagged"
assert_contains "$OUT" "$EXP_PASS passed, 2 failed (of $EXP_TOTAL)" "the runner counts both offenders as failures"

# Control: with only reporting suites the same runner is green, so the rule above is not
# simply failing everything.
rm "$FAKE/tests/test_bb_dies_early.sh" "$FAKE/tests/test_cc_silent_pass.sh"
CLEAN_RC=0
CLEAN="$(bash "$FAKE/tests/run_all.sh" 2>&1)" || CLEAN_RC=$?
assert_eq "0" "$CLEAN_RC" "run_all.sh is green when every suite reports"
assert_contains "$CLEAN" "All test suites passed!" "the clean run reports success"

print_summary
