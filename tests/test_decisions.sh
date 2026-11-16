#!/usr/bin/env bash
set -euo pipefail

# The decision record (.claude/bin/decisions.sh): one private, live record per clone,
# under the git common directory, that the decision hooks inject into every agent.
#
# The helper writes the record of the repository it runs in, as git would. Every call
# here runs from inside a temp project (a copy of the helper committed in it, plus a
# linked worktree), and GIT_CEILING_DIRECTORIES stops git from walking up out of the
# temp directory, so the suite never touches the record of the checkout it runs from.
#
# Covered: the CLI contract the hooks and commands build on (add, supersede, in-force,
# hash, export, path), one record shared by every worktree, verbatim words through
# quotes and unicode, credential refusal that never echoes the value, the in-force
# size budget, and the protocol rules the helper enforces (a user's decision is
# superseded only by the user; a standing order names what it covers and when it ends).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

HELPER_SRC="$REPO_ROOT/.claude/bin/decisions.sh"
WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$WORK"' EXIT
export GIT_CEILING_DIRECTORIES="$WORK"

echo "[test_decisions] The decision record under the git common directory"
echo ""

# Identity from the environment, never from the machine's git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export DECISIONS_DATE=2026-10-22

# A project with the helper committed, and a linked worktree of it.
MAIN="$WORK/main"
WT="$WORK/wt"
mkdir -p "$MAIN/.claude/bin"
cp "$HELPER_SRC" "$MAIN/.claude/bin/decisions.sh"
(
  cd "$MAIN"
  git init -q -b main
  git add .claude
  git commit -q --no-gpg-sign -m fixture
  git worktree add -q "$WT" -b side
) > "$QUIET_LOG" 2>&1 || quiet_fail "fixture repo"
REC="$(cd "$(cd "$MAIN" && git rev-parse --path-format=absolute --git-common-dir)" && pwd -P)/decisions"

# run <project> <args...>: the project's helper, run from the project; sets RC, OUT, ERR
run() {
  local dir="$1"
  shift
  set +e
  OUT="$(cd "$dir" && bash .claude/bin/decisions.sh "$@" 2>"$WORK/err")"
  RC=$?
  set -e
  ERR="$(cat "$WORK/err")"
}
# dec <project> <args...>: the same, output straight through
dec() { local dir="$1"; shift; (cd "$dir" && bash .claude/bin/decisions.sh "$@"); }

# key <id> <front-matter key>: the raw value as written
key() { sed -n "/^$2: /{s/^$2: //p;q;}" "$REC/$1.md"; }

# rep <text> <n>: <text> n times. Credential-shaped samples are assembled from pieces at
# run time, so this file holds no literal token for a secret scanner to flag.
rep() { local s="" i=0; while [ "$i" -lt "$2" ]; do s="$s$1"; i=$((i + 1)); done; printf '%s' "$s"; }

entries() { ls "$REC" 2>/dev/null | grep -c '^[DPS]-' || true; }

echo "[script]"
TOTAL=$((TOTAL + 1))
if [ -x "$HELPER_SRC" ]; then
  echo "  PASS: decisions.sh is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL: decisions.sh is not executable"
  FAIL=$((FAIL + 1))
fi
assert_cmd_success "bash -n '$HELPER_SRC'" "decisions.sh parses"
assert_file_contains "$HELPER_SRC" "set -euo pipefail" "decisions.sh has strict mode"
# Literal arguments only: nothing a field holds may ever be evaluated.
assert_eq "" "$(grep -nE '(^|[^A-Za-z_-])eval([^A-Za-z_-]|$)' "$HELPER_SRC" | grep -vE '^[0-9]+:[[:space:]]*#' || true)" \
  "decisions.sh never calls eval"

