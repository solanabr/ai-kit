#!/usr/bin/env bash
set -euo pipefail

# Test runner for Solana AI Kit
# Runs all test_*.sh files and reports results.
#
#   bash tests/run_all.sh          one suite per CPU at a time
#   bash tests/run_all.sh -j 4     at most four at a time (-j4 and --jobs 4 work too)
#   bash tests/run_all.sh -j 1     one after another, output streamed as it runs
#   SAK_TEST_JOBS=N                the same as -j N; -j wins when both are given
#
# In parallel each suite writes its own log, and the logs are printed whole, in suite
# order, as each one finishes, so the output reads as a serial run does. Must run on
# macOS's bash 3.2, which has no `wait -n`: the scheduler polls instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cpu_count() {
  local n
  for n in "$(nproc 2>/dev/null)" "$(getconf _NPROCESSORS_ONLN 2>/dev/null)" "$(sysctl -n hw.ncpu 2>/dev/null)"; do
    case "$n" in '' | *[!0-9]* | 0) ;; *) echo "$n"; return ;; esac
  done
  echo 1
}

# A count that was given but is empty (`-j ""`, `SAK_TEST_JOBS=`) is an error, not a
# request for the default: a caller expanding an unset variable must not get full width.
# Only an unset SAK_TEST_JOBS and no -j mean "one per CPU".
JOBS=""
JOBS_GIVEN=no
if [ -n "${SAK_TEST_JOBS+set}" ]; then JOBS="$SAK_TEST_JOBS"; JOBS_GIVEN=yes; fi
while [ $# -gt 0 ]; do
  case "$1" in
    -j | --jobs)
      if [ $# -lt 2 ]; then echo "run_all.sh: $1 needs a job count" >&2; exit 64; fi
      JOBS="$2"; JOBS_GIVEN=yes; shift 2 ;;
    -j*) JOBS="${1#-j}"; JOBS_GIVEN=yes; shift ;;
    --jobs=*) JOBS="${1#--jobs=}"; JOBS_GIVEN=yes; shift ;;
    *) echo "usage: run_all.sh [-j N]   (unknown argument: $1)" >&2; exit 64 ;;
  esac
done
[ "$JOBS_GIVEN" = yes ] || JOBS="$(cpu_count)"
case "$JOBS" in
  '' | *[!0-9]* | 0) echo "run_all.sh: -j / SAK_TEST_JOBS needs a positive integer, got '$JOBS'" >&2; exit 64 ;;
esac

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SKIPPED_SUITES=0
FAILED_NAMES=""
SKIPPED_NAMES=""

# Everything the run writes lives in one private directory: each suite's log, exit
# status and skip count, so suites running side by side never share a file.
RUN_DIR="$(mktemp -d 2>/dev/null || true)"
if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  RUN_DIR="${TMPDIR:-/tmp}/sak-run-all.$$"
  mkdir -p "$RUN_DIR" 2>/dev/null || RUN_DIR=""
