#!/usr/bin/env bash
set -euo pipefail

# Test runner for Solana AI Kit
# Runs all test_*.sh files and reports results.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SKIPPED_SUITES=0
FAILED_NAMES=""
SKIPPED_NAMES=""

# Suites that find an ext/ pack present but empty skip those checks instead of failing
# (see tests/helpers.sh). Collect the counts so the remedy appears once at the end of a
# full run rather than only inside each suite. Best effort: no writable temp dir just
# means no aggregate line.
SAK_SKIP_REPORT="${TMPDIR:-/tmp}/sak-run-all-skips.$$"
: > "$SAK_SKIP_REPORT" 2>/dev/null || SAK_SKIP_REPORT=""
export SAK_SKIP_REPORT

# Each suite's output is kept so the runner can check it reported at all. A suite that
# dies under set -e before print_summary prints no "Results:" line, and on one OS that
# read as silence rather than as a failure for two sessions (#216).
SUITE_LOG="${TMPDIR:-/tmp}/sak-run-all-suite.$$"
: > "$SUITE_LOG" 2>/dev/null || SUITE_LOG=/dev/null
trap 'rm -f "${SAK_SKIP_REPORT:-/dev/null}" "$SUITE_LOG" 2>/dev/null || true' EXIT

echo "========================================"
echo " Solana AI Kit - Test Suite"
echo "========================================"
echo ""

# The glob below picks up every test_*.sh. These three carry the firewall's security
# properties, so a rename or a deletion has to fail loudly rather than silently
# shrinking the suite.
for required in test_firewall test_egress_guard test_fetch_exec_guard; do
  if [ ! -f "$SCRIPT_DIR/$required.sh" ]; then
    echo "MISSING SUITE: tests/$required.sh (the firewall tiers ship with it)"
    exit 1
  fi
done

for test_file in "$SCRIPT_DIR"/test_*.sh; do
  test_name="$(basename "$test_file" .sh)"
  TOTAL_SUITES=$((TOTAL_SUITES + 1))

  echo "--- $test_name ---"
  RC=0
  bash "$test_file" 2>&1 | tee "$SUITE_LOG" || RC=$?
  # No summary means the suite stopped somewhere it did not choose to. Treat that as a
  # failure whatever it exited with, so it can never pass for having said nothing.
  if [ "$SUITE_LOG" != /dev/null ] && ! grep -q '^Results:' "$SUITE_LOG"; then
    echo "NO SUMMARY: $test_name exited $RC without reaching print_summary"
    RC=1
  fi
  # 2 means the suite checked nothing but skips: not a pass, not a failure either.
  if [ "$RC" -eq 0 ]; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
  elif [ "$RC" -eq 2 ]; then
    SKIPPED_SUITES=$((SKIPPED_SUITES + 1))
    SKIPPED_NAMES="$SKIPPED_NAMES  - $test_name\n"
  else
    FAILED_SUITES=$((FAILED_SUITES + 1))
    FAILED_NAMES="$FAILED_NAMES  - $test_name\n"
  fi
  echo ""
done

echo "========================================"
echo " Final Summary"
echo "========================================"
if [ "$SKIPPED_SUITES" -gt 0 ]; then
  echo "Suites: $PASSED_SUITES passed, $FAILED_SUITES failed, $SKIPPED_SUITES skipped (of $TOTAL_SUITES)"
else
  echo "Suites: $PASSED_SUITES passed, $FAILED_SUITES failed (of $TOTAL_SUITES)"
fi

if [ "$SKIPPED_SUITES" -gt 0 ]; then
  echo ""
  echo "Suites that checked nothing but skips:"
  printf "$SKIPPED_NAMES"
fi

# What the suites skipped, added up. Empty when submodules are checked out, as in CI.
if [ -n "${SAK_SKIP_REPORT:-}" ] && [ -s "$SAK_SKIP_REPORT" ]; then
  SKIPPED_CHECKS="$(awk -F'\t' '{n += $2} END {print n + 0}' "$SAK_SKIP_REPORT")"
  echo ""
  echo "Skipped $SKIPPED_CHECKS checks across $(wc -l < "$SAK_SKIP_REPORT" | tr -d ' ') suite(s) because"
  echo "submodules aren't initialized:"
  awk -F'\t' '{printf "  - %s (%s)\n", $1, $2}' "$SAK_SKIP_REPORT"
  echo "Run 'git submodule update --init --recursive' (or ./install.sh) to check them."
fi

if [ "$FAILED_SUITES" -gt 0 ]; then
  echo ""
  echo "Failed suites:"
  printf "$FAILED_NAMES"
  exit 1
elif [ "$SKIPPED_SUITES" -gt 0 ]; then
  echo "No suite failed, but $SKIPPED_SUITES checked nothing but skips."
else
  echo "All test suites passed!"
fi