echo "[usage]"
run "$MAIN"
assert_eq "2" "$RC" "no command: exit 2"
run "$MAIN" frobnicate
assert_eq "2" "$RC" "an unknown command: exit 2"
run "$MAIN" help
assert_eq "0" "$RC" "help: exit 0"
assert_contains "$OUT" "Usage: decisions.sh" "help prints the usage"
run "$MAIN" add --question q --decision d --words w
assert_eq "2" "$RC" "add without --kind: exit 2"
assert_contains "$ERR" "kind is required" "it names --kind"
run "$MAIN" add --kind decision --question q --decision d
assert_eq "2" "$RC" "add without --words: exit 2"
assert_contains "$ERR" "words is required" "it names --words"
run "$MAIN" add --kind decision --decision d --words w
assert_eq "2" "$RC" "a decision without --question: exit 2"
run "$MAIN" add --kind standing-order --decision d --words w --expires never
assert_eq "2" "$RC" "a standing order without --covers: exit 2"
run "$MAIN" add --kind standing-order --decision d --words w --covers "PR #1"
assert_eq "2" "$RC" "a standing order without --expires: exit 2"
run "$MAIN" add --kind decision --question q --decision d --words w --colour blue
assert_eq "2" "$RC" "an unknown option: exit 2"
run "$MAIN" add --kind decision --question q --decision d --words w --words again
assert_eq "2" "$RC" "an option given twice: exit 2"
run "$MAIN" add --kind ruling --question q --decision d --words w
assert_eq "2" "$RC" "an unknown kind: exit 2"
run "$MAIN" add --kind decision --question q --decision d --words w --by boss
assert_eq "2" "$RC" "an unknown --by: exit 2"
run "$MAIN" add --kind decision --question q --decision d --words w --status superseded
assert_eq "2" "$RC" "add --status superseded: exit 2"
DECISIONS_DATE=2026-13-01 run "$MAIN" add --kind decision --question q --decision d --words w
assert_eq "2" "$RC" "a malformed DECISIONS_DATE: exit 2"
run "$MAIN" add --kind decision --question q --decision d --words w "a stray field value"
assert_eq "2" "$RC" "a value with no option before it: exit 2"
assert_eq "" "$(printf '%s' "$ERR" | grep -F 'a stray field value' || true)" "and the value is not printed back"
assert_eq "0" "$(entries)" "no usage error wrote an entry"

echo "[record location]"
run "$MAIN" path
assert_eq "$REC" "$OUT" "path: <git common dir>/decisions, absolute"
run "$WT" path
assert_eq "$REC" "$OUT" "path from the linked worktree: the same directory"
mkdir -p "$MAIN/src/deep"
OUT="$(cd "$MAIN/src/deep" && bash ../../.claude/bin/decisions.sh path 2>/dev/null)"
assert_eq "$REC" "$OUT" "path from a subdirectory: the same directory"
# The repository the command runs in decides, never where the script lives: a test that
# runs a checkout's copy by its path from a temp repository must not reach that
# checkout's record. Only path, which writes nothing, runs the kit's own copy.
OUT="$(cd "$MAIN" && bash "$HELPER_SRC" path 2>/dev/null)"
assert_eq "$REC" "$OUT" "another checkout's copy, run by its path, uses the working directory's repository"
run "$MAIN" in-force
assert_eq "0:" "$RC:$OUT" "in-force before the first entry: nothing, exit 0"
run "$MAIN" hash
assert_eq "0:" "$RC:$OUT" "hash before the first entry: nothing, exit 0"
run "$MAIN" export
assert_eq "0:" "$RC:$OUT" "export before the first entry: nothing, exit 0"
assert_dir_not_exists "$REC" "the readers create no record directory"

echo "[add]"
run "$MAIN" add --kind decision --question "When the kit firewall and safe-ai-skill disagree about .env, who decides?" \
  --decision "The kit tier decides; safe-ai-skill defers." --words "2. b kit wins, and should be rippled to safe ai skill" \
  --premises "PR #263 adds the .env rows [verified]" --slug env-tier
assert_eq "0" "$RC" "add: exit 0"
assert_eq "D-2026-10-22-env-tier" "$OUT" "add prints the new id: <D|P|S>-<date>-<slug>"
assert_file_exists "$REC/D-2026-10-22-env-tier.md" "one markdown file per entry, named by its id"
KEYS="$(awk 'NR == 1 { next } /^---/ { exit } { sub(/:.*/, ""); printf "%s ", $0 }' "$REC/D-2026-10-22-env-tier.md")"
assert_eq "id kind status decided-by date question decision your-words premises enforced-by supersedes covers requires expires " \
  "$KEYS" "the front matter carries every contract key, in order"
assert_eq "D-2026-10-22-env-tier" "$(key D-2026-10-22-env-tier id)" "id matches the file name"
assert_eq "in-force" "$(key D-2026-10-22-env-tier status)" "status defaults to in-force"
assert_eq "you" "$(key D-2026-10-22-env-tier decided-by)" "decided-by defaults to you"
assert_eq "2026-10-22" "$(key D-2026-10-22-env-tier date)" "date comes from DECISIONS_DATE"
assert_eq '"none yet"' "$(key D-2026-10-22-env-tier enforced-by)" "enforced-by defaults to none yet"
assert_eq "—" "$(key D-2026-10-22-env-tier supersedes)" "an unset field is written as —"
assert_file_contains "$REC/in-force.md" 'D-2026-10-22-env-tier: The kit tier decides; safe-ai-skill defers. — "2. b kit wins, and should be rippled to safe ai skill" (2026-10-22)' \
  "in-force.md: id, decision, the user's words and date on one line"
