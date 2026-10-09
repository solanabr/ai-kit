# lib-tokenize.awk — the quote-aware command tokenizer shared by the firewall
# guards.  Prepended with a second -f, never run on its own:
#
#   awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/<guard>.awk"
#
# This closes the sharing half of issue #138.  Three guards had grown three
# near-copies of the same splitter — secrets-guard, egress-guard and (in a
# different shape) onchain-guard — and a copy is a corpus that drifts.  The
# copies had already drifted: one filled a quote-flag array and one did not, one
# re-skipped VAR= assignments behind a wrapper and one did not, and the wrapper
# lists disagreed by four entries.
#
# So the extraction is parameterised rather than unified.  Each guard keeps the
# semantics it shipped with, because these three implement the mainnet-deploy
# gate, the keypair-read block and the egress denylist, and "identical verdicts"
# outranks "one code path".  Where a guard needs its own answer, the library
# calls back into a function the guard defines:
#
#   kit_wrapper(w)             is w a wrapper binary to look past?
#   kit_heredoc_is_code(w)     does a heredoc fed to w carry code, not prose?
#                              (only needed by callers of strip_heredocs)
#
# The invariant every caller inherits, and the reason the splitter exists at all:
# a rule may match only a token in ARGUMENT or COMMAND position of a real
# command.  Prose that merely names a gated command — a commit message, an
# issue body, a heredoc document, a test corpus — is data and must never fire.
#
# Separators the splitter emits:
#   \001  statement boundary (data cannot flow across)
#   \002  stage boundary inside one statement (data CAN flow across)
#   \003  a backslash-escaped space that must not split a token

BEGIN { SQ = sprintf("%c", 39) }

# ---------------------------------------------------------------- small predicates

# base — the command's basename.  Strips a leading backslash too, so an escaped
# `\env` is still recognised as the wrapper it is.
function base(p) { sub(/^\\/, "", p); sub(/^.*\//, "", p); return p }

# unmark — put back the spaces split_cmd protected with \003.
function unmark(s) { gsub(/\003/, " ", s); return s }

# looks_remote — a URL or an scp/ssh remote spec is a destination, never a local
# path.  Without it, `curl -sL https://docs.example.com/.aws/guide.html` reads as
# an attempt to exfiltrate ~/.aws.
function looks_remote(a) {
  return (a ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\// || a ~ /^[^\/ ]+@[^\/ ]+:/)
}

function is_shell(c) {
  return (c == "sh" || c == "bash" || c == "zsh" || c == "dash" || c == "ksh" || c == "fish")
}

# is_wrapper — binaries that run another command, without being a shell.  Guards
# that also look past shells say so in their own kit_wrapper.
function is_wrapper(c) {
  return (c == "env" || c == "command" || c == "builtin" || c == "exec" || c == "nohup" \
       || c == "nice" || c == "ionice" || c == "time" || c == "timeout" || c == "stdbuf" \
       || c == "xargs" || c == "sudo" || c == "doas" || c == "setsid" || c == "flock" \
       || c == "watch" || c == "noglob" || c == "eval")
}

# kit_wrapper_operand — a wrapper taking a POSITIONAL operand before the command
# it runs.  This is the bug that bit twice: skipping a wrapper's OPTIONS alone
# leaves `timeout 5 npx -y evil` with "5" in command position, so the gate never
# sees npx at all.  Only callers passing operands=1 to cmdword_x get this.
#
# Deliberately narrow.  `flock -w 5 f cmd` still misses, because skipping every
# non-flag token until something looks like a command would walk past the command
# itself on a wrapper nobody models.
function kit_wrapper_operand(w, t) {
  if (w == "timeout" && t ~ /^[0-9]/) return 1
  if (w == "flock" && t !~ /^-/) return 1
  return 0
}

# ---------------------------------------------------------------- the splitter

# split_cmd — quote-aware split into statements and pipeline stages.  Honours
# SQ..SQ (fully literal) and ".." (literal except $( ) and backticks), keeps
# ${VAR} as one token rather than reading { as a brace group, and turns a command
# substitution into a stage of its own.
function split_cmd(s,   i, c, c2, st, sp, out, j) {
  out = ""; sp = 0; st[0] = "code"
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1); c2 = substr(s, i, 2)
    if (st[sp] == "sq") { out = out c; if (c == SQ) sp--; continue }
    if (st[sp] == "dq") {
      if (c == "\\" && i < length(s)) { out = out substr(s, i+1, 1); i++; continue }
      if (c2 == "$(") { out = out " $__X__\002 "; st[++sp] = "code"; i++; continue }
      if (c == "`")   { out = out " $__X__\002 "; st[++sp] = "bt"; continue }
      if (c == "\"")  { sp--; out = out c; continue }
      out = out c; continue
    }
    if (c == "\\" && i < length(s)) {
      i++; c = substr(s, i, 1)
      if (c == " ") out = out "\003"; else out = out c
      continue
    }
    if (c == SQ)    { st[++sp] = "sq"; out = out c; continue }
    if (c == "\"")  { st[++sp] = "dq"; out = out c; continue }
    if (c2 == "${") { j = index(substr(s, i), "}"); if (j > 0) { out = out substr(s, i, j); i += j - 1; continue } }
    if (c2 == "$(") { out = out " $__X__\002 "; st[++sp] = "code"; i++; continue }
    if (c == "`")   { if (st[sp] == "bt") { sp--; out = out "\002" } else { out = out " $__X__\002 "; st[++sp] = "bt" } ; continue }
    if (c == ")" && sp > 0 && st[sp] == "code") { sp--; out = out "\002"; continue }
    if (c2 == "&&" || c2 == "||") { out = out "\001"; i++; continue }
    if (c == ";" || c == "&" || c == "\n") { out = out "\001"; continue }
    if (c == "|" || c == "(" || c == ")" || c == "{" || c == "}") { out = out "\002"; continue }
    out = out c
  }
  return out
}

# tokenize — fill T[] with tokens and Q[] with 1 where the token carried a quote.
# Q is optional: a caller passing only (s, T) gets an unused local array, which is
# how egress-guard's copy behaved before it was lifted here.
function tokenize(s, T, Q,   i, c, q, cur, n, hadq) {
  n = 0; cur = ""; q = ""; hadq = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; else cur = cur c; continue }
    if (c == SQ || c == "\"") { q = c; hadq = 1; continue }
    if (c == " " || c == "\t") { if (cur != "" || hadq) { T[++n] = cur; Q[n] = hadq; cur = ""; hadq = 0 } ; continue }
    cur = cur c
  }
  if (cur != "" || hadq) { T[++n] = cur; Q[n] = hadq }
  return n
}

