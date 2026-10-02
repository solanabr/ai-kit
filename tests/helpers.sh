#!/usr/bin/env bash
set -euo pipefail

# Shared test helpers for Solana AI Kit test suite

PASS=0
FAIL=0
TOTAL=0

# new_tmp — a writable temp dir, or exit 1 having said why.
#
# `mktemp -d` is itself denied under the Bash sandbox on some machines ("mkdtemp failed
# ... Operation not permitted"), which is the shipped bug this release fixes. A bare
# `mktemp -d` under `set -e` kills the suite, and an unguarded empty result truncated a
# tracked file once, so every caller goes through here and every result is checked.
_TMP_SEQ=0
new_tmp() {
  local d
  d="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$d" ] || [ ! -d "$d" ]; then
    _TMP_SEQ=$((_TMP_SEQ + 1))
    d="${TMPDIR:-/tmp}/sak-test.$$.$_TMP_SEQ"
    mkdir -p "$d" 2>/dev/null || true
  fi
  if [ -z "$d" ] || [ ! -d "$d" ]; then
    echo "  FAIL: no writable temp dir (tried mktemp -d and \$TMPDIR)" >&2
    return 1
  fi
  printf '%s' "$d"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-assert_eq}"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local path="$1"
  local message="${2:-File exists: $path}"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_exists() {
  local path="$1"
  local message="${2:-Directory exists: $path}"
  TOTAL=$((TOTAL + 1))
  if [ -d "$path" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (directory not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_valid() {
  local path="$1"
  local message="${2:-Valid JSON: $path}"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ] && python3 -c "import json; json.load(open('$path'))" 2>/dev/null; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (invalid JSON or file missing: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local string="$1"
  local substring="$2"
  local message="${3:-String contains '$substring'}"
  TOTAL=$((TOTAL + 1))
  if echo "$string" | grep -qF "$substring"; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (substring '$substring' not found)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd_success() {
  local cmd="$1"
  local message="${2:-Command succeeds: $cmd}"
  TOTAL=$((TOTAL + 1))
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (command failed)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local path="$1"
  local message="${2:-File does not exist: $path}"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$path" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (file exists: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_not_exists() {
  local path="$1"
  local message="${2:-Directory does not exist: $path}"
  TOTAL=$((TOTAL + 1))
  if [ ! -d "$path" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (directory exists: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local file="$1"
  local substring="$2"
  local message="${3:-File $file contains '$substring'}"
  TOTAL=$((TOTAL + 1))
  if [ -f "$file" ] && grep -qF "$substring" "$file"; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (substring '$substring' not found in $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
  local file="$1"
  local substring="$2"
  local message="${3:-File $file does not contain '$substring'}"
  TOTAL=$((TOTAL + 1))
  if [ -f "$file" ] && ! grep -qF "$substring" "$file"; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (substring '$substring' found in $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_count() {
  local dir="$1"
  local pattern="$2"
  local expected="$3"
  local message="${4:-Count of $pattern in $dir is $expected}"
  TOTAL=$((TOTAL + 1))
  local actual
  actual=$(find "$dir" -name "$pattern" | wc -l | tr -d ' ')
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

print_summary() {
  echo ""
  echo "========================================="
  echo "Results: $PASS passed, $FAIL failed (of $TOTAL checks)"
  echo "========================================="
  if [ "$FAIL" -gt 0 ]; then
    return 1
  fi
  return 0
}