assert_eq "$(cd "$MAIN" && git hash-object --stdin < "$REC/in-force.md")" "$(cat "$REC/in-force.sha")" \
  "in-force.sha holds the blob id of in-force.md"
run "$MAIN" hash
assert_eq "$(cat "$REC/in-force.sha")" "$OUT" "hash prints in-force.sha"

run "$MAIN" add --kind decision --question "Where should the commands live?" --decision "Kit only." --words "Kit only"
assert_eq "D-2026-10-22-commands-live" "$OUT" "the slug defaults to the question, stop words dropped"
run "$MAIN" add --kind decision --question "Where should the commands live?" --decision "Kit only." --words "Kit only" --status proposed
assert_eq "D-2026-10-22-commands-live-2" "$OUT" "a name already taken that day gets a -2"
run "$MAIN" add --kind principle --decision "Relaxed never gets in the way; High is diligent." \
  --words "relaxed tier should never get in the way of the day to day useflow, high tier is diligent" --slug relaxed-smooth
assert_eq "P-2026-10-22-relaxed-smooth" "$OUT" "a principle needs no question and takes the P prefix"
run "$MAIN" add --kind S --decision "Merge #253 and #254, then #255 and #256 on green CI." \
  --words "merge 253, 254 and leave open the ai review after they are merged then merge 255, 256 after the ci is green" \
  --covers "PRs #253, #254, #255, #256 — nothing else" --requires "CI green on the head SHA" --expires "when all four are merged" \
  --slug merge-train --date 2026-10-21
assert_eq "S-2026-10-21-merge-train" "$OUT" "a standing order takes the S prefix; --date overrides DECISIONS_DATE"
assert_file_contains "$REC/in-force.md" "[covers: PRs #253, #254, #255, #256 — nothing else; requires: CI green on the head SHA; expires: when all four are merged]" \
  "a standing order's line carries what it covers, needs and when it lapses"
assert_eq "drwx------" "$(ls -ld "$REC" | cut -c1-10)" "the record directory is private to the user"
assert_eq "-rw-------" "$(ls -l "$REC/D-2026-10-22-env-tier.md" | cut -c1-10)" "an entry is private to the user"
assert_eq "" "$(cd "$MAIN" && git status --porcelain)" "the record never shows in git status"

echo "[linked worktree]"
DECISIONS_DATE=2026-10-20 run "$WT" add --kind decision --question "Start the firewall PR now?" --decision "Yes, start it now." \
  --words "Yes, start it now" --slug firewall-now
assert_eq "D-2026-10-20-firewall-now" "$OUT" "add from the linked worktree"
assert_file_exists "$REC/D-2026-10-20-firewall-now.md" "the worktree writes the shared record"
assert_file_contains "$REC/in-force.md" "D-2026-10-20-firewall-now" "the main checkout's in-force list has it at once"
HM="$(dec "$MAIN" hash)"
HW="$(dec "$WT" hash)"
assert_eq "$HM" "$HW" "hash is the same from the main checkout and the worktree"
assert_eq "" "$(cd "$WT" && git status --porcelain)" "nor in the worktree's git status"

echo "[in-force]"
run "$MAIN" in-force
assert_eq "0" "$RC" "in-force: exit 0"
FIRST="${OUT%%$'\n'*}"
assert_contains "$FIRST" "D-2026-10-20-firewall-now" "oldest first: the earliest date leads though it was recorded last"
assert_eq "$(cat "$REC/in-force.md")" "$OUT" "in-force prints in-force.md"
assert_eq "5" "$(printf '%s\n' "$OUT" | grep -c '^- ')" "one line per entry in force (the proposal is left out)"
run "$MAIN" add --kind decision --question "Use a panel for wording?" --decision "Panels never clear taste calls." --words "a panel never clears a taste call" --by panel
assert_contains "$(cat "$REC/in-force.md")" "D-2026-10-22-use-panel-wording [panel]: Panels never clear taste calls." \
  "an entry the user did not decide is marked with who did"
