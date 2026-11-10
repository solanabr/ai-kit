#!/bin/sh
# decisions-report-check.sh — SubagentStop: send one of the kit's agents back, once,
# when its report leaves out part of the return contract.
#
# The contract is five labelled lines, "none" being a fine answer:
#
#   Verified:          what the agent checked, as a command and its result
#   Decisions made:    the calls it took itself
#   Decisions needed:  the calls that are the user's, each as a brief
#   Assumptions:       what it took as given without checking
#   Next owner:        who should take the work next
#
# A decision an agent takes and does not report is one nobody can check, and one it
# needs but leaves inside a status line never reaches the user. The check is on the
# labels, deterministically: no model call, so it costs nothing, answers the same way
# twice and cannot misread a report. That is also its limit: "Decisions made: none"
# passes, because presence can be checked and honesty cannot.
#
# Scope:
#   - The kit's own agents only, by name, bare or plugin-scoped (solana-ai-kit:<name>).
#     SubagentStop also fires for Claude Code's internal agents (prompt suggestions,
#     /btw side questions) and for general-purpose, Explore and every user-written
#     agent; none of them was given this contract, so none is held to it. The
#     registration's matcher names the same agents, and this list holds where a harness
#     ignores the matcher. One gap: an internal agent carries the session's own agent
#     name, so in a session started as `claude --agent <kit agent>` it can be sent back
#     once, for one extra turn.
#   - Where the project teaches it. No agent's own prompt carries the labels. They reach
#     a kit agent through the project's instruction files, as CLAUDE-solana.md's subagent
#     line, which install.sh writes as the project's ./CLAUDE.md, and through the briefs
#     /implement, /parallel and /research write, which this hook does not read. Where
#     none of those files carries the line, the check steps aside: a plugin ships no
#     project ./CLAUDE.md, and an older install's ./CLAUDE.md lacks the line until the user
#     merges it in from the ./CLAUDE.md.upstream that /update leaves beside it.
#   - Once per stop: stop_hook_active means a stop hook already sent this agent back.
#   - The report as delivered. In auto mode a subagent reports through the
#     SubagentHandback tool and last_assistant_message holds only its closing text, so
#     the last handback's message is read from the agent's own transcript when there is
#     one, and last_assistant_message otherwise.
#   - Prose only. A report that is JSON, such as a workflow agent returning its schema,
#     is a value for a program, not a report to a person.
#
# It never decides a tool call: the most it does is keep a subagent running for one
# more turn, and the registration's wrapper exits 0 whatever this script does.
#
# stdin: SubagentStop JSON. stdout: {"decision":"block","reason":...}, or nothing.

INPUT=$(cat)

# Next to a full install, which registers its own copy, the plugin's copy steps aside.
case ${CLAUDE_PLUGIN_ROOT-} in
  ?*) [ "$0" = "$CLAUDE_PLUGIN_ROOT/hooks/decisions-report-check.sh" ] \
        && [ -f "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/decisions-report-check.sh" ] && exit 0 ;;
esac

case $INPUT in
  *'"stop_hook_active":true'* | *'"stop_hook_active": true'* | \
  *'"stopHookActive":true'* | *'"stopHookActive": true'*) exit 0 ;;
esac

