#!/usr/bin/env bash
set -euo pipefail

# Test runner for Solana AI Kit
# Runs all test_*.sh files and reports results.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_NAMES=""

echo "========================================"
echo " Solana AI Kit - Test Suite"
echo "========================================"
echo ""

# The glob below picks up every test_*.sh. These two carry the firewall's security
# properties, so a rename or a deletion has to fail loudly rather than silently
# shrinking the suite.
for required in test_firewall test_egress_guard; do
  if [ ! -f "$SCRIPT_DIR/$required.sh" ]; then
    echo "MISSING SUITE: tests/$required.sh (the firewall tiers ship with it)"
    exit 1
  fi
done

for test_file in "$SCRIPT_DIR"/test_*.sh; do
  test_name="$(basename "$test_file" .sh)"
  TOTAL_SUITES=$((TOTAL_SUITES + 1))

  echo "--- $test_name ---"
  if bash "$test_file"; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
  else
    FAILED_SUITES=$((FAILED_SUITES + 1))
    FAILED_NAMES="$FAILED_NAMES  - $test_name\n"
  fi
  echo ""
done

echo "========================================"
echo " Final Summary"
echo "========================================"
echo "Suites: $PASSED_SUITES passed, $FAILED_SUITES failed (of $TOTAL_SUITES)"

if [ "$FAILED_SUITES" -gt 0 ]; then
  echo ""
  echo "Failed suites:"
  printf "$FAILED_NAMES"
  exit 1
else
  echo "All test suites passed!"
fi