run "$MAIN" add --kind decision --question "Provisional call?" --decision "Retry later." --words "picked during recovery" --by agent --status provisional
assert_file_not_contains "$REC/in-force.md" "Retry later." "a provisional entry is not in force"

echo "[supersede]"
H1="$(dec "$MAIN" hash)"
DECISIONS_DATE=2026-10-23 run "$WT" supersede D-2026-10-22-commands-live --decision "Kit only, no links." --words "Kit only"
assert_eq "0" "$RC" "supersede: exit 0"
assert_eq "D-2026-10-23-commands-live" "$OUT" "the replacement keeps the slug, with its own date"
assert_eq "superseded" "$(key D-2026-10-22-commands-live status)" "the old entry is marked superseded"
assert_file_contains "$REC/D-2026-10-22-commands-live.md" "Superseded by D-2026-10-23-commands-live (2026-10-23)." \
  "the old entry names its replacement"
assert_eq "D-2026-10-22-commands-live" "$(key D-2026-10-23-commands-live supersedes)" "the new entry records what it supersedes"
assert_eq '"Where should the commands live?"' "$(key D-2026-10-23-commands-live question)" "the question carries over"
assert_eq "decision" "$(key D-2026-10-23-commands-live kind)" "the kind carries over"
assert_file_not_contains "$REC/in-force.md" "D-2026-10-22-commands-live:" "the superseded entry leaves in-force.md"
assert_file_contains "$REC/in-force.md" "D-2026-10-23-commands-live: Kit only, no links." "its replacement joins it"
H2="$(dec "$MAIN" hash)"
TOTAL=$((TOTAL + 1))
if [ -n "$H1" ] && [ "$H1" != "$H2" ]; then
  echo "  PASS: the hash changes when the entries in force do"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the hash did not change across a supersede ($H1 -> $H2)"
  FAIL=$((FAIL + 1))
fi
N="$(entries)"
run "$MAIN" supersede D-2026-10-22-commands-live --decision x --words y
assert_eq "1" "$RC" "superseding an entry already superseded: refused"
run "$MAIN" supersede D-2026-10-22-no-such-entry --decision x --words y
assert_eq "1" "$RC" "superseding an unknown id: refused"
run "$MAIN" supersede ../../config --decision x --words y
assert_eq "1" "$RC" "an id that is a path: refused"
run "$MAIN" supersede D-2026-10-22-env-tier --decision x --words y --by agent
assert_eq "1" "$RC" "an agent superseding the user's decision: refused"
assert_contains "$ERR" "only the user supersedes it" "it says why"
run "$MAIN" supersede D-2026-10-22-env-tier --decision x --words y --status proposed
assert_eq "2" "$RC" "a proposal superseding anything: refused"
assert_eq "$N" "$(entries)" "no refused supersede wrote an entry"
assert_eq "in-force" "$(key D-2026-10-22-env-tier status)" "and none touched the entry it named"
run "$MAIN" add --kind decision --question "Lint style?" --decision "Tabs." --words "minor and clear" --by agent --slug lint-style
run "$MAIN" supersede D-2026-10-22-lint-style --decision "Spaces." --words "minor and clear" --by agent
assert_eq "0:D-2026-10-22-lint-style-2" "$RC:$OUT" "an agent's own call can be superseded by an agent"
# A supersede that stopped before marking the old file still takes it out of force.
sed 's/^status: superseded$/status: in-force/' "$REC/D-2026-10-22-commands-live.md" > "$WORK/old.md"
cat "$WORK/old.md" > "$REC/D-2026-10-22-commands-live.md"
run "$MAIN" in-force
assert_eq "" "$(printf '%s\n' "$OUT" | grep 'D-2026-10-22-commands-live:' || true)" \
  "an entry another in-force entry supersedes stays out, whatever its own file says"

echo "[hand edits]"
# A hand edit or deletion counts at the next hash or in-force; the timestamps are moved
# back so the check does not depend on the filesystem's clock resolution.
H3="$(dec "$MAIN" hash)"
awk '{ sub(/^decision: .*/, "decision: \"Tabs, edited by hand.\"") } 1' "$REC/D-2026-10-20-firewall-now.md" > "$WORK/edit.md"
cat "$WORK/edit.md" > "$REC/D-2026-10-20-firewall-now.md"
touch -t 202001010000 "$REC/in-force.sha"
H4="$(dec "$MAIN" hash)"
assert_file_contains "$REC/in-force.md" "Tabs, edited by hand." "hash regenerates after an entry is edited by hand"
TOTAL=$((TOTAL + 1))
if [ "$H3" != "$H4" ] && [ "$H4" = "$(cat "$REC/in-force.sha")" ]; then
  echo "  PASS: and prints the new hash"
  PASS=$((PASS + 1))