# first_word — index of the first token that is not a VAR=value assignment.
function first_word(T, n,   i) {
  i = 1
  while (i <= n && T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
  return i
}

# cmdword_x — the real command word, past leading assignments and wrappers.
# Sets CWI to its index.  Returns "" when there is none.
#
#   reskip    1: re-skip VAR=value assignments after each wrapper, so
#                `env FOO=1 cat x` yields "cat".  0: skip them once at the front
#                only, so the same command yields "FOO=1" and the path lands in
#                argument position instead.  Both shipped; both are preserved.
#   operands  1: also skip a wrapper's positional operand (kit_wrapper_operand).
#
# CWI is left untouched when reskip is 1 and nothing was found, because that copy
# never assigned it there and a caller may still be reading the previous value.
function cmdword_x(T, n, reskip, operands,   ci, w) {
  ci = first_word(T, n)
  while (ci <= n) {
    if (reskip) {
      while (ci <= n && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ci++
      if (ci > n) return ""
    }
    w = base(T[ci])
    if (!kit_wrapper(w)) { CWI = ci; return w }
    ci++
    while (ci <= n && T[ci] ~ /^-/) ci++
    if (operands && ci <= n && kit_wrapper_operand(w, T[ci])) ci++
  }
  if (!reskip) CWI = n + 1
  return ""
}

# ---------------------------------------------------------------- heredocs

# strip_heredocs — drop heredoc BODIES from a raw multi-line command, returning
# what is left.  A document that merely names a gated command or a credential
# path must never fire; writing one is not running it.
#
# One exception: an UNQUOTED delimiter feeding something that executes its input
# is code, not prose, so that body is kept and inspected.  The caller decides
# what executes its input, via kit_heredoc_is_code.
function strip_heredocs(raw,   text, delim, nl, L, k, l, t, quoted, d, head, hn, HT, HQ, hw, HD_DQ, HD_SQ, HD_BARE) {
  HD_DQ = "<<-?[ \t]*\"[A-Za-z_][A-Za-z0-9_]*\""
  HD_SQ = "<<-?[ \t]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
  HD_BARE = "<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*"
  text = ""; delim = ""
  nl = split(raw, L, "\n")
  for (k = 1; k <= nl; k++) {
    l = L[k]
    if (delim != "") {
      t = l; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == delim) delim = ""
      continue
    }
    quoted = 0
    if (match(l, HD_DQ) || match(l, HD_SQ)) quoted = 1
    else if (!match(l, HD_BARE)) RSTART = 0
    if (RSTART > 0) {
      d = substr(l, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", d); gsub(/"/, "", d); gsub(SQ, "", d)
      head = substr(l, 1, RSTART - 1)
      hn = tokenize(split_cmd(head), HT, HQ); hw = cmdword_x(HT, hn, 0, 0)
      if (quoted || !kit_heredoc_is_code(hw)) delim = d
    }
    text = text l "\n"
  }
  return text
}