# json_str <key> — the string value of a top-level "<key>" in the payload, in V. The
# same reader as the other two decision hooks: ids, names and paths run to their
# closing quote, and a key named twice is left to jq.
json_str() {
  case $INPUT in
    *"\"$1\""*"\"$1\""*)
      command -v jq >/dev/null 2>&1 || return 1
      V=$(printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty | strings' 2>/dev/null)
      [ -n "$V" ]
      return ;;
    *"\"$1\""*) V=${INPUT#*\"$1\"} ;;
    *) return 1 ;;
  esac
  V=${V#"${V%%[! ]*}"}
  case $V in :*) V=${V#:} ;; *) return 1 ;; esac
  V=${V#"${V%%[! ]*}"}
  case $V in \"*) V=${V#\"}; V=${V%%\"*} ;; *) return 1 ;; esac
  [ -n "$V" ]
}

# A subagent the hook can name. Kept in step with .claude/agents/ and with the matcher
# in both hook registrations; tests/test_hooks.sh fails when they drift.
json_str agent_id || json_str agentId || exit 0
json_str agent_type || json_str agentType || exit 0
case ${V#solana-ai-kit:} in
  anchor-engineer | defi-engineer | devops-engineer | game-architect | mobile-engineer | \
  pinocchio-engineer | rust-backend-engineer | solana-architect | solana-frontend-engineer | \
  solana-guide | solana-qa-engineer | solana-researcher | tech-docs-writer | token-engineer | \
  unity-engineer) ;;
  *) exit 0 ;;
esac