else
  echo "  FAIL: hash after a hand edit ($H3 -> $H4)"
  FAIL=$((FAIL + 1))
fi
rm -f "$REC/D-2026-10-22-use-panel-wording.md"
touch -t 202001010000 "$REC/in-force.sha"
dec "$MAIN" hash > /dev/null
assert_file_not_contains "$REC/in-force.md" "use-panel-wording" "hash regenerates after an entry is deleted by hand"
ln -s "$REC/D-2026-10-22-env-tier.md" "$REC/D-2026-10-22-planted-link.md"
run "$MAIN" in-force
assert_eq "" "$(printf '%s\n' "$OUT" | grep 'planted-link' || true)" "a symlink is never read as an entry"
rm -f "$REC/D-2026-10-22-planted-link.md"
printf -- '---\nid: D-2026-10-22-half-written\nstatus: in-force\ndecision: "partial"\n' > "$REC/D-2026-10-22-half-written.md"
run "$MAIN" in-force
assert_eq "" "$(printf '%s\n' "$OUT" | grep 'half-written' || true)" "a file whose front matter never closes is skipped"
rm -f "$REC/D-2026-10-22-half-written.md"

echo "[export]"
run "$MAIN" export
assert_eq "0" "$RC" "export: exit 0"
IDS="$(printf '%s\n' "$OUT" | sed -n 's/^id: //p' | tr '\n' ' ')"
assert_contains "$IDS" "D-2026-10-22-commands-live D-2026-10-22-commands-live-2" "export prints every entry, superseded and proposed included"
assert_eq "D-2026-10-20-firewall-now" "$(sed -n '/^id: /{s/^id: //p;q;}' <<<"$OUT")" "export is oldest first"
assert_eq "$(ls "$REC" | grep -c '^[DPS]-')" "$(printf '%s\n' "$OUT" | grep -c '^id: ')" "export prints each entry once"
run "$MAIN" export --handoff
assert_eq "0" "$RC" "export --handoff: exit 0"
assert_contains "$OUT" "## In force (" "the handoff lists what is in force"
assert_contains "$OUT" "## Proposed (1)" "then the proposals"
assert_contains "$OUT" "## Provisional (1)" "and the provisional calls"
assert_contains "$OUT" "## Superseded (" "and what was superseded"
assert_contains "$OUT" "Superseded by: D-2026-10-23-commands-live" "naming each replacement"
assert_contains "$OUT" "The user's words (2026-10-22): \"2. b kit wins, and should be rippled to safe ai skill\"" "quoting the user's words with their date"
run "$MAIN" export --everything
assert_eq "2" "$RC" "export takes only --handoff"

echo "[verbatim words]"
WORDS='ok, "links" too — ação, 日本語, 🚀; back\slash \n not-a-newline $(touch PWNED) `touch PWNED2` 50% & | ; '"'single'"
run "$MAIN" add --kind decision --question "Quotes and unicode?" --decision "Kept verbatim." --words "$WORDS" --slug verbatim
assert_eq "0" "$RC" "words with quotes, backslashes, shell syntax and unicode are accepted"
assert_file_contains "$REC/in-force.md" "\"$WORDS\" (2026-10-22)" "the in-force line quotes them byte for byte"
OUT="$(dec "$MAIN" export --handoff)"
assert_contains "$OUT" "\"$WORDS\"" "and so does the handoff"
assert_file_not_exists "$MAIN/PWNED" "nothing in a field is executed (\$(...))"
assert_file_not_exists "$MAIN/PWNED2" "nothing in a field is executed (backticks)"
MULTI="first line
second line	with a tab"
run "$MAIN" add --kind decision --question "Two lines?" --decision "Kept." --words "$MULTI" --slug two-lines
assert_eq '"first line\nsecond line\twith a tab"' "$(key D-2026-10-22-two-lines your-words)" "newlines and tabs are stored escaped, on one line"
assert_file_contains "$REC/in-force.md" '"first line second line with a tab"' "the in-force line flattens them"
OUT="$(dec "$MAIN" export --handoff)"
assert_contains "$OUT" "  > first line" "the handoff quotes each line of multi-line words"
assert_contains "$OUT" "  > second line	with a tab" "keeping the tab"

