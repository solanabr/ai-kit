#!/usr/bin/env bash
set -euo pipefail

# Shared test helpers for Solana AI Kit test suite

PASS=0
FAIL=0
TOTAL=0
SKIP=0

_KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# anthropic-skills is a core pack fetched from its own upstream, not vendored from a kit
# submodule, so every install.sh and update.sh run in these suites would otherwise reach
# github.com. Default its source to a path that does not exist: the fetch fails offline
# and deterministically, the install warns and carries on (asserted in
# tests/test_skill_extensions.sh), and no suite depends on the network for it. A test that
# needs the pack actually installed exports its own mirror over this, as
# tests/test_anthropic_skills.sh does.
export SOLANA_AI_KIT_PACK_MIRROR="${SOLANA_AI_KIT_PACK_MIRROR:-${TMPDIR:-/tmp}/sak-no-pack-mirror.$$}"

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

# --- Uninitialized ext/ packs: a setup state, not broken config -----------------------
#
# A fresh clone or a git worktree without `git submodule update --init` leaves every
# .claude/skills/ext/<pack>/ present but empty. Links into those packs then dangle,
# install.sh vendors empty folders, and skills.sh refuses to copy from them ("<id> is
# empty in <repo> (run: git submodule update --init there)"). That is setup, not a
# regression, and a suite that FAILs on it buries the failures that matter. validate.sh
# counts such checks as skipped; these helpers let the suites do the same.
#
# The discrimination that earns the skip: the pack directory is present and EMPTY. A pack
# that IS checked out with the linked file missing stays a failure — that is the case
# which catches a path an upstream pack renamed, and it is the point of the check.

# skip <message> — record a check as skipped: not passed, not failed, not in TOTAL.
skip() {
  echo "  SKIP: ${1:-skipped}"
  SKIP=$((SKIP + 1))
}

# ext_pack_empty <dir> — the pack directory exists and has nothing in it.
ext_pack_empty() {
  [ -d "$1" ] && [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

# in_uninitialized_submodule <path> — <path> points into a pack that is present but empty.
# Same contract as validate.sh's function of this name, but it matches the
# skills/ext/<pack> segment anywhere in the path, so it also covers the absolute paths
# and the .agents/ installs these suites build in temp dirs.
in_uninitialized_submodule() {
  local path="$1" sub
  # Links from agents/, commands/ and skill folders climb out first
  # (../skills/ext/..., ../ext/...): drop each "dir/.." pair.
  path="$(printf '%s' "$path" | sed -E -e ':a' -e 's#(^|/)[^/.][^/]*/\.\./#\1#' -e 'ta')"
  case "$path" in
    */skills/ext/* | skills/ext/*)
      sub="$(printf '%s' "$path" | sed -E 's#(.*skills/ext/[^/]+).*#\1#')"
      ext_pack_empty "$sub"
      ;;
    *) return 1 ;;
  esac
}

# ext_packs_uninitialized — any pack in THIS repo is empty, so anything that copies or
# reads real pack content (install.sh vendoring, skills.sh add, resync.sh's broken-path
# report) can only report that setup state. Conservative on purpose: one empty pack is
# enough, because the blocks gated on this one copy the whole ext/ tree.
ext_packs_uninitialized() {
  local d
  for d in "$_KIT_ROOT/.claude/skills/ext"/*/; do
    ext_pack_empty "$d" && return 0
  done
  return 1
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

# print_summary — report the counts and say what a skip means.
#
# Returns 1 when anything failed, 2 when the suite checked nothing but skips (so
# run_all.sh does not count that as a pass), 0 otherwise. With submodules checked out
# SKIP is 0 and both the output and the return value are what they always were, which is
# why this is a no-op in CI.
print_summary() {
  echo ""
  echo "========================================="
  if [ "$SKIP" -gt 0 ]; then
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (of $((TOTAL + SKIP)) checks)"
  else
    echo "Results: $PASS passed, $FAIL failed (of $TOTAL checks)"
  fi
  echo "========================================="
  if [ "$SKIP" -gt 0 ]; then
    echo "Note: $SKIP checks skipped because submodules aren't initialized."
    echo "      Run 'git submodule update --init --recursive' (or ./install.sh) to check them."
    # run_all.sh adds these up so the remedy appears once at the end of a full run.
    if [ -n "${SAK_SKIP_REPORT:-}" ]; then
      printf '%s\t%s\n' "$(basename "${0:-suite}" .sh)" "$SKIP" >> "$SAK_SKIP_REPORT" 2>/dev/null || true
    fi
  fi
  if [ "$FAIL" -gt 0 ]; then
    return 1
  fi
  if [ "$PASS" -eq 0 ] && [ "$SKIP" -gt 0 ]; then
    return 2
  fi
  return 0
}