# Does the project teach the contract? The files read are the ones Claude Code loads as
# the project's instructions, under CLAUDE_PROJECT_DIR: ./CLAUDE.md, .claude/CLAUDE.md and
# CLAUDE.local.md, or AGENTS.md where it reads that in their place. Not @imports, files
# above the project or .claude/rules/: the kit writes none of them, and a file not read
# here only makes the check step aside. In a session that entered a worktree,
# CLAUDE_PROJECT_DIR stays on the main checkout while ./CLAUDE.md loads from the worktree,
# so there the main checkout's files decide. Checked before the transcript is read: a
# project with no instruction file costs a few stat calls, and one whose files lack the
# line one awk over those files.
P=${CLAUDE_PROJECT_DIR:-$PWD}
case $P in /*) ;; *) P=$PWD/$P ;; esac

# plain <path> — true when <path> is a regular file this hook may read, in F: the file
# itself, or reached through links that each name a file beside them, as
# `ln -s AGENTS.md CLAUDE.md` makes, up to eight. No other link is followed. These hooks
# run outside the sandbox, and a link elsewhere can name a file outside the project, a
# FIFO that never answers, or a network path whose lookup alone contacts the host named.
# The check comes before the read, and a shell cannot open a file without following a
# link, so a file swapped for a link in between still gets its open. That swap can
# change only the verdict, or hold the stop until the registration's 10-second timeout.
plain() {
  F=$1 HOPS=0
  while [ -L "$F" ]; do
    [ "$HOPS" -lt 8 ] || return 1
    HOPS=$((HOPS + 1))
    L=$(readlink "$F" 2>/dev/null) || return 1
    L=${L#./}
    case $L in '' | . | .. | */*) return 1 ;; esac
    F=${F%/*}/$L
  done
  [ -f "$F" ] && [ -r "$F" ]
}

# agents_md — AGENTS.md, in F, when Claude Code reads it as the project's instructions,
# which by default it does only when no ./CLAUDE.md, .claude/CLAUDE.md or ./CLAUDE.local.md
# sits in the project or a directory above it, ~/.claude/CLAUDE.md aside.
# `install.sh --agents` writes one. A .claude that is a link counts as holding a
# .claude/CLAUDE.md, rather than be looked into.
agents_md() {
  D=$P
  while :; do
    [ -L "$D/CLAUDE.md" ] || [ -e "$D/CLAUDE.md" ] || [ -L "$D/CLAUDE.local.md" ] \
      || [ -e "$D/CLAUDE.local.md" ] && return 1
    if [ "$D" != "${HOME%/}" ]; then
      [ -L "$D/.claude" ] || [ -L "$D/.claude/CLAUDE.md" ] || [ -e "$D/.claude/CLAUDE.md" ] && return 1
    fi
    case $D in */*[!/]*) D=${D%/*}; [ -n "$D" ] || D=/ ;; *) break ;; esac
  done
  plain "$P/AGENTS.md"
}

# taught — true when one of those files has a line naming all five labels, outside a
# block-level HTML comment: Claude Code strips those from an instruction file before the
# model reads it, so a line commented out there asks for nothing. Code fences are not
# tracked, so a comment opened inside one reads as a comment too: an error that can only
# make the check step aside, never send an agent back.
taught() {
  set --
  for N in CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md; do  # AGENTS.md: agents_md, after the loop
    case $N in .claude/*) [ -L "$P/.claude" ] && continue ;; esac
    if plain "$P/$N"; then set -- "$@" "$F"; fi
  done
  if [ $# -eq 0 ] && agents_md; then set -- "$F"; fi
  [ $# -gt 0 ] || return 1
  LC_ALL=C awk '
    FNR == 1 { c = 0 }
    c { if (index($0, "-->")) c = 0; next }
    match($0, /^ *<!--/) && RLENGTH <= 7 { c = !index(substr($0, RLENGTH + 1), "-->"); next }
    { l = tolower($0) }
    index(l, "verified") && index(l, "decisions made") && index(l, "decisions needed") &&
      index(l, "assumptions") && index(l, "next owner") { t = 1; exit }
    END { exit !t }' "$@" 2>/dev/null
}
taught || exit 0

# Absolute paths only: awk reads an operand shaped like name=value as an assignment.
T=/dev/null
if json_str agent_transcript_path || json_str agentTranscriptPath; then
  case $V in /*) [ -f "$V" ] && [ -r "$V" ] && T=$V ;; esac
fi

# One awk pass: the payload on stdin first, then the transcript. It prints the parts
# the report is missing, OK when none are, or SKIP when there is no prose to judge.
# LC_ALL=C keeps tolower() and the byte-wise matching the same in every awk.
MISSING=$(printf '%s\n' "$INPUT" | LC_ALL=C awk '
  # value <text> <key> — the decoded string value of the first "<key>" in <text>.
  function value(s, key,   p) {
    p = index(s, "\"" key "\"")
    if (!p) return ""
    s = substr(s, p + length(key) + 2)
    if (!match(s, /^[ \t\r\n]*:[ \t\r\n]*"/)) return ""
    return jstr(substr(s, RLENGTH + 1))
  }
  # jstr <text> — a JSON string body, decoded up to its closing quote. Every label
  # looked for is ASCII, so a \u escape becomes "?", except an en or em dash, which
  # becomes the hyphen a label may end with.
  function jstr(s,   out, p, q, c) {
    out = ""
    for (;;) {
      p = index(s, "\\"); q = index(s, "\"")
      if (q && (!p || q < p)) return out substr(s, 1, q - 1)
      if (!p) return out s
      out = out substr(s, 1, p - 1); c = substr(s, p + 1, 1)
      if (c == "n") out = out "\n"
      else if (c == "t") out = out "\t"
      else if (c == "r") out = out "\r"
      else if (c == "u") {
        out = out (substr(s, p + 2, 4) ~ /^201[34]$/ ? "-" : "?")
        s = substr(s, p + 6); continue
      }
      else out = out c
      s = substr(s, p + 2)
    }
  }
  # lab <line> <label> — the line opens with the label and then a colon, a dash, a
  # table bar or nothing, optionally after a parenthesis: "verified (cmd): ran it",
  # "next owner", "decisions made - none". Up to eight words may come between the
  # label and its colon, bar or spaced dash, the way people write labels: "assumptions
  # made:", "decisions needed from you:", "verified by running anchor test:". On a
  # heading or a line wholly in bold (FORM) the end of the line closes it too. Prose
  # that merely starts with the word does not count: "next, I ran the tests",
  # "verified the build works" and "verified the build, then ran: x" are not labels.
  function lab(l, re,   t, p, q, k, n, W) {
    if (!match(l, re)) return 0
    t = substr(l, RLENGTH + 1)
    sub(/^[ \t]*(\([^)]*\))?[ \t]*/, "", t)
    if (t == "" || t ~ /^[:|]/ || t == "-" || t ~ /^-[ \t]/ || index(t, "—") == 1 || index(t, "–") == 1) return 1
    if (substr(l, RLENGTH + 1, 1) !~ /[ \t]/) return 0
    p = 0
    for (k = 1; k <= 5; k++) { q = index(t " ", TERM[k]); if (q && (!p || q < p)) p = q }
    if (!p && FORM) p = length(t) + 1
    if (p < 2) return 0
    q = substr(t, 1, p - 1)
    if (length(q) > 80 || q ~ /[,;!?]/ || q ~ /\.[ \t]/) return 0
    n = 0; k = split(q, W, /[ \t]+/)
    while (k > 0) { if (W[k] != "") n++; k-- }
    return n >= 1 && n <= 8
  }
  BEGIN { TERM[1] = ":"; TERM[2] = "|"; TERM[3] = " - "; TERM[4] = "—"; TERM[5] = "–" }
  FNR == 1 { f++ }
  f == 1 { payload = payload $0 "\n"; next }
  /"name": ?"SubagentHandback"/ { hb = $0 }
  END {
    r = ""
    if (hb != "") { p = index(hb, "\"SubagentHandback\""); if (p) r = value(substr(hb, p), "message") }
    if (r !~ /[A-Za-z]/) r = value(payload, "last_assistant_message")
    if (r !~ /[A-Za-z]/) r = value(payload, "lastAssistantMessage")
    if (r !~ /[A-Za-z]/) { print "SKIP"; exit }
    t = r; sub(/^[ \t\r\n]+/, "", t)
    if (substr(t, 1, 1) == "{" || substr(t, 1, 1) == "[") { print "SKIP"; exit }
    n = split(r, L, "\n")
    for (i = 1; i <= n; i++) {
      # Markdown around a label is decoration: emphasis, headings, bullets, numbering.
      # A heading, or a line wholly in bold, is a label by its form.
      o = L[i]; sub(/^[ \t>]*([-*+][ \t]+|[0-9]+[.)][ \t]+)?/, "", o); sub(/[ \t\r]+$/, "", o)
      FORM = (o ~ /^#/ || (o ~ /^(\*\*|__)/ && o ~ /(\*\*|__):?$/))
      l = tolower(L[i]); gsub(/[*_`]/, "", l)
      sub(/^[^a-z0-9]+/, "", l)
      if (sub(/^[0-9]+[.)]/, "", l)) sub(/^[^a-z0-9]+/, "", l)
      if (lab(l, "^(what (i|we) |what was )?verified") || lab(l, "^verification")) v = 1
      if (lab(l, "^decisions? (i |we )?made") || lab(l, "^decided")) dm = 1
      if (lab(l, "^decisions? (i |we |you )?need(ed)?") || lab(l, "^needs? your (call|decision)s?") \
          || lab(l, "^open (decisions?|questions?)") || lab(l, "^(decisions?|questions?) for (you|the user|the lead)")) dn = 1
      if (lab(l, "^assum(ptions?|ed)") || lab(l, "^premises?")) a = 1
      if (lab(l, "^next( owner| steps?| up)?") || lab(l, "^who should (take|pick up|own)") \
          || lab(l, "^hand[- ]?(off|over)")) nx = 1
    }
    m = ""
    if (!v) m = m ", Verified"
    if (!dm) m = m ", Decisions made"
    if (!dn) m = m ", Decisions needed"
    if (!a) m = m ", Assumptions"
    if (!nx) m = m ", Next owner"
    print (m == "" ? "OK" : substr(m, 3))
  }' - "$T" 2>/dev/null) || exit 0

case $MISSING in '' | OK | SKIP) exit 0 ;; esac

printf '{"decision":"block","reason":"%s"}\n' "Your report is missing: $MISSING. Deliver the complete report again, ending with one labelled line for each of these five, and write none where there is nothing to say. Verified: what you checked, as a command and its result. Decisions made: the calls you took yourself. Decisions needed: the calls that are the user's, each as a brief with the question, your recommendation and the case against it. Assumptions: what you took as given without checking. Next owner: who should take the work next."
exit 0