echo "[stdin]"
# Fields read from a quoted heredoc never sit on the command line, where the guard hooks
# take a word naming a credential path for a file argument.
run "$MAIN" add --kind decision --slug gh-host-file --stdin <<'EOF'
# a comment line is skipped
question: At Relaxed, which credential files may Bash read?
decision: Open only ~/.config/gh/hosts.yml; the wallet ~/.config/solana/id.json and every other credential file stay denied.
words: Open only gh's host file

  a second paragraph, "quoted"
premises: firewall.sh denies the wallet at every tier [verified]
EOF
assert_eq "0:D-2026-10-22-gh-host-file" "$RC:$OUT" "add --stdin records the fields it reads"
assert_eq '"Open only ~/.config/gh/hosts.yml; the wallet ~/.config/solana/id.json and every other credential file stay denied."' \
  "$(key D-2026-10-22-gh-host-file decision)" "a credential path in a field is kept as written"
assert_eq '"Open only gh'"'"'s host file\n\na second paragraph, \"quoted\""' "$(key D-2026-10-22-gh-host-file your-words)" \
  "indented and blank lines continue the value, keeping its line breaks"
assert_eq '"firewall.sh denies the wallet at every tier [verified]"' "$(key D-2026-10-22-gh-host-file premises)" \
  "the field after a multi-line one starts fresh"
DECISIONS_DATE=2026-10-23 run "$MAIN" supersede D-2026-10-22-gh-host-file --stdin <<'EOF'
decision: Open only ~/.config/gh/hosts.yml at Relaxed.
your-words: Open only gh's host file
EOF
assert_eq "0:D-2026-10-23-gh-host-file" "$RC:$OUT" "supersede --stdin, taking your-words as the front matter spells it"
assert_eq '"Open only gh'"'"'s host file"' "$(key D-2026-10-23-gh-host-file your-words)" "your-words lands in the same field as words"
N="$(entries)"
run "$MAIN" add --kind decision --question q --stdin <<'EOF'
question: asked twice
decision: d
words: w
EOF
assert_eq "2" "$RC" "a field given on the command line and on stdin is refused"
run "$MAIN" add --stdin <<'EOF'
kind: decision
question: q
decision: d
words: w
colour: blue
EOF
assert_eq "2" "$RC" "an unknown field name on stdin is refused"
run "$MAIN" add --stdin <<'EOF'
kind: decision
this line has no colon
EOF
assert_eq "2" "$RC" "a line that is not name: value is refused"
TOKEN="gh""p_$(rep a 36)"
run "$MAIN" add --stdin <<EOF
kind: decision
question: q
decision: d
words: my token is $TOKEN
EOF
assert_eq "1" "$RC" "credentials are refused on stdin too"
assert_eq "$N" "$(entries)" "no refused stdin add wrote an entry"
# The route has to stay open: if a guard starts blocking a heredoc that a script file
# reads as data, recording any decision about credential paths stops working.
HD_CMD="bash .claude/bin/decisions.sh add --kind decision --stdin <<'EOF'
question: Which files stay denied?
decision: ~/.ssh, ~/.config/solana/id.json, ~/.npmrc and .env stay denied; cat ~/.ssh/id_rsa is never run.
words: keys, funds, mainnet, money are mine
EOF"
HD_PAYLOAD="$(python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$HD_CMD")"
for tier in off relaxed high; do
  for guard in onchain-guard egress-guard; do
    set +e
    HD_OUT="$(cd "$MAIN" && printf '%s' "$HD_PAYLOAD" | CLAUDE_PROJECT_DIR="$MAIN" KIT_FIREWALL_TIER="$tier" KIT_FIREWALL_HEADLESS=0 \
      sh "$REPO_ROOT/.claude/hooks/$guard.sh" 2>&1)"
    HD_RC=$?
    set -e
    assert_eq "0:" "$HD_RC:$HD_OUT" "$guard stays silent on a --stdin heredoc naming credential paths ($tier)"
  done
done