fi
cleanup() {
  local p
  # An interrupted parallel run leaves suites behind: stop them and what they started.
  # Only two levels deep: a suite's own children (a hung git, say) can outlive it.
  for p in $(jobs -p 2>/dev/null || true); do
    pkill -TERM -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  [ -z "$RUN_DIR" ] || rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Suites that find an ext/ pack present but empty skip those checks instead of failing
# (see tests/helpers.sh). Collect the counts so the remedy appears once at the end of a
# full run rather than only inside each suite. Each suite reports into its own file
# (print_summary appends to SAK_SKIP_REPORT), merged in suite order at the end so the
# list reads the same however the suites were scheduled. Best effort: no writable temp
# dir just means no aggregate line.
SAK_SKIP_REPORT=""
[ -z "$RUN_DIR" ] || SAK_SKIP_REPORT="$RUN_DIR/skips"
export SAK_SKIP_REPORT

echo "========================================"
echo " Solana AI Kit - Test Suite"
echo "========================================"
echo ""

# The glob below picks up every test_*.sh. These nine carry the firewall's security
# properties, so a rename or a deletion has to fail loudly rather than silently
# shrinking the suite. test_doc_gates is here for a sharper reason than the others: it is
# the only check that a gate the documentation promises has something enforcing it, so
# its absence is the one thing nothing else would report. test_git_guard holds the one
# gate whose whole value is in what it does NOT fire on — delete it and a false positive
# on `git config user.email` reaches users silently. test_gh_api_guard is the same shape
# for gh api: delete it and a deny on an ordinary issue comment would go unnoticed.
# test_secrets_guard holds the shell -c block, the only layer for an agent's bash -c at Off
# and Relaxed and in a plugin install and a second one elsewhere, and its one exact
# memsearch exception: without it, a hook change that let any other shell -c through would
# go unnoticed where no rule backs it. It also holds the Read and Grep refusal on gh's host
# file, the only thing between those tools and gh's token at Off and Relaxed. test_onchain_guard
# holds the exact local-host match that lets Relaxed skip the localnet prompt: loosen it
# and a remote host that merely names a local one would go unprompted.
# test_report_page holds report-page.sh's input gate: a firewall rule that lets the script
# run without a prompt, where a tier carries one, rests on it, and loosened, the renderer
# would copy any file it is pointed at into a page.
for required in test_firewall test_egress_guard test_fetch_exec_guard test_doc_gates test_git_guard test_gh_api_guard test_secrets_guard test_onchain_guard test_report_page; do
  if [ ! -f "$SCRIPT_DIR/$required.sh" ]; then
    echo "MISSING SUITE: tests/$required.sh (the firewall tiers ship with it)"
    exit 1
  fi
done
# The decision record's three protections, each with one suite: a field that looks like a
# credential never reaches the record (test_decisions), only the user's main session
# writes it (test_decisions_guard), and the hooks that read it follow no link planted in
# it (test_decision_hooks). Those hooks run outside the sandbox while an agent inside it
# can write .git/, so a link they followed would turn that into a write the sandbox
# forbids, or let a tracked file speak as the user. Whatever the record holds reaches
# every agent.
for required in test_decisions test_decisions_guard test_decision_hooks; do
  if [ ! -f "$SCRIPT_DIR/$required.sh" ]; then
    echo "MISSING SUITE: tests/$required.sh (the decision record's protections ship with it)"
    exit 1
  fi
done

# install.sh's safe-ai-skill step calls the real `claude` CLI; keep every suite off it
# (tests/helpers.sh sets the same for a suite run on its own).
export SOLANA_AI_KIT_SAFE_AI_SKILL="${SOLANA_AI_KIT_SAFE_AI_SKILL:-0}"

SUITES=""
for test_file in "$SCRIPT_DIR"/test_*.sh; do
  [ -f "$test_file" ] || continue
  SUITES="$SUITES $(basename "$test_file" .sh)"
done

# record <name> <rc> <log> — classify one finished suite. The log is what it printed.
record() {
  local test_name="$1" rc="$2" log="$3"
  TOTAL_SUITES=$((TOTAL_SUITES + 1))
  # No summary means the suite stopped somewhere it did not choose to. Treat that as a
  # failure whatever it exited with, so it can never pass for having said nothing (#216).
  if [ -n "$log" ] && ! grep -q '^Results:' "$log"; then
    echo "NO SUMMARY: $test_name exited $rc without reaching print_summary"
    rc=1
  fi
  # 2 means the suite checked nothing but skips: not a pass, not a failure either.
  if [ "$rc" -eq 0 ]; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
  elif [ "$rc" -eq 2 ]; then
    SKIPPED_SUITES=$((SKIPPED_SUITES + 1))
    SKIPPED_NAMES="$SKIPPED_NAMES  - $test_name\n"
  else
    FAILED_SUITES=$((FAILED_SUITES + 1))
    FAILED_NAMES="$FAILED_NAMES  - $test_name\n"
  fi
  # This suite's skips join the run-wide report in suite order.
  if [ -n "$SAK_SKIP_REPORT" ] && [ -s "$SAK_SKIP_REPORT.$test_name" ]; then
    cat "$SAK_SKIP_REPORT.$test_name" >> "$SAK_SKIP_REPORT"
  fi
  echo ""
}

# skip_report_for <name> — the file that suite's print_summary appends its skips to.
skip_report_for() { [ -z "$SAK_SKIP_REPORT" ] || printf '%s' "$SAK_SKIP_REPORT.$1"; }

if [ "$JOBS" -eq 1 ]; then
  # Serial: one suite at a time, its output streamed as it runs.
  for test_name in $SUITES; do
    echo "--- $test_name ---"
    RC=0
    LOG=""
    [ -z "$RUN_DIR" ] || LOG="$RUN_DIR/$test_name.log"
    SAK_SKIP_REPORT="$(skip_report_for "$test_name")" \
      bash "$SCRIPT_DIR/$test_name.sh" 2>&1 | tee "${LOG:-/dev/null}" || RC=$?
    record "$test_name" "$RC" "$LOG"
  done
else
  if [ -z "$RUN_DIR" ]; then
    echo "run_all.sh: no writable temp dir for the suite logs; run with -j 1" >&2
    exit 1
  fi
  # The slowest suites start first, so none of them is left to begin near the end and
  # set the critical path alone. Slowest first, as measured serially on CI's macOS runner
  # and locally; a name not in the tree is ignored, and every other suite follows in glob
  # order. Output order is unaffected: it is always suite order.
  SLOW="test_install_agents_only test_hooks test_skill_extensions test_install test_update_firewall test_env_schema test_safe_ai_skill_policy test_update test_update_migrations test_validate test_safe_ai_skill_install test_update_settings_migration"
  ORDER=""
  for s in $SLOW; do
    case " $SUITES " in *" $s "*) ORDER="$ORDER $s" ;; esac
  done
  for s in $SUITES; do
    case " $SLOW " in *" $s "*) ;; *) ORDER="$ORDER $s" ;; esac
  done
  set -- $ORDER
  echo "(running $# suites, $JOBS at a time)"
  echo ""

  # launch <name> — run one suite in the background; its .rc file appears when it is done.
  launch() {
    (
      rc=0
      SAK_SKIP_REPORT="$(skip_report_for "$1")" \
        bash "$SCRIPT_DIR/$1.sh" > "$RUN_DIR/$1.log" 2>&1 < /dev/null || rc=$?
      echo "$rc" > "$RUN_DIR/$1.rc.tmp" && mv "$RUN_DIR/$1.rc.tmp" "$RUN_DIR/$1.rc"
    ) &
  }

  LAUNCHED_LIST=""
  PRINT_QUEUE="$SUITES"
  while [ -n "$PRINT_QUEUE" ]; do
    # Count what has finished since the last pass, then fill the free slots.
    RUNNING=0
    for s in $LAUNCHED_LIST; do [ -f "$RUN_DIR/$s.rc" ] || RUNNING=$((RUNNING + 1)); done
    while [ $# -gt 0 ] && [ "$RUNNING" -lt "$JOBS" ]; do
      launch "$1"
      LAUNCHED_LIST="$LAUNCHED_LIST $1"
      RUNNING=$((RUNNING + 1))
      shift
    done
    # Print every suite at the head of the queue that has finished, in suite order.
    PRINTED=no
    while [ -n "$PRINT_QUEUE" ]; do
      rest="${PRINT_QUEUE# }"; head_name="${rest%% *}"
      [ -f "$RUN_DIR/$head_name.rc" ] || break
      echo "--- $head_name ---"
      cat "$RUN_DIR/$head_name.log"
      record "$head_name" "$(cat "$RUN_DIR/$head_name.rc")" "$RUN_DIR/$head_name.log"
      case "$rest" in *" "*) PRINT_QUEUE="${rest#* }" ;; *) PRINT_QUEUE="" ;; esac
      PRINTED=yes
    done
    [ -z "$PRINT_QUEUE" ] || [ "$PRINTED" = yes ] || sleep 0.2
  done
  wait
fi

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
