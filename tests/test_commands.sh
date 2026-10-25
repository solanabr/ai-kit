#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

CMDS_DIR="$REPO_ROOT/.claude/commands"

echo "[test_commands] Checking command frontmatter..."

COUNT=0
for f in "$CMDS_DIR"/*.md; do
  name="$(basename "$f")"
  COUNT=$((COUNT + 1))

  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(sed -n '/^---$/,/^---$/p' "$f" | head -20 || true)"

    TOTAL=$((TOTAL + 1))
    if grep -q "^description:" <<<"$frontmatter"; then
      echo "  PASS: $name has description:"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name missing description:"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  FAIL: $name has no frontmatter"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
  fi
done

echo ""
assert_eq "54" "$COUNT" "Total command count is 54"
assert_file_exists "$CMDS_DIR/firewall.md" "/firewall exists (shows and switches the security tier)"
# /firewall drives the generator; it must not hand-edit the block it regenerates.
assert_file_contains "$CMDS_DIR/firewall.md" "firewall.sh" "firewall.md calls bin/firewall.sh rather than editing settings.json by hand"
# /ship merges PRs, and the firewall lets `gh pr merge` through at Relaxed, so whether it runs
# is the user's typing alone: Claude must not be able to invoke it from its description. Read
# from the frontmatter, since the same words in the body would leave it model-invocable.
SHIP_FRONT="$(awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$CMDS_DIR/ship.md")"
assert_eq "disable-model-invocation: true" "$(printf '%s\n' "$SHIP_FRONT" | grep -x 'disable-model-invocation:[[:space:]]*true' || true)" \
  "/ship is user-only (disable-model-invocation: true in its frontmatter)"
# It settles the merge method before the first PR, so the train never stops partway for it,
# and two merge-method principles that disagree are reported, never resolved by picking one.
assert_file_contains "$CMDS_DIR/ship.md" "**Settle the merge method** before the first PR" "/ship settles the merge method before the first PR"
assert_file_contains "$CMDS_DIR/ship.md" "that disagree are a conflict" "/ship reports two disagreeing merge-method principles as a conflict"

echo ""
echo "[test_commands] Checking /explore, the short aliases and composition..."
# Project commands have no alias field, so each short name is a file that has the model read
# its full command and follow it. It must name a target that exists (rep's, report.md, ships
# in its own change) and stay user-only like /explore, which keeps both out of every
# session's listing and leaves /adversarial and /parallel to start only from the user.
# Frontmatter is read on its own, as for /ship above.
front() { awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1" 2>/dev/null || true; }
for pair in adv:adversarial par:parallel rep:report res:research exp:explore; do
  short="${pair%%:*}"; full="${pair#*:}"
  f="$CMDS_DIR/$short.md"
  assert_file_exists "$f" "/$short exists"
  assert_file_contains "$f" "\`.claude/commands/$full.md\`" "/$short forwards to .claude/commands/$full.md"
  assert_file_exists "$CMDS_DIR/$full.md" "/$short's target /$full exists"
  assert_eq "description: \"Short for /$full: " "$(front "$f" | grep -o "^description: \"Short for /$full: " || true)" \
    "/$short's description starts 'Short for /$full:'"
  # Claude Code replaces every \$ARGUMENTS in a command body with the user's text, so a
  # second one, meant to name the target's placeholder, would arrive as that text instead.
  assert_eq "1" "$(grep -o '\$ARGUMENTS' "$f" 2>/dev/null | wc -l | tr -d ' ')" "/$short uses \$ARGUMENTS exactly once"
done
for name in adv par rep res exp explore; do
  assert_eq "disable-model-invocation: true" "$(front "$CMDS_DIR/$name.md" | grep -x 'disable-model-invocation:[[:space:]]*true' || true)" \
    "/$name is user-only (disable-model-invocation: true in its frontmatter)"
  assert_eq "" "$(front "$CMDS_DIR/$name.md" | grep '^model:' || true)" "/$name sets no model: line"
done
EXPLORE="$CMDS_DIR/explore.md"
for label in adversarial parallel serial user; do
  assert_cmd_success "grep -qx -e '- \*\*$label\*\*: .*' '$EXPLORE'" "explore.md's triage rubric defines the $label label"
done
assert_file_not_contains "$EXPLORE" "**single**" "explore.md's rubric says serial, not the calibration run's single"
assert_file_contains "$EXPLORE" "## Triage rubric" "explore.md keeps the rubric under the heading its Triage section names"
assert_file_contains "$EXPLORE" 'model: "sonnet"' "explore.md runs the triage on Sonnet"
for f in research.md decide.md plan-work.md review-round.md; do
  assert_file_contains "$CMDS_DIR/$f" "(explore.md#triage)" "$f triages its items with /explore's rubric before the adversarial pass"
done
# /decide records a pasted answers block as the user's own words, so only a block from the
# user's own message counts, and each line has to match the page it came from.
assert_file_contains "$CMDS_DIR/decide.md" "pasted in the user's own message" "decide.md takes an answers block only from the user's own message"
assert_file_contains "$CMDS_DIR/decide.md" "Check each line against that page's JSON" "decide.md checks each pasted line against the page's saved JSON"
assert_file_contains "$CMDS_DIR/decide.md" "Every run writes a new local HTML page" "decide.md writes a page on every run"
assert_file_not_contains "$CMDS_DIR/decide.md" "5. **Triage.**" "decide.md's clear-or-cloudy step does not share the Sonnet classifier's name"
assert_eq "1" "$(grep -c '^[0-9][0-9]*\. \*\*Triage' "$CMDS_DIR/decide.md")" "decide.md has one step named Triage, the Sonnet classifier"
assert_file_contains "$CMDS_DIR/decide.md" "**Clear or cloudy**" "decide.md names its whose-call sorting Clear or cloudy"
for f in decide.md report.md; do
  assert_file_contains "$CMDS_DIR/$f" "rm -f <its path>" "$f deletes the JSON it wrote once the page is rendered"
done
# report.md once refused the user's own example, /rep(/adv(task 1) and /adv(task 2)), as calls
# that were the user's to type. It defers to Composition, and runs an inner call only once.
assert_file_contains "$CMDS_DIR/report.md" "(parallel.md#composition)" "report.md defers inline calls to /parallel's Composition rules"
assert_file_not_contains "$CMDS_DIR/report.md" "user's to type" "report.md does not refuse a composed call as the user's to type"
assert_file_contains "$CMDS_DIR/report.md" "run it no second time" "report.md reports what an inner call returned instead of running it again"
assert_file_contains "$CMDS_DIR/adversarial.md" 'a bare `proceed`' "/adversarial takes an empty task or a bare proceed as the unfinished work"
assert_file_contains "$CMDS_DIR/adversarial.md" "6. **Whose call:**" "adversarial.md names its whose-call step so, leaving 'triage' to the classifier"
assert_file_contains "$CMDS_DIR/adversarial.md" "it runs no pairs of its own" "/adversarial stacked on a step that triages forces that step's pass, not a second run"
assert_file_contains "$CMDS_DIR/parallel.md" "is three items" "Composition splits /par(a and b and c) into three items"
assert_file_contains "$CMDS_DIR/parallel.md" "no second pass" "/parallel as an outer call runs its inner calls as its lanes, with no second pass"
assert_file_contains "$CMDS_DIR/parallel.md" "unless the brief says to run it" "Composition reads a call quoted in a subagent's brief as text"
# The composition and plain-request lines: CLAUDE-solana.md ships them, and the kit's own
# CLAUDE.md carries them too, since a session in this repository loads that file instead.
for f in CLAUDE-solana.md CLAUDE.md; do
  for needle in '`.claude/commands/<name>.md`' 'Composition section' 'unless the brief says to run it' \
    'Bring me the points I need to decide' 'explain better what I need to unblock you on' 'report on what you found'; do
    assert_file_contains "$REPO_ROOT/$f" "$needle" "$f carries: $needle"
  done
done
# The decision record never outranks the user: their newest explicit instruction wins, and
# the session supersedes the entry it overrides.
assert_file_contains "$REPO_ROOT/CLAUDE-solana.md" "newest explicit instruction beats anything recorded earlier, the decision record included" \
  "CLAUDE-solana.md: the user's newest explicit instruction beats the decision record"
assert_file_contains "$CMDS_DIR/parallel.md" "## Composition" "parallel.md carries the composition rules"
assert_file_contains "$CMDS_DIR/adversarial.md" "(parallel.md#composition)" "adversarial.md points at /parallel's composition rules"
for f in parallel.md adversarial.md; do
  assert_file_not_contains "$CMDS_DIR/$f" "that command did not load" "$f runs a call that did not load instead of skipping it"
done

echo ""
echo "[test_commands] Checking setup-mcp.md covers every .env.example key..."

ENV_EXAMPLE="$REPO_ROOT/.env.example"
SETUP_MCP="$CMDS_DIR/setup-mcp.md"

if [ -f "$ENV_EXAMPLE" ] && [ -f "$SETUP_MCP" ]; then
  # Counted, then asserted non-zero. Both files existing is not the same as the producer
  # finding keys in one of them: the grep is anchored on `^KEY=`, so .env.example moving to
  # the `export KEY=` form (or any other style change) empties the loop and every key is
  # reported as covered without one being read. Demonstrated by rewriting .env.example to
  # `export KEY=` with HELIUS_API_KEY stripped out of setup-mcp.md: 62 checks became 52
  # and the suite stayed green.
  ENV_KEYS=0
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    ENV_KEYS=$((ENV_KEYS + 1))
    assert_file_contains "$SETUP_MCP" "$key" "setup-mcp.md mentions .env.example key: $key"
  done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$ENV_EXAMPLE" | sed 's/=$//')
  assert_cmd_success "[ $ENV_KEYS -gt 0 ]" ".env.example has KEY= lines for the coverage check to read ($ENV_KEYS found)"
else
  assert_eq "0" "1" ".env.example and setup-mcp.md both exist for drift check"
fi

echo ""
echo "[test_commands] Checking /dream and /diff-review write to the Project Learnings subsections in CLAUDE-solana.md..."
for sub in "### Recurring Issues" "### Fix Patterns" "### Config Conventions"; do
  assert_file_contains "$REPO_ROOT/CLAUDE-solana.md" "$sub" "CLAUDE-solana.md has '$sub'"
  assert_file_contains "$CMDS_DIR/dream.md" "\`$sub\`" "dream.md names '$sub'"
done
assert_file_contains "$CMDS_DIR/diff-review.md" '`### Recurring Issues`' "diff-review.md files repeated mistakes under ### Recurring Issues"
assert_file_contains "$CMDS_DIR/diff-review.md" '`### Config Conventions`' "diff-review.md files confirmed conventions under ### Config Conventions"
assert_file_contains "$CMDS_DIR/dream.md" "if it is missing (never a differently named one)" "dream.md creates a missing subsection instead of inventing one"

echo ""
echo "[test_commands] Checking --agents install-mode support..."
assert_file_contains "$CMDS_DIR/resync.md" ".agents/bin" "resync.md supports --agents installs (.agents/bin)"
assert_file_contains "$CMDS_DIR/update.md" ".agents/bin" "update.md supports --agents installs (.agents/bin)"

echo ""
echo "[test_commands] Checking Anchor error codes are decoded by discriminant, not declaration order..."
for f in test-rust.md test-ts.md test-and-fix.md; do
  assert_file_contains "$CMDS_DIR/$f" '`offset` (default 6000) + discriminant' "$f decodes #[error_code] ids as offset + discriminant"
  assert_file_not_contains "$CMDS_DIR/$f" "declaration order" "$f does not claim declaration order"
done

print_summary