echo "[credentials]"
BYTES="[$(i=0; s=""; while [ "$i" -lt 64 ]; do s="$s$(( (i * 37) % 256 )),"; i=$((i + 1)); done; printf '%s' "${s%,}")]"
PRETTY="$(printf '[\n'; i=0; while [ "$i" -lt 40 ]; do printf '  %d,\n' $((i + 7)); i=$((i + 1)); done; printf '  9\n]')"
# refuse <option> <label> <value>: refused naming the option and the kind of credential,
# with the value never printed and nothing written.
refuse() {
  local opt="$1" label="$2" val="$3" n q="q?" d="d" w="w" args echoed=no
  n="$(entries)"
  case "$opt" in --question) q="$val" ;; --decision) d="$val" ;; --words) w="$val" ;; esac
  args=(add --kind decision --question "$q" --decision "$d" --words "$w")
  case "$opt" in --question|--decision|--words) ;; *) args=("${args[@]}" "$opt" "$val") ;; esac
  run "$MAIN" "${args[@]}"
  case "$OUT$ERR" in *"$val"*) echoed=yes ;; esac
  TOTAL=$((TOTAL + 1))
  if [ "$RC" -eq 1 ] && grep -qF -- "refusing $opt: it looks like $label" <<<"$ERR" \
    && [ "$echoed" = no ] && [ "$(entries)" = "$n" ]; then
    echo "  PASS: refuses $label in $opt, without echoing it"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label in $opt (rc=$RC, $(entries) entries, was $n): $ERR"
    FAIL=$((FAIL + 1))
  fi
}
refuse --words "a keypair byte array" "my keypair $BYTES"
refuse --premises "a keypair byte array" "$PRETTY"
refuse --decision "a PEM key or certificate block" "-----BEG""IN OPENSSH PRIVATE KEY----- abc"
refuse --words "a base58 64-byte secret key" "4$(rep K 87)"
# A Solana keypair is 64 bytes: refused as a bare list of its numbers and inside a C# or
# Unity initializer's braces, as well as a JSON array, and in base58 from 80 characters.
BARE="$(i=0; s=""; while [ "$i" -lt 64 ]; do s="$s$(( (i * 53 + 11) % 256 )), "; i=$((i + 1)); done; printf '%s' "${s%, }")"
refuse --words "a keypair byte array" "the deploy key is $BARE"
refuse --decision "a keypair byte array" "new byte[] { $BARE }"
refuse --words "a base58 64-byte secret key" "$(rep K 80)"
refuse --premises "a base58 64-byte secret key" "key $(rep 7 84) here"
refuse --words "a GitHub token" "token gh""p_$(rep a 36) here"
refuse --covers "a GitHub token" "github_""pat_$(rep B 40)"
refuse --words "an sk- API key" "sk-""ant-api03-$(rep x 30)"
refuse --question "an sk- API key" "is sk-""proj-$(rep Y 40) live?"
refuse --words "an AWS access key id" "AKI""A$(rep Q 16)"
refuse --expires "a Slack token" "xox""b-1234567890-$(rep z 20)"
refuse --words "a Google API key" "AIz""a$(rep k 35)"
refuse --words "a Stripe key" "sk_""live_$(rep r 24)"
refuse --words "an npm token" "np""m_$(rep n 36)"
refuse --words "a PyPI token" "pyp""i-$(rep y 60)"
refuse --words "a GitLab token" "glp""at-$(rep g 20)"
refuse --words "a Hugging Face token" "h""f_$(rep h 34)"
refuse --words "a JWT" "eyJ$(rep h 12).eyJ$(rep p 12).$(rep s 12)"
refuse --requires "a URL with a password" "https://deploy:$(rep p 12)@example.com/repo"
refuse --words "a key in a URL query" "https://mainnet.helius-rpc.com/?api-key=$(rep u 36)"
refuse --enforced-by "a credential assignment" "HELIUS_API_""KEY=$(rep v 20)"
refuse --slug "a GitHub token" "gh""p_$(rep a 36)"
# Not credentials: public keys, digests and the names of protected files must pass.
for v in "the token program TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA stays pinned" \
  "commit c7a86c9e1f2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b" "sha256 $(rep ab 32)" \
  "the wallet ~/.config/solana/id.json and .env stay denied" "HELIUS_API_KEY stays optional; set HELIUS_API_KEY=<your key>" \
  "task-runner-configuration-for-the-ci-matrix" "GITHUB_TOKEN=\${{ secrets.GITHUB_TOKEN }}" "[1, 2, 3]" \
  "PRs 12, 13, 14 and 15 merge first; ports 8080, 8899 and 9900 stay open"; do
  run "$MAIN" add --kind decision --question "Not a secret?" --decision "Accepted." --words "$v" --status proposed --slug not-secret
  assert_eq "0" "$RC" "accepts: ${v:0:60}"
done
run "$MAIN" add --kind decision --question "Not a secret?" --decision "Accepted." --words "$(rep K 79)" --status proposed --slug not-secret
assert_eq "0" "$RC" "a base58 run under 80 characters is not taken for a secret key"

echo "[limits]"
run "$MAIN" add --kind decision --question q --decision d --words "$(rep x 4001)"
assert_eq "1" "$RC" "a field over 4000 bytes is refused"
run "$MAIN" add --kind decision --question q --decision d --words "$(printf 'red \033[31m text')"
assert_eq "1" "$RC" "a control character is refused"
assert_contains "$ERR" "control character" "naming why"

echo "[budget]"
# Its own project, so the size is predictable.
BUD="$WORK/budget"
mkdir -p "$BUD/.claude/bin"
cp "$HELPER_SRC" "$BUD/.claude/bin/decisions.sh"
(cd "$BUD" && git init -q -b main)
BREC="$(cd "$(cd "$BUD" && git rev-parse --path-format=absolute --git-common-dir)" && pwd -P)/decisions"
LONG="$(rep 'ação ' 100)end of the words"
i=1
while [ "$i" -le 12 ]; do
  dec "$BUD" add --kind decision --question "budget question $i" --decision "$(rep 'decide ' 40)" --words "$LONG" > /dev/null 2>&1
  i=$((i + 1))
done
SIZE="$(wc -c < "$BREC/in-force.md" | tr -d ' ')"
TOTAL=$((TOTAL + 1))
if [ "$SIZE" -le 6000 ]; then
  echo "  PASS: 12 long entries fit in-force.md under about 1.5K tokens ($SIZE bytes)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: 12 long entries make in-force.md $SIZE bytes, over 6000"
  FAIL=$((FAIL + 1))
fi
assert_file_contains "$BREC/in-force.md" "…\" (2026-10-22)" "long words are cut with an ellipsis"
assert_file_contains "$BREC/in-force.md" "(… marks text cut to fit; decisions.sh export prints the full entries)" "and the list says where the full text is"
assert_file_contains "$BREC/D-2026-10-22-budget-question-1.md" "end of the words\"" "the entry keeps every word"
assert_cmd_success "python3 -c 'import sys; open(sys.argv[1], encoding=\"utf-8\").read()' '$BREC/in-force.md'" \
  "a cut never splits a UTF-8 character"
# Standing orders carry three more bounded fields per line, so a few more pass the budget.
while [ "$i" -le 20 ]; do
  dec "$BUD" add --kind standing-order --decision "$(rep 'merge ' 40)" --words "$LONG" --covers "$(rep 'PR #1, ' 20)" \
    --requires "$(rep 'CI green, ' 10)" --expires "$(rep 'when merged, ' 10)" --slug "order-$i" > /dev/null 2> "$WORK/budget.err"
  i=$((i + 1))
done
assert_file_contains "$WORK/budget.err" "over its 1.5K-token budget" "past the budget, add warns"

echo "[parallel writers]"
for i in 1 2 3 4; do
  (dec "$MAIN" add --kind decision --question "Same name, same day?" --decision "Parallel $i." --words "w$i" > "$WORK/par.$i" 2>&1) &
  (dec "$WT" in-force > /dev/null 2>&1) &
done
wait
assert_eq "4" "$(cat "$WORK"/par.* | grep -c '^D-2026-10-22-same-name-same-day')" "four parallel adds of one name each get an id"
assert_eq "4" "$(cat "$WORK"/par.* | sort -u | wc -l | tr -d ' ')" "and no two share one"
assert_eq "4" "$(grep -c 'Parallel [1-4]\.' "$REC/in-force.md")" "in-force.md ends with all four"
assert_eq "$(cd "$MAIN" && git hash-object --stdin < "$REC/in-force.md")" "$(cat "$REC/in-force.sha")" "and in-force.sha matches it"
assert_eq "0" "$(ls -A "$REC" | grep -c '^\.tmp' || true)" "no temp file is left behind"

echo "[outside a repository]"
NOGIT="$WORK/nogit"
mkdir -p "$NOGIT/.claude/bin"
cp "$HELPER_SRC" "$NOGIT/.claude/bin/decisions.sh"
run "$NOGIT" path
assert_eq "1" "$RC" "path outside a git repository: exit 1"
run "$NOGIT" add --kind decision --question q --decision d --words w
assert_eq "1" "$RC" "add outside a git repository: exit 1"
run "$NOGIT" in-force
assert_eq "0:" "$RC:$OUT" "in-force outside a git repository: nothing, exit 0"
run "$NOGIT" hash
assert_eq "0:" "$RC:$OUT" "hash outside a git repository: nothing, exit 0"

print_summary
