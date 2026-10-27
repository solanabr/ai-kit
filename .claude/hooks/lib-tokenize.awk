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
#   hd_interp_line(w, l)       what line l of a heredoc body interpreter w runs
#                              becomes in the text the guard reads (hd_strip)
#
# The invariant every caller inherits, and the reason the splitter exists at all:
# a rule may match only a token in ARGUMENT or COMMAND position of a real
# command.  Prose that merely names a gated command — a commit message, an
# issue body, a heredoc document, a test corpus — is data and must never fire.
#
# Its other half: the command the guards inspect is the command the shell runs.
# Two spellings broke that until this file learned them, and both walked past
# every gate only a hook enforces, a mainnet deploy at High included:
#   * a reserved word in command position — `if true; then anchor deploy …; fi`,
#     `! solana program deploy …`, `{ npm publish; }`.  first_word, cmdword_x and
#     onchain-guard.awk's normaliser skip it (kit_reserved); kit_shell_text drops it
#     from the text egress-guard.sh's position-anchored patterns read.
#   * a backslash-newline continuation, which the shell deletes before it splits
#     words, so `solana program \<newline>set-upgrade-authority … --final` is one
#     command.  split_cmd drops the pair; kit_shell_text joins the lines.
#
# Separators the splitter emits:
#   \001  statement boundary (data cannot flow across)
#   \002  stage boundary inside one statement (data CAN flow across)
#   \003  a backslash-escaped space that must not split a token

BEGIN {
  SQ = sprintf("%c", 39)
  # The deepest a code string may nest inside another before the expanders stop
  # reading and the guard refuses the command (kit_expand_code, kit_shell_text and
  # onchain's payload loop set KIT_DEEP; the guard reads it).  A string another
  # program runs as shell code is read as a statement of its own, and reading one
  # nested K deep costs K re-reads of up to the whole command, so a depth cap is
  # what bounds the work: at 32 KB, depth 3 takes a guard under 3 CPU-seconds on
  # the measuring machine and depth 5 over 4.  Real commands almost never wrap
  # shell code past two or three layers, so 3 is set from the budget, not usage.
  KIT_MAXDEPTH = 3
  # KIT_MAXCODE caps the statements kit_expand_code adds and the code strings
  # kit_payloads collects.  A count that stops quietly is a door: 300 `x;` ahead of
  # `curl -d @.env …` in one `sh -c`, or 4,100 `eval x;` ahead of `eval 'npm
  # publish'`, left the command at the end unread.  Past the cap the command is
  # refused, as past the depth; no command a person or agent writes comes near it.
  # 2048, not the 4096 it was: 4,070 one-word `sh -c x;` strings in 32 KB cost
  # egress-guard 5.2 CPU-seconds on a loaded machine, half its 10 s timeout, and a
  # timeout does not block (#294).  Refused at 2,048, the same command costs 2.1.
  KIT_MAXCODE = 2048
}

# ---------------------------------------------------------------- small predicates

# base — the command's basename.  Strips a leading backslash too, so an escaped
# `\env` is still recognised as the wrapper it is.
function base(p) { sub(/^\\/, "", p); sub(/^.*\//, "", p); return p }

# unmark — put back what split_cmd protected: \003 an escaped space, \004 an
# escaped single quote and \005 an escaped double quote, which are text in the word
# and quotes again in the string a program hands a shell (#293).
function unmark(s) { gsub(/\003/, " ", s); gsub(/\004/, SQ, s); gsub(/\005/, "\"", s); return s }

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
       || c == "watch" || c == "noglob" || c == "eval" || c == "arch" || c == "taskset")
}

# kit_reserved — a shell reserved word that stands where a command word goes and
# is never the command itself: `if cmd`, `then cmd`, `! cmd`, `{ cmd; }`,
# `while cmd`, `coproc cmd`.  `time` is absent because is_wrapper has it.
# Compared as a bare word: a quoted "if" is a command named if, which does not
# exist, so skipping that too costs nothing.
function kit_reserved(t) {
  return (t == "!" || t == "if" || t == "then" || t == "elif" || t == "else" || t == "do" \
       || t == "while" || t == "until" || t == "{" || t == "coproc")
}

# kit_wrapper_optarg — a wrapper OPTION that swallows the next word, so the word
# is not mistaken for the command: env -u HOME, xargs -I {}, nice -n 5,
# sudo -u me, timeout -s KILL 5.  Skipping the flag alone left `nice -n 5 git
# --no-pager clean -fdx` with "5" in command position and every git gate silent.
# Moved here from onchain-guard.awk, which had it first and still uses it; only
# callers passing operands=1 to cmdword_x get it there, beside kit_wrapper_operand,
# and so does hd_cmd, the heredoc reader's walk to the command a body feeds.
# An attached value (-n5, --adjustment=5) is one token already.  The spaced GNU
# long forms of the same options (--signal KILL, --adjustment 5, --user me) sit
# beside them and match by prefix, because getopt_long takes an unambiguous
# abbreviation: `nice --adj 5` is `nice --adjustment 5`.  Only options whose
# argument is REQUIRED belong here: `xargs --max-lines 5 cmd` runs `5`, because
# an optional argument has to be attached with `=`.
function kit_wrapper_optarg(b, f) {
  if (b == "env") return (f ~ /^-[uC]$/ || kit_long_arg(f, "unset chdir"))
  if (b == "xargs")
    return (f ~ /^-[ILnPsdEaJRS]$/ || kit_long_arg(f, "max-args max-procs max-chars delimiter arg-file"))
  if (b == "sudo" || b == "doas")
    return (f ~ /^-[ughpCDrtTU]$/ \
         || kit_long_arg(f, "user group prompt host close-from chdir role type command-timeout other-user"))
  if (b == "nice") return (f == "-n" || kit_long_arg(f, "adjustment"))
  if (b == "timeout") return (f ~ /^-[sk]$/ || kit_long_arg(f, "signal kill-after"))
  if (b == "stdbuf") return (f ~ /^-[ioe]$/ || kit_long_arg(f, "input output error"))
  if (b == "exec") return (f == "-a")
  if (b == "time") return (f ~ /^-[fo]$/ || kit_long_arg(f, "format output"))
  if (b == "ionice") return (f ~ /^-[cnpPu]$/ || kit_long_arg(f, "class classdata pid pgid uid"))
  if (b == "watch") return (f ~ /^-[nq]$/ || kit_long_arg(f, "interval equexit"))
  if (b == "flock") return (f ~ /^-[wE]$/ || kit_long_arg(f, "wait timeout conflict-exit-code"))
  if (b == "arch") return (f == "-arch" || f == "-e" || f == "-d")
  return 0
}

# kit_long_arg — f is `--<prefix>` of one of the long option names in opts.  A
# prefix the real program finds ambiguous ends in a usage error, so reading it as
# the option costs nothing.
function kit_long_arg(f, opts,   n, O, i) {
  if (f !~ /^--[A-Za-z]/ || index(f, "=") > 0) return 0
  n = split(opts, O, " ")
  for (i = 1; i <= n; i++) if (index("--" O[i], f) == 1) return 1
  return 0
}

# kit_wrapper_operand — a wrapper taking a POSITIONAL operand before the command
# it runs.  This is the bug that bit twice: skipping a wrapper's OPTIONS alone
# leaves `timeout 5 npx -y evil` with "5" in command position, so the gate never
# sees npx at all.  Only callers passing operands=1 to cmdword_x get this.
#
# Deliberately narrow: one operand, and only where the wrapper's is known.  Skipping
# every non-flag token until something looks like a command would walk past the
# command itself on a wrapper nobody models.  `flock -w 5 f cmd` reaches cmd
# because -w has a row in kit_wrapper_optarg.
function kit_wrapper_operand(w, t) {
  if (w == "timeout" && t ~ /^[0-9]/) return 1
  if (w == "flock" && t !~ /^-/) return 1
  if (w == "taskset" && t !~ /^-/) return 1      # the CPU mask or list
  return 0
}

# ---------------------------------------------------------------- the splitter

# split_cmd — quote-aware split into statements and pipeline stages.  Honours
# SQ..SQ (fully literal) and ".." (literal except $( ) and backticks), keeps
# ${VAR} as one token rather than reading { as a brace group, and turns a command
# substitution into a stage of its own.  A backslash-newline outside SQ..SQ is a
# line continuation and is dropped whole, as the shell drops it: kept, the newline
# landed inside a token, and `git config \<newline>core.hooksPath x` had a key
# no gate recognised.
function split_cmd(s,   i, c, c2, st, sp, out, j, pk, np, lastk, lastp, dbr) {
  out = ""; sp = 0; st[0] = "code"; np = 0; lastp = 0; dbr = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1); c2 = substr(s, i, 2)
    if (st[sp] == "sq") { out = out c; if (c == SQ) sp--; continue }
    if (st[sp] == "dq") {
      if (c == "\\" && i < length(s)) {
        i++; c = substr(s, i, 1)
        if (c == "\"") out = out "\005"; else if (c != "\n") out = out c
        continue
      }
      if (c2 == "$(") { out = out " $__X__\002 "; st[++sp] = "code"; pk[++np] = "$"; i++; continue }
      if (c == "`")   { j = kit_bt_end(s, i); out = out " $__X__\002 " split_cmd(kit_bt_body(substr(s, i + 1, j - i - 1))) "\002"; i = j; continue }
      if (c == "\"")  { sp--; out = out c; continue }
      out = out c; continue
    }
    if (c == "\\" && i < length(s)) {
      i++; c = substr(s, i, 1)
      if (c == "\n") continue
      # An escaped blank or quote is text in this word: marked, so tokenize keeps
      # it out of the quoting, and unmark puts it back.  As a bare quote it opened
      # a quoted run of its own: `sh -c "sh -c \"npm publish\""` read wrong.
      if (c == " ") out = out "\003"; else if (c == SQ) out = out "\004"
      else if (c == "\"") out = out "\005"; else out = out c
      # An escaped `$` opens no $'…' and pairs into no `$$`: the empty "" keeps
      # tokenize from reading either.
      if (c == "$" && substr(s, i + 1, 1) ~ /[$\047]/) out = out "\"\""
      continue
    }
    # A comment runs to the newline, and nothing in it quotes: read as text, the
    # quote in `echo hi # it's` or `# $'\'` held every line after it (#301).
    # Not inside `[[ … ]]`, where `(` and `|` are a regex's and `#` follows them
    # as text (`[[ x =~ (#) ]]`); and after a `)` only when it closed a plain
    # subshell (lastk "p"): `$(true)#`, `$((1))#` and `<(true)#` go on as one word.
    if ((c == "[" || c == "]") && st[sp] == "code") dbr = kit_dbr(s, i, dbr)
    if (c == "#" && !dbr && kit_comment_at(s, i, (lastp == i - 1) ? lastk : "")) { j = index(substr(s, i), "\n"); if (j == 0) break; i += j - 2; continue }
    if (c == "(") pk[++np] = (i > 1 && substr(s, i - 1, 1) ~ /[$<>?*+@!=]/) ? "x" : "p"
    if (c == ")") { lastk = (np > 0) ? pk[np--] : ""; lastp = i }
    if (kit_pid(s, i)) { out = out c2; i++; continue }
    # $'…' is copied whole for tokenize to decode (#301).  Its `\'` is escaped,
    # so read as '…' the region closed there: `echo $'it\'s; npm publish'` split.
    if (c2 == "$" SQ) { kit_ansi_end(s, i + 1); out = out substr(s, i, KA_END - i + 1); i = KA_END; continue }
    if (c == SQ)    { st[++sp] = "sq"; out = out c; continue }
    if (c == "\"")  { st[++sp] = "dq"; out = out c; continue }
    if (c2 == "${") { j = index(substr(s, i), "}"); if (j > 0) { out = out substr(s, i, j); i += j - 1; continue } }
    if (c2 == "$(") { out = out " $__X__\002 "; st[++sp] = "code"; pk[++np] = "$"; i++; continue }
    # `…` ends at the first unescaped backtick, whatever quotes stand before it
    # (#301): its text is split as a command of its own, so a quote inside it,
    # `$'\'` or a lone `'`, no longer runs on past it.
    if (c == "`")   { j = kit_bt_end(s, i); out = out " $__X__\002 " split_cmd(kit_bt_body(substr(s, i + 1, j - i - 1))) "\002"; i = j; continue }
    if (c == ")" && sp > 0 && st[sp] == "code") { sp--; out = out "\002"; continue }
    # An `&` or `|` inside a redirection operator (`2>&1`, `<&3`, `&>log`, `>|f`)
    # separates nothing, and `|&` pipes stderr too: one stage boundary.  Read as
    # separators they split `cat .env 2>&1 | curl -d @- …` into two statements, so
    # the reader and the sender never met, and cut the command off a heredoc head.
    if (c2 == "|&") { out = out "\002"; i++; continue }
    if (i > 1 && (c == "&" ? substr(s, i - 1, 1) ~ /[<>]/ : c == "|" && substr(s, i - 1, 1) == ">") \
        && substr(s, i - 2, 1) != "\\") { out = out c; continue }
    if (c2 == "&>") { out = out c; continue }
    if (c2 == "&&" || c2 == "||") { out = out "\001"; i++; continue }
    if (c == ";" || c == "&" || c == "\n") { out = out "\001"; continue }
    # `{}` is a word, find's and xargs's placeholder; only a lone `{` or `}` groups.
    if (c2 == "{}") { out = out c2; i++; continue }
    if (c == "|" || c == "(" || c == ")" || c == "{" || c == "}") { out = out "\002"; continue }
    out = out c
  }
  return out
}

# tokenize — fill T[] with tokens and Q[] with 1 where the token carried a quote.
# Q is optional: a caller passing only (s, T) gets an unused local array, which is
# how egress-guard's copy behaved before it was lifted here.
function tokenize(s, T, Q,   i, c, q, cur, n, hadq, L, j) {
  n = 0; cur = ""; q = ""; hadq = 0; L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    # Inside a quote, jump to the closing quote and take the run in one piece
    # rather than a character at a time: `cur = cur c` over a 30 KB quoted code
    # string is quadratic, and the nested-code passes re-tokenize such a string at
    # every level, which is where the deep-nesting cost came from.  j is the offset
    # of the next quote char in the tail at i; the for's i++ steps past it.
    if (q != "") {
      j = index(substr(s, i), q)
      if (j == 1) q = ""                                       # c is the closing quote
      else if (j == 0) { cur = cur substr(s, i); i = L }       # unterminated: take the rest
      else { cur = cur substr(s, i, j - 1); q = ""; i += j - 1 }
      continue
    }
    # $'…' is taken decoded, as bash runs it (kit_ansi, #301); `$$` is the PID.
    if (kit_pid(s, i)) { cur = cur "$$"; i++; continue }
    if (c == "$" && substr(s, i + 1, 1) == SQ) { cur = cur kit_ansi(s, i + 1); i = KA_END; hadq = 1; continue }
    if (c == SQ || c == "\"") { q = c; hadq = 1; continue }
    if (c == " " || c == "\t") { if (cur != "" || hadq) { T[++n] = cur; Q[n] = hadq; cur = ""; hadq = 0 } ; continue }
    cur = cur c
  }
  if (cur != "" || hadq) { T[++n] = cur; Q[n] = hadq }
  return n
}

# first_word — index of the first token that is neither a VAR=value assignment
# nor a reserved word (`if FOO=1 cmd`, `! cmd`, `then cmd`).
function first_word(T, n,   i, r) {
  i = 1
  while (i <= n) {
    if (T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || kit_reserved(T[i])) i++
    else if ((r = kit_redir(T, n, i)) > 0) i += r
    else break
  }
  return i
}

# kit_redir — how many words the redirection at T[i] spans: 1 with its target
# attached (`2>&1`, `>log`, `<<EOF`), 2 when the target is the next word (`> log`),
# 0 when T[i] is no redirection.  bash takes a redirection anywhere among a
# command's words, ahead of the command word too: `2>/dev/null anchor deploy …` is
# the deploy.  Read as the command word, one hid it from every guard (#287), and
# read as an operand, one made `bash 2>&1 <<'EOF'` a shell running a script file
# with the body as its data.
function kit_redir(T, n, i) {
  if (T[i] !~ /^([0-9]+|&)?(<<<|<<-?|<>|>>|>\||[<>]&?)/) return 0
  return (T[i] ~ /^([0-9]+|&)?(<<<|<<-?|<>|>>|>\||[<>]&?)$/ && i < n) ? 2 : 1
}

# kit_sep — the next statement separator in s, as match(s, /(\|\||&&|\$\(|[;&|()])/)
# finds it (RSTART, RLENGTH; 0 when there is none), except that the `&` of `2>&1`,
# `<&3` and `&>log` and the `|` of `>|f` separate nothing and `|&` is one pipe, as
# split_cmd reads them.  Split there, `2>&1 anchor deploy …` left `1` in command
# position for the anchored patterns.
function kit_sep(s,   off, p, c, q) {
  off = 0
  while (match(substr(s, off + 1), /(\|\||&&|\$\(|[;&|()])/)) {
    p = off + RSTART; c = substr(s, p, RLENGTH)
    q = (p > 1) ? substr(s, p - 1, 1) : ""
    if (((c == "&" && (q ~ /[<>]/ || substr(s, p + 1, 1) == ">")) || (c == "|" && q == ">")) \
        && (p < 3 || substr(s, p - 2, 1) != "\\")) { off = p; continue }
    if (c == "|" && substr(s, p + 1, 1) == "&") RLENGTH = 2
    RSTART = p; return p
  }
  RSTART = 0; RLENGTH = -1; return 0
}

# kit_unq — command word w with its quotes and backslashes removed, as the shell
# removes them before it looks the command up: `"npm" publish`, `n\pm publish` and
# `'anchor' deploy` run npm and anchor, and the anchored patterns, which read the
# word as written, met nothing (#293).  w comes back unchanged when its quotes do
# not close inside it (a quoted run that spans words) or the result is no plain
# command name, so a quoted `;` or blank never becomes a separator.  With arg set
# it reads any other word of the command, where `=` and `,` are plain too:
# `npm "publish"` and `git push '--force'` hid the publish and the push (#297).
# An ANSI-C quoted part is decoded (kit_ansi, #301): `$'git' push` runs git.
function kit_unq(w, arg,   o, i, c, q, L) {
  if (w !~ /["\047\\]/) return w
  o = ""; q = ""; L = length(w)
  for (i = 1; i <= L; i++) {
    c = substr(w, i, 1)
    if (q == SQ) { if (c == SQ) q = ""; else o = o c; continue }
    if (q == "\"") {
      if (c == "\\" && i < L && index("\"\\$`", substr(w, i + 1, 1))) { o = o substr(w, ++i, 1); continue }
      if (c == "\"") q = ""; else o = o c
      continue
    }
    if (c == "\\" && i < L) { o = o substr(w, ++i, 1); continue }
    if (kit_pid(w, i)) { o = o "$$"; i++; continue }
    if (c == "$" && substr(w, i + 1, 1) == SQ) { o = o kit_ansi(w, i + 1); if (KA_OPEN) return w; i = KA_END; continue }
    if (c == SQ || c == "\"") { q = c; continue }
    o = o c
  }
  if (q != "") return w
  if (arg) return (o ~ /^[A-Za-z0-9_.\/+${}~:@%=,-]+$/) ? o : w
  return (o ~ /^[A-Za-z0-9_.\/+${}~:@%-]+$/) ? o : w
}

# kit_ansi — the ANSI-C quoted part $'…' whose opening quote is at p in s, decoded
# as bash decodes it before it runs the word (#301): `$'git' push --force`,
# `$'\x67it' push --force` and `$'\147it' push --force` all run git push --force,
# and read with the `$` and the escapes kept they met no gate.  KA_END is left at
# the closing quote, or at the end of s with KA_OPEN set when none closes it.
#
# The region ends where bash's reader ends it: a backslash escapes the next
# character, `\'` included, so `$'it\'s'` is one quoted part.  Inside it the
# escapes bash supports are decoded: \a \b \e \E \f \n \r \t \v \\ \' \" \?,
# \nnn octal, \xHH, \uHHHH, \UHHHHHHHH and \cx; any other is kept as written.  A
# NUL ends the string, as it ends the C string bash builds.  Only the verdicts
# depend on the result, so a byte past ASCII, and the \001-\005 bytes the readers
# use as marks, all come back as KA_HI, \006: one character that matches no gated
# word and that every awk reads.  A lone byte past 127 is no character in a UTF-8
# locale, and macOS awk stops with an error on one.
function kit_ansi(s, p,   b, o, j, c, v) {
  if (KA_HI == "") kit_ansi_init()
  b = substr(s, p + 1, kit_ansi_end(s, p))
  o = ""
  while ((j = index(b, "\\")) > 0 && j < length(b)) {
    o = o substr(b, 1, j - 1); c = substr(b, j + 1, 1); b = substr(b, j + 2)
    v = -1; KA_N = 0
    if (c ~ /[0-7]/) { b = c b; v = kit_ansi_num(b, 3, 8) % 256 }
    else if (c == "x" || c == "u" || c == "U") {
      v = kit_ansi_num(b, (c == "x") ? 2 : (c == "u") ? 4 : 8, 16)
      if (!KA_N) v = -1                                # `\x` with no digit is kept
    }
    else if (c == "c" && b != "") {                    # \cx is control-x; \c\\ is control-\
      c = substr(b, 1, 1); b = substr(b, 2)
      if (c == "\\" && substr(b, 1, 1) == "\\") b = substr(b, 2)
      v = (c == "?") ? 127 : (index(KA_ORD, toupper(c)) + 31) % 32
    }
    else if (c in KA_ESC) v = KA_ESC[c]
    b = substr(b, KA_N + 1)
    if (v == 0) return o
    o = o ((v < 0) ? "\\" c : (v <= 5 || v > 126) ? KA_HI : sprintf("%c", v))
  }
  return o b
}
# kit_pid — a `$$` at i in s that the readers take as one unit, the PID, before
# they look for $'…': in `$$'\' ; npx -y evil ; echo 'x'` bash reads `$$` and then
# a plain '…', where a backslash escapes nothing, so the npx runs.  Read as `$` and
# `$'\' ; …'`, the npx was quoted.  Taken only where a `$` or a quote follows, the
# one place the pairing decides anything, so `$$(…)` and `$${…}` read as before.
function kit_pid(s, i) { return substr(s, i, 2) == "$$" && substr(s, i + 2, 1) ~ /[$\047]/ }
# kit_bt_end — the closing backtick of the `…` opened at p in s, or past the end
# of s.  bash looks for it skipping only backslash pairs: no quote counts there,
# so `echo $'\'` closes at its second backtick and the `;` after it separates.
function kit_bt_end(s, p,   e) {
  match(substr(s, p + 1), /^([^`\\]|\\.)*/); e = p + RLENGTH + 1
  return (substr(s, e, 1) == "`") ? e : length(s) + 1
}
# kit_bt_body — the text of a `…` as bash runs it: \`, \\ and \$ lose their backslash.
function kit_bt_body(b,   o, j, c) {
  o = ""
  while ((j = index(b, "\\")) > 0) {
    c = substr(b, j + 1, 1)
    o = o substr(b, 1, j - 1) ((c == "`" || c == "\\" || c == "$") ? c : "\\" c)
    b = substr(b, j + 2)
  }
  return o b
}
# kit_comment_at — the `#` at i in s starts a comment: it begins a word, after
# the start, an unescaped blank or newline, or an operator character.  After a
# `)` it does only when that `)` closed a plain subshell or group, which the
# caller knows and passes as pk "p": the `)` of `$( )`, `$(( ))`, `<( )` or an
# extglob ends no word, so `$(true)#` is one word and `$(true)#; npx` runs npx.
# After a `(` it does unless the `(` opens an extglob.
function kit_comment_at(s, i, pk,   p, k) {
  if (i == 1) return 1
  p = substr(s, i - 1, 1)
  if (p !~ /[ \t\n;&|()]/) return 0
  if (p == ")" && pk != "p") return 0
  if (p == "(" && substr(s, i - 2, 1) ~ /[$<>?*+@!=]/) return 0
  for (k = i - 2; k >= 1 && substr(s, k, 1) == "\\"; k--) ;
  return (i - 2 - k) % 2 == 0
}
# kit_dbr — whether the reader is inside `[[ … ]]` after the `[` or `]` at i in
# s, from d before it.  Only a word `[[` opens one and a word `]]` closes it.
function kit_dbr(s, i, d,   b, a) {
  b = (i == 1) ? " " : substr(s, i - 1, 1); a = substr(s, i + 2, 1)
  if (substr(s, i, 2) == "[[" && b ~ /[ \t\n;&|(!{]/ && a ~ /[ \t\n]/) return 1
  if (substr(s, i, 2) == "]]" && b ~ /[ \t\n]/ && (a == "" || a ~ /[ \t\n;&|)]/)) return 0
  return d
}
# kit_ansi_end — the length of what $'…' quotes, its opening quote at p in s.
# Sets KA_END and KA_OPEN as kit_ansi describes, without decoding.
function kit_ansi_end(s, p) {
  match(substr(s, p + 1), /^([^\\\047]|\\.)*/)
  KA_END = p + RLENGTH + 1; KA_OPEN = (substr(s, KA_END, 1) != SQ)
  if (!KA_OPEN) return RLENGTH
  KA_END = length(s); return KA_END - p
}
# kit_ansi_num — the value of the up to max base-b digits t starts with; KA_N is
# how many there were.
function kit_ansi_num(t, max, b,   v, d) {
  v = 0
  for (KA_N = 0; KA_N < max; KA_N++) {
    d = substr(t, KA_N + 1, 1)
    if (d == "" || (d = index(substr("0123456789abcdef", 1, b), tolower(d))) == 0) break
    v = v * b + d - 1
  }
  return v
}
function kit_ansi_init(   j) {
  KA_HI = sprintf("%c", 6); KA_ORD = ""
  for (j = 32; j < 127; j++) KA_ORD = KA_ORD sprintf("%c", j)
  KA_ESC["a"] = 7; KA_ESC["b"] = 8; KA_ESC["e"] = 27; KA_ESC["E"] = 27; KA_ESC["f"] = 12
  KA_ESC["n"] = 10; KA_ESC["r"] = 13; KA_ESC["t"] = 9; KA_ESC["v"] = 11
  KA_ESC["\\"] = 92; KA_ESC[SQ] = 39; KA_ESC["\""] = 34; KA_ESC["?"] = 63
}

# kit_lead_redir — kit_redir for the normalisers that rewrite a statement's text,
# except a heredoc operator: hd_strip reads the opener off that text, so it stays.
function kit_lead_redir(A, n, i) { return (A[i] ~ /^[0-9]*<<([^<]|$)/) ? 0 : kit_redir(A, n, i) }

# cmdword_x — the real command word, past leading assignments and wrappers.
# Sets CWI to its index.  Returns "" when there is none.
#
#   reskip    1: re-skip VAR=value assignments after each wrapper, so
#                `env FOO=1 cat x` yields "cat".  0: skip them once at the front
#                only, so the same command yields "FOO=1" and the path lands in
#                argument position instead.  Both shipped; both are preserved.
#   operands  1: also skip a wrapper's positional operand (kit_wrapper_operand)
#                and the word an option of it swallows (kit_wrapper_optarg).
#
# CWI is left untouched when reskip is 1 and nothing was found, because that copy
# never assigned it there and a caller may still be reading the previous value.
#
# A reserved word behind a wrapper is skipped as well: bash's `time` is a keyword
# that takes `!` after it (`time ! cmd`), and on any other wrapper the word would
# name a command that does not exist.  Never read past n: tokenize leaves the
# previous stage's tokens above it.
function cmdword_x(T, n, reskip, operands,   ci, w, r) {
  ci = first_word(T, n)
  while (ci <= n) {
    while (ci <= n) {
      if (kit_reserved(T[ci]) || (reskip && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) ci++
      else if ((r = kit_redir(T, n, ci)) > 0) ci += r
      else break
    }
    if (ci > n) { if (reskip) return ""; break }
    w = base(T[ci])
    if (!kit_wrapper(w)) { CWI = ci; return w }
    ci++
    while (ci <= n && T[ci] ~ /^-/) {
      if (operands && ci < n && kit_wrapper_optarg(w, T[ci])) ci++
      ci++
    }
    while (ci <= n && (r = kit_redir(T, n, ci)) > 0) ci += r
    if (operands && ci <= n && kit_wrapper_operand(w, T[ci])) ci++
  }
  if (!reskip) CWI = n + 1
  return ""
}

# kit_plain — t is one word the shell reads back as itself: no blank, quote,
# operator, expansion or glob.  The set is git's own test for whether a command
# needs a shell (run-command.c, prepare_shell_cmd).  \003, split_cmd's mark for an
# escaped space, is a blank here: `watch npm\ publish` hands sh "npm publish".
function kit_plain(t) { return (t != "" && t !~ /[|&;<>()$`\\"\047 \t\n\003\004\005*?#~=%[]/) }

# kit_shq — t as one shell word: itself when plain, single-quoted otherwise.
function kit_shq(t,   n, P, i, s) {
  if (kit_plain(t)) return t
  n = split(t, P, /\047/); s = P[1]
  for (i = 2; i <= n; i++) s = s "\047\\\047\047" P[i]
  return "\047" s "\047"
}

# kit_join — T[i..n] joined by spaces, each word quoted as one (kit_shq) when q is set.
function kit_join(T, i, n, q,   s) {
  s = ""
  for (; i <= n; i++) s = s (s == "" ? "" : " ") (q ? kit_shq(T[i]) : T[i])
  return s
}

# kit_git_optarg — a git-level option, ahead of the subcommand, that takes the next
# word.  egress-guard.awk's git_global_operand reads this table too, and says how
# each entry was verified.
function kit_git_optarg(o) {
  return (o == "-C" || o == "-c" || o == "--git-dir" || o == "--work-tree" \
       || o == "--namespace" || o == "--attr-source" || o == "--super-prefix" \
       || o == "--config-env" || o == "--shallow-file")
}

# kit_git_code — git at T[ci] running a code string.  `rebase` with --exec or -x
# returns the index of the first, KIC_CODE holding each one a line apiece: the
# sequencer runs every one with sh -c after a commit.  `submodule foreach` returns
# the index of CMD, with KIC_CODE set as kit_inline_code describes, or minus that
# index when CMD is a plain word, which git runs as a command.  0 otherwise.
function kit_git_code(T, n, ci,   i, o, v, p) {
  for (i = ci + 1; i <= n && T[i] ~ /^-/; i++) if (kit_git_optarg(T[i])) i++
  if (i > n) return 0
  if (T[i] == "submodule") {
    i++; while (i <= n && T[i] ~ /^-/) i++
    if (i > n || T[i] != "foreach") return 0
    for (i++; i <= n && T[i] ~ /^-/; i++) if (T[i] == "--") { i++; break }
    if (i > n) return 0
    if (kit_plain(T[i])) return -i
    KIC_CODE = T[i] (i < n ? " " kit_join(T, i + 1, n, 1) : "")
    return i
  }
  if (T[i] != "rebase") return 0
  p = 0
  for (i++; i <= n && T[i] != "--"; i++) {
    o = T[i]
    if (o ~ /^-[iqvnfkmr]*x$/ || kit_long_arg(o, "exec")) { if (i == n) break; v = T[++i] }
    else if (o ~ /^-[iqvnfkmr]*x./) { v = o; sub(/^-[iqvnfkmr]*x/, "", v) }
    else if (o ~ /^--ex(ec?)?=/) { v = o; sub(/^[^=]*=/, "", v) }
    else continue
    KIC_CODE = KIC_CODE (p ? "\n" : "") v
    if (!p) p = i
  }
  return p
}

# kit_env_split — env's option at T[ci] is -S or --split-string, whose STRING env
# splits into words and reads, with the words after it, as arguments of its own.
# Sets KIC_CODE to that env command line and returns 1.  A STRING of one plain word
# needs no splitting: the walk reads it where it stands.
function kit_env_split(T, n, ci,   o, s, j, W, nw, k) {
  o = T[ci]; j = ci + 1
  if (o ~ /^-[iv0]*S$/ || kit_long_arg(o, "split-string")) { if (ci == n) return 0; s = T[j++] }
  else if (o ~ /^-[iv0]*S./) { s = o; sub(/^-[iv0]*S/, "", s) }
  else if (o ~ /^--s[a-z-]*=/ && kit_long_arg(substr(o, 1, index(o, "=") - 1), "split-string")) s = substr(o, index(o, "=") + 1)
  else return 0
  if (kit_plain(s)) return 0
  nw = tokenize(unmark(s), W); KIC_CODE = "env"
  for (k = 1; k <= nw; k++) KIC_CODE = KIC_CODE " " kit_shq(W[k])
  for (k = j; k <= n; k++) KIC_CODE = KIC_CODE " " kit_shq(T[k])
  return 1
}

# kit_inline_code — index of the first word of the code a stage runs through a
# shell, past any wrapper in front; 0 when it runs none.  The code is T[p], or
# KIC_CODE when that is set, for the programs that build it from more than one word.
# Its escaped spaces (\003) are restored where it is read as code, since the shell
# reading it splits there: `sh -c npm\ publish` runs npm publish.
#
#   sh -c CODE, bash -lc CODE        CODE.  `bash ./x.sh "a; b"` is 0: that string
#                                    is the script's argument.
#   flock FILE -c CODE               CODE, which flock runs with $SHELL -c.
#   eval WORD…, watch WORD…          the words joined by spaces, the string each hands
#                                    to a shell: `watch echo 'a; npm publish'` runs the
#                                    publish.  watch -x runs them as a command instead.
#   git submodule foreach CMD ARG…   CMD, then each ARG quoted as the one word it was:
#                                    git runs `sh -c 'CMD "$@"' CMD ARG…`.
#   git rebase --exec CODE, -x CODE  every CODE, a line each.
#   env -S STRING ARG…               env again, with STRING's words and each ARG.
#   su … -c CODE                     CODE.
#   find … -exec CMD ARG… ;          CMD and its words, as a command, a line for
#                                    each -exec, -execdir, -ok and -okdir.
#
# Given words that need no shell (kit_plain), eval, watch, foreach and env -S run
# them as a command, so the walk goes on into it: a chain of `eval eval … npm
# publish` is read in one pass, where a code string per eval would cost a pass
# each, quadratic in the chain.  Where that walk ends on a command behind eval or
# foreach, the code is the words from there, because kit_unwrap stops at both and
# the anchored gates need a statement start.  np is the last word that is not
# plain, found once: asked again at each eval, the chain was quadratic after all.
function kit_inline_code(T, n,   ci, w, i, c, need, np, p, s, j, r) {
  KIC_CODE = ""; need = 0
  for (np = n; np > 0 && kit_plain(T[np]); np--) ;
  ci = first_word(T, n)
  while (ci <= n) {
    w = base(T[ci])
    if (w == "eval" || w == "watch") {
      i = ci + 1; c = 1
      if (w == "watch")
        for (; i <= n && T[i] ~ /^-/; i++) {
          if (T[i] == "--") { i++; break }
          if (T[i] ~ /^-[A-Za-z]*x[A-Za-z]*$/ || kit_long_arg(T[i], "exec")) c = 0
          else if (i < n && kit_wrapper_optarg(w, T[i])) i++
        }
      if (i > n) return 0
      if (c && i <= np) { KIC_CODE = kit_join(T, i, n, 0); return i }
      if (w == "eval") need = 1
      ci = i; continue
    }
    if (is_shell(w)) {
      c = 0
      for (i = ci + 1; i <= n; i++) {
        if (T[i] == "-o" || T[i] == "+o") { i++; continue }
        if (T[i] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { c = 1; continue }
        if (T[i] ~ /^[-+]/) continue
        return c ? i : 0
      }
      return 0
    }
    # su -c CODE runs CODE in the target user's shell.  find -exec CMD … runs CMD as
    # a command, so each -exec's command is a line of KIC_CODE: `find . -exec sh -c
    # 'npm publish' {} +` and `find . -exec true \; -exec npm publish {} \;` were
    # arguments to find (#293).
    if (w == "su") {
      for (i = ci + 1; i <= n; i++) {
        if (T[i] == "--command" || T[i] ~ /^-[A-Za-z]*c$/) return (i < n) ? i + 1 : 0
        if (T[i] ~ /^--command=/) { KIC_CODE = substr(T[i], 11); return i }
      }
      return 0
    }
    if (w == "find") {
      p = 0
      for (i = ci + 1; i <= n; i++) {
        if (T[i] !~ /^-(exec|execdir|ok|okdir)$/) continue
        s = ""
        for (j = i + 1; j <= n && T[j] != ";" && T[j] != "+"; j++) s = s (s == "" ? "" : " ") kit_shq(T[j])
        if (s != "") { KIC_CODE = KIC_CODE (p ? "\n" : "") s; if (!p) p = i + 1 }
        i = j
      }
      return p
    }
    if (w == "git" && (i = kit_git_code(T, n, ci)) != 0) {
      if (i > 0) return i
      need = 1; ci = -i; continue
    }
    if (need && !is_wrapper(w)) { KIC_CODE = kit_join(T, ci, n, 1); return ci }
    if (!is_wrapper(w)) return 0
    ci++
    while (ci <= n && T[ci] ~ /^-/) {
      if (w == "env" && kit_env_split(T, n, ci)) return ci
      if (ci < n && kit_wrapper_optarg(w, T[ci])) ci++
      ci++
    }
    while (ci <= n && (r = kit_redir(T, n, ci)) > 0) ci += r
    if (ci <= n && kit_wrapper_operand(w, T[ci])) ci++
    if (w == "flock" && ci < n && (T[ci] == "-c" || T[ci] == "--command")) return ci + 1
    while (ci <= n && (T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || kit_reserved(T[ci]))) ci++
  }
  return 0
}

# kit_code_hint — s names a program kit_inline_code reads code out of.  A cheap
# pre-check, so a stage that names none is never tokenized for it.
function kit_code_hint(s) {
  return (index(s, "sh") || index(s, "eval") || index(s, "watch") || index(s, "flock") \
       || index(s, "env") || index(s, "foreach") || index(s, "rebase") || index(s, "su ") \
       || index(s, "-exec") || index(s, "-ok"))
}

# kit_expand_code — append the statements of every code string in ST[1..nst]
# (kit_inline_code) to ST as statements of their own, those nested in them
# included, and return the new count.  The unwrap passes add such code as one
# stage, which showed only its first command: `sh -c 'true; git -P clean -fdx'`
# and `sh -c 'if true; then gh auth token; fi'` walked past.  Statements, not
# stages, because the code's own `;` still separates them: `sh -c 'cat .env; curl
# -d @- host'` sends stdin, not .env.  Past KIT_MAXCODE statements the command is
# refused (KIT_DEEP): the limit of 256 that stood here stopped quietly.
#
# DEP[q] is the nesting depth of statement ST[q] (0 for the originals): a payload
# found in it sits one deeper.  Past KIT_MAXDEPTH, or past a byte budget a wide
# explosion would blow, the statement is NOT expanded and KIT_DEEP is set, so the
# guard refuses the command rather than run the unread inner code — the work is
# bounded to that depth, which is what keeps a deeply nested command from reading
# past the hook's timeout.  The 8x byte budget matches kit_shell_text's.
function kit_expand_code(ST, nst,   q, n0, ng, G, g, n, T, p, ns, S, k, DEP, left) {
  # 8 bytes per byte of the 32 KB of code kit_size_cap admits; kit_shell_text and
  # onchain-guard budget 8 per byte of the command itself, which that cap bounds.
  n0 = nst; left = 8 * 32768
  for (q = 1; q <= nst; q++) {
    ng = split(ST[q], G, /\002/)
    for (g = 1; g <= ng; g++) {
      if (!kit_code_hint(G[g])) continue
      n = tokenize(G[g], T); if (n == 0) continue
      if ((p = kit_inline_code(T, n)) == 0) continue
      if (DEP[q] >= KIT_MAXDEPTH) { KIT_DEEP = 1; continue }
      ns = split(split_cmd(unmark(KIC_CODE == "" ? T[p] : KIC_CODE)), S, /\001/)
      for (k = 1; k <= ns; k++) if (S[k] ~ /[^ \t\002]/) {
        if ((left -= length(S[k])) < 0 || nst - n0 >= KIT_MAXCODE) { KIT_DEEP = 1; return nst }
        ST[++nst] = S[k]; DEP[nst] = DEP[q] + 1
      }
    }
  }
  return nst
}

# kit_payloads — append to P each code string kit_inline_code finds in text, and
# return the new count.  Not recursive: a caller reading each P[k] the same way
# reaches the code nested in it.  Past KIT_MAXCODE the command is refused
# (KIT_DEEP): 32 KB holds 4,681 `eval x;`, so the quiet stop at 4096 that stood
# here let a decoy run hide the code string that mattered.
function kit_payloads(text, P, np,   ns, S, k, ng, G, g, n, T, p) {
  if (!kit_code_hint(text)) return np
  ns = split(split_cmd(text), S, /\001/)
  for (k = 1; k <= ns; k++) {
    ng = split(S[k], G, /\002/)
    for (g = 1; g <= ng; g++) {
      if (!kit_code_hint(G[g])) continue
      n = tokenize(G[g], T); if (n == 0) continue
      if (!(p = kit_inline_code(T, n))) continue
      if (np >= KIT_MAXCODE) { KIT_DEEP = 1; return np }
      P[++np] = unmark((KIC_CODE == "") ? T[p] : KIC_CODE)
    }
  }
  return np
}

# ---------------------------------------------------------------- heredocs

# kit_hd_delim — the delimiter word at s, which begins at a `<<` an operator scan
# found.  bash reads the whole word, quote-removes it, and does NOT expand the body
# if ANY part of the word was quoted (a single quote, a double quote, or a
# backslash).  Every reader used to take the delimiter from a regex that stopped at
# the first non-identifier byte, so a quote inside the word (`<<E'O'F`), a dash or
# dot (`<<END-OF`, `<<END.TXT`), or an unquoted run after a quoted one (`<<"EOF"x`)
# produced a truncated delimiter that no body line ever matched: the body ran away
# and swallowed every command after it, a mainnet deploy at High among them.  This
# reads the word the way bash's tokenizer does.  Sets:
#   KHD_DELIM   the quote-removed delimiter
#   KHD_QUOTED  1 when the body is NOT expanded (any part of the word was quoted)
#   KHD_DASH    1 for `<<-`, which strips leading TABS from the body and the
#               terminator line (only tabs, and only with the dash — measured)
#   KHD_LEN     bytes of s consumed, the operator through the end of the word, so a
#               caller can read what follows the delimiter (`cat <<EOF | sh`)
# Returns 1 when s opens a heredoc, 0 when it does not.  As every reader always has,
# a word whose first quote-removed character is not [A-Za-z_] is treated as no
# opener: that keeps the verdicts on `(( a << b ))` and `(( a << 2 ))` arithmetic,
# where `<<` is a left shift, exactly where they were, and confines this change to
# the shapes above.  The caller's operator scan has already checked that this `<<`
# is outside quotes and comments and is not a `<<<` here-string.
function kit_hd_delim(s,   i, L, c, delim, quoted, dash, st, j) {
  if (substr(s, 1, 2) != "<<") { KHD_LEN = 0; return 0 }
  i = 3; dash = 0
  if (substr(s, 3, 1) == "-") { dash = 1; i = 4 }
  L = length(s)
  while (i <= L && (substr(s, i, 1) == " " || substr(s, i, 1) == "\t")) i++
  # The word is built from whole runs, never a byte at a time: appending a byte to
  # a growing string copies it, and a 30 KB delimiter built that way cost seconds.
  delim = ""; quoted = 0; st = i
  while (i <= L) {
    c = substr(s, i, 1)
    if (c == SQ) {                                   # '…' is literal and quotes the body
      delim = delim substr(s, st, i - st); quoted = 1
      j = i + 1; while (j <= L && substr(s, j, 1) != SQ) j++
      delim = delim substr(s, i + 1, j - i - 1); i = j + 1; st = i; continue
    }
    if (c == "\"") {                                 # "…" too; \" \\ \$ \` are its escapes
      delim = delim substr(s, st, i - st); quoted = 1
      j = i + 1; st = j
      while (j <= L && (c = substr(s, j, 1)) != "\"") {
        if (c == "\\" && j < L && index("\"\\$`", substr(s, j + 1, 1))) {
          delim = delim substr(s, st, j - st); st = j + 1; j += 2; continue
        }
        j++
      }
      delim = delim substr(s, st, j - st); i = j + 1; st = i; continue
    }
    if (c == "\\") {                                 # \x outside quotes is x, and quotes
      delim = delim substr(s, st, i - st) substr(s, i + 1, 1); quoted = 1
      i += 2; st = i; continue
    }
    # An unquoted word character.  The word ends at an unquoted blank or a shell
    # metacharacter, as bash ends a redirection target word.  A `\r` is NOT one:
    # bash keeps it, so a CRLF line's `cat <<EOF` has the delimiter `EOF\r` and the
    # body ends at the line `EOF\r`.  Stopping at it left a delimiter no CRLF line
    # matched, and the body ran away over the command bash runs next — a mainnet
    # deploy after `EOF\r` was silent in every guard (measured, on main too).
    if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" \
        || c == "|" || c == "(" || c == ")" || c == "<" || c == ">") break
    i++
  }
  if (i > L + 1) i = L + 1
  delim = delim substr(s, st, i - st)
  if (delim == "" || substr(delim, 1, 1) !~ /[A-Za-z_]/) { KHD_LEN = 0; return 0 }
  KHD_DELIM = delim; KHD_QUOTED = quoted; KHD_DASH = dash; KHD_LEN = i - 1
  return 1
}

# kit_hd_end — does body line l end a heredoc with delimiter delim?  bash compares
# the line to the delimiter exactly; `<<-` first strips leading TABS (only tabs, not
# spaces) from the line.  The readers once trimmed all surrounding whitespace, which
# ended the body one line early on an indented or trailing-space terminator and let a
# second, unterminated heredoc after it swallow a gated command.  A `\r` is left on,
# as bash leaves it, so an `EOF\r` in a body that is otherwise LF does not terminate
# and a CRLF document is copied whole rather than read as commands.
function kit_hd_end(l, delim, dash,   t) {
  t = l
  if (dash) sub(/^\t+/, "", t)
  return (t == delim)
}

# kit_hd_subst — the command substitutions an UNQUOTED heredoc body still runs, as
# statements a guard that anchors on a statement start can read.  bash expands an
# unquoted body, so a `$( … )`, `$(( … ))` or `` ` … ` `` in it runs while the body
# is written — across body lines too, which the per-line reader this replaces missed:
# a `$(` that opened on one line and closed on a later one hid a mainnet deploy from
# onchain-guard.  A quoted body expands nothing and never calls this.  Stateful over a
# body: kit_hd_subst_reset() clears the carry before one begins, kit_hd_subst(l)
# returns the `; $( … )` fragments that CLOSE on line l (an opener still unclosed is
# carried to the next line, bash's body newline becoming a `;` so its statements stay
# separate), and kit_hd_subst_flush() emits an opener the body ended still inside.
# A backtick is rewritten to `$( … )`, the form the existing readers emitted.
#
# Quotes are literal in the body itself — bash expands `it's $(cmd)` — so only a
# backslash escapes there.  Inside `$( … )` the text is a command line again, so a
# `)` inside '…' or "…" closes nothing: read naively, `$(echo ')'; npx -y x)` ended
# at the quoted paren and the fetch after it was never seen.  That quote state
# carries across lines with the rest (KHS_Q).  Text is copied in whole runs, a line
# at a time, not a byte at a time, so the cost stays linear in the body.
function kit_hd_subst_reset() { KHS_IN = 0; KHS_DEPTH = 0; KHS_Q = ""; KHS_BUF = "" }
function kit_hd_subst(l,   out, i, L, c, st) {
  out = ""; L = length(l); st = 1
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1)
    if (KHS_IN == 0) {
      if (c == "\\") { i++; continue }
      if (substr(l, i, 2) == "$(") { KHS_IN = 1; KHS_DEPTH = 1; KHS_Q = ""; KHS_BUF = ""; i++; st = i + 1; continue }
      if (c == "`") { KHS_IN = 2; KHS_BUF = ""; st = i + 1 }
      continue
    }
    if (KHS_IN == 1) {                                # inside $( … ); $(( … )) balances here too
      if (KHS_Q == SQ) { if (c == SQ) KHS_Q = ""; continue }
      if (c == "\\") { i++; continue }
      if (KHS_Q == "\"") { if (c == "\"") KHS_Q = ""; continue }
      # e is $'…', where `\'` closes nothing; `$$` is the PID (#301, kit_pid).
      if (KHS_Q == "e") { if (c == SQ) KHS_Q = ""; continue }
      if (kit_pid(l, i)) { i++; continue }
      if (substr(l, i, 2) == "$" SQ) { KHS_Q = "e"; i++; continue }
      if (c == SQ || c == "\"") KHS_Q = c
      else if (c == "(") KHS_DEPTH++
      else if (c == ")" && --KHS_DEPTH == 0) { out = out "; $(" KHS_BUF substr(l, st, i - st) ")"; KHS_IN = 0 }
      continue
    }
    if (c == "\\") { i++; continue }                  # inside ` … `
    if (c == "`") { out = out "; $(" KHS_BUF substr(l, st, i - st) ")"; KHS_IN = 0 }
  }
  # A body line that ends inside a substitution continues it: a newline separates
  # its commands, so it becomes `;`, but a backslash-newline joins the next line
  # onto this one, as bash joins it (#288).
  if (KHS_IN != 0) {
    if (match(l, /\\+$/) && RLENGTH % 2 == 1) KHS_BUF = KHS_BUF substr(l, st, length(l) - st)
    else KHS_BUF = KHS_BUF substr(l, st) ";"
  }
  return out
}
# A quote still open when the body ends is closed there (#301): the body ends at
# its delimiter whatever it holds, so `$(echo $'\')` or `$(echo ')` left open
# quoted every command after the heredoc in the text the guards read.
function kit_hd_subst_flush(   out) {
  if (KHS_IN == 0) return ""
  out = "; $(" KHS_BUF ((KHS_Q == "e") ? SQ : KHS_Q) ")"; KHS_IN = 0; KHS_Q = ""; return out
}

# kit_hd_ops — the `<<` heredoc operators the shell reads in l, starting in quote
# stack q: KH_P[i] is where the i-th starts and KH_S[i] the stack there; returns
# the count, and leaves the stack at the end of l in KH_QEND.  A `<<` inside '…'
# or "…", or after a # that starts a comment, is text, and `<<<` is a
# here-string: neither opens a body, and nor does one inside `$(( … ))` or `(( … ))`,
# where `<<` is a left shift: read as an opener, `$((a << b))` took `b` for a
# delimiter no line matched and hid every command after it (#288).  `a` on the
# stack is that arithmetic.  hd_strip, kit_shell_text and
# kit-code-size.awk all find openers here, so every reader agrees on what opens a
# body.  Reading any `<<` as an opener let `echo '<<X'` turn every line after it
# into a body nothing normalised or inspected: `git push \<newline>--force`
# after it was silent at High.
function kit_hd_ops(l, q,   i, L, c, top, k) {
  k = 0; L = length(l)
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1); top = substr(q, length(q))
    if (top == "s") { if (c == SQ) q = substr(q, 1, length(q) - 1); continue }
    if (top == "e") { if (c == "\\") i++; else if (c == SQ) q = substr(q, 1, length(q) - 1); continue }
    if (c == "\\") { i++; continue }
    if (top == "b") { if (c == "`") q = substr(q, 1, length(q) - 1); continue }   # as kit_qscan
    if (top == "d") {
      if (c == "\"") q = substr(q, 1, length(q) - 1)
      else if (substr(l, i, 3) == "$((") { q = q "a"; i += 2 }
      else if (substr(l, i, 2) == "$(") { q = q "p"; i++ }
      else if (c == "`") q = q "b"
      continue
    }
    if (kit_pid(l, i)) i++                                 # $$ and $'…', as kit_qscan reads them
    else if (substr(l, i, 2) == "$" SQ) { q = q "e"; i++ }
    else if (c == SQ) q = q "s"
    else if (c == "\"") q = q "d"
    else if (c == "`") q = (top == "b") ? substr(q, 1, length(q) - 1) : q "b"
    else if (substr(l, i, 2) == "((") { q = q "a"; i++ }
    else if (c == "(") q = q "p"
    else if (top == "a" && substr(l, i, 2) == "))") { q = substr(q, 1, length(q) - 1); i++ }
    else if (c == ")") { if (top == "p") q = substr(q, 1, length(q) - 1) }
    else if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t;&|(]/)) break
    else if (top == "a") continue
    else if (substr(l, i, 3) == "<<<") i += 2
    else if (substr(l, i, 2) == "<<") { KH_P[++k] = i; KH_S[k] = q; i++ }
  }
  KH_QEND = q
  return k
}

# ---- what a heredoc body is (#166, #284).  A body is code when something RUNS
# it: a shell or interpreter reading its program from stdin, as the command that
# owns the heredoc (`bash <<'EOF'`, `python3 - <<'EOF'`), as a later stage of its
# pipeline (`cat <<'EOF' | sh`), or as the inline-code command a `$(cat <<EOF …)`
# is spliced into (`bash -c "$(cat <<'EOF'`).  Quoting the delimiter changes
# expansion, not that.  Every other body is data — a document that merely names a
# gated command must never fire — except that an unquoted one still runs its
# `$( … )` and `` ` … ` `` substitutions as it is written, so those are kept and
# the prose around them is dropped.  onchain-guard and secrets-guard carried this
# reader as two identical copies.  egress-guard kept a body only when its
# delimiter was unquoted and the head's first word a shell or interpreter, and
# fetch-exec-guard looked past the shell for the command word and kept none, so
# `bash <<'EOF'` and `cat <<'EOF' | sh` ran an upload or a fetch past both.
#
# Each includer defines hd_interp_line(w, l): what line l of a body interpreter w
# runs becomes in the text the guard reads.

# A versioned name is the same interpreter: python3.12, pypy3, php8.2, nodejs.
function hd_interp(w) {
  return (w ~ /^(python|pypy|php|ruby|perl|lua)[0-9.]*$/ || w == "node" || w == "nodejs" \
       || w == "deno" || w == "bun" || w == "osascript" || w == "Rscript" || w == "tclsh")
}
function hd_shell(w) { return (is_shell(w) || w == "ash") }
# hd_cmd — index of the command word, past assignments, reserved words
# (`then bash <<'EOF'`), redirections and non-shell wrappers with the words their
# options take.
function hd_cmd(T, n,   ci, w, r) {
  ci = 1
  while (ci <= n) {
    while (ci <= n) {
      if (T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || kit_reserved(T[ci])) ci++
      else if ((r = kit_redir(T, n, ci)) > 0) ci += r
      else break
    }
    if (ci > n) break
    w = base(T[ci]); if (!is_wrapper(w) || w == "eval") break
    ci++
    while (ci <= n && T[ci] ~ /^-/) ci += (ci < n && kit_wrapper_optarg(w, T[ci])) ? 2 : 1
    while (ci <= n && (r = kit_redir(T, n, ci)) > 0) ci += r
    if (ci <= n && kit_wrapper_operand(w, T[ci])) ci++
  }
  return ci
}
# hd_inline_flag — t makes w run its next argument as the program.
function hd_inline_flag(w, t) {
  if (hd_shell(w)) return (t ~ /^-[A-Za-z]*c[A-Za-z]*$/)
  return (t ~ /^-[A-Za-z]*[ceEp]$/ || t == "-m" || t ~ /^--(eval|print)/ || (w == "php" && t == "-r"))
}
# hd_optarg — option t of w, a shell when sh is set, takes the next word as its
# value, which is then no script file: `node -r dotenv/config -`, `bash -o pipefail`.
function hd_optarg(w, sh, t) {
  if (sh) return (t == "-o" || t == "+o" || t == "-O" || t == "+O" || t == "--rcfile" || t == "--init-file")
  if (w == "node" || w == "nodejs") return (t == "-r" || t == "--require" || t == "--import" || t == "--loader" \
                        || t == "--experimental-loader" || t == "-C" || t == "--conditions")
  if (w == "ruby") return (t == "-I" || t == "-r" || t == "-C")
  return (t ~ /^-[WX]$/)
}
# hd_stdin_path — t names the process's own stdin, which `-` also means.
function hd_stdin_path(t) { return (t == "-" || t == "/dev/stdin" || t == "/dev/fd/0" || t == "/proc/self/fd/0") }
# hd_stdin_code — the command at T[ci] reads its program from stdin.  A shell's
# -s reads it from stdin whatever follows: `bash -s arg <<'EOF'` runs the body with
# arg as $1.
function hd_stdin_code(T, n, ci,   w, sh, i, t, r) {
  w = base(T[ci])
  if (w == "source" || w == ".") {
    for (i = ci + 1; i <= n && (r = kit_redir(T, n, i)) > 0; i += r) ;
    return (i <= n && hd_stdin_path(T[i]))
  }
  sh = hd_shell(w)
  if (!sh && !hd_interp(w)) return 0
  for (i = ci + 1; i <= n; i++) {
    t = T[i]
    if ((r = kit_redir(T, n, i)) > 0) { i += r - 1; continue }
    if (hd_stdin_path(t)) return 1
    if (sh ? t ~ /^[-+]/ : t ~ /^-/) {
      if (hd_inline_flag(w, t)) return 0             # stdin is that program's data
      if (sh && t ~ /^-[A-Za-z]*s[A-Za-z]*$/) return 1
      if (hd_optarg(w, sh, t)) i++
      continue
    }
    if ((w == "deno" || w == "bun") && t == "run" && i == ci + 1) continue
    return 0                                           # a script file; stdin is its data
  }
  return 1
}
# hd_inline — the command at T[ci] runs an argument as code.
function hd_inline(T, n, ci,   w, i) {
  w = base(T[ci])
  if (w == "eval") return 1
  if (!hd_shell(w) && !hd_interp(w)) return 0
  for (i = ci + 1; i <= n; i++) if (T[i] ~ /^-/ && hd_inline_flag(w, T[i])) return 1
  return 0
}
# hd_consumer — the word that runs a heredoc opened between head and tail on one
# line, or "" when its body is data.  A heredoc inside `$( … )` is code when the
# command it is spliced into runs its argument (`bash -c "$(cat <<'EOF'`), and
# one inside `<( … )` when the command before it runs that file as a program
# (`bash <(cat <<'EOF'`, `source <(…)`, `bash < <(…)`): bash runs both.
function hd_consumer(head, tail,   ns, S, ng, G, g, n, T, Q, ci, w) {
  ns = split(split_cmd(head), S, "\001"); ng = split(S[ns], G, "\002")
  n = tokenize(G[ng], T, Q); ci = hd_cmd(T, n)
  if (ci <= n && hd_stdin_code(T, n, ci)) return base(T[ci])
  if (ng > 1 && G[ng-1] ~ /\$__X__[ \t]*$/) {
    n = tokenize(G[ng-1], T, Q); ci = hd_cmd(T, n)
    if (ci <= n && hd_inline(T, n, ci)) return base(T[ci])
  }
  if (ng > 1 && G[ng-1] ~ /<[ \t]*$/) {
    n = tokenize(G[ng-1], T, Q); ci = hd_cmd(T, n); w = (ci <= n) ? base(T[ci]) : ""
    if (hd_shell(w) || hd_interp(w) || w == "source" || w == ".") return w
  }
  ns = split(split_cmd(tail), S, "\001"); ng = split(S[1], G, "\002")
  for (g = 2; g <= ng; g++) {
    n = tokenize(G[g], T, Q); ci = hd_cmd(T, n)
    if (ci <= n && hd_stdin_code(T, n, ci)) return base(T[ci])
  }
  return ""
}
# hd_strip — raw with every heredoc body reduced to what runs, kw as kit_shell_text
# takes it; the head line stays and the terminator goes.  The opener is found as
# the shell finds it (kit_hd_ops), the delimiter read whole (kit_hd_delim) and the
# body ended exactly (kit_hd_end).  A body a shell runs is code and is read as
# the shell reads it: kit_shell_text joins its continuations and, with kw, drops
# its reserved words, and its own heredocs are reduced the same way, eight levels
# deep, past which it is kept whole.  Copied verbatim instead, `git push
# \<newline>--force` and `then npm publish` in `bash <<'EOF'` met no anchored
# pattern, and a document heredoc inside one read as commands.  An interpreter's
# body becomes the includer's hd_interp_line text.  An unquoted body that is data
# leaves its substitutions, across lines (kit_hd_subst).  Any other body is
# dropped.  A body the input ends inside still runs, as bash warns and reads it to
# the end, so it is reduced the same way.
function hd_strip(raw, kw,   text, delim, dash, mode, who, body, nl, L, k, l, s, np, j, at, q) {
  if (index(raw, "<<") == 0) return raw
  text = ""; delim = ""; q = ""
  nl = split(raw, L, "\n")
  for (k = 1; k <= nl; k++) {
    l = L[k]
    if (delim != "") {
      if (kit_hd_end(l, delim, dash)) { text = text hd_close(mode, body, kw); delim = ""; continue }
      if (mode == "shell") body = body l "\n"
      else if (mode == "interp") { s = hd_interp_line(who, l); if (s != "") text = text s "\n" }
      else if (mode == "subst") { s = kit_hd_subst(l); if (s != "") text = text s "\n" }
      continue
    }
    np = kit_hd_ops(l, q); q = KH_QEND; at = 0
    for (j = 1; j <= np && at == 0; j++) if (kit_hd_delim(substr(l, KH_P[j]))) at = KH_P[j]
    if (at > 0) {
      who = hd_consumer(substr(l, 1, at - 1), substr(l, at + KHD_LEN))
      delim = KHD_DELIM; dash = KHD_DASH; body = ""
      if (who == "") { mode = KHD_QUOTED ? "drop" : "subst"; if (mode == "subst") kit_hd_subst_reset() }
      else mode = (hd_shell(who) || who == "eval" || who == "source" || who == ".") ? "shell" : "interp"
    }
    text = text l "\n"
  }
  if (delim != "") text = text hd_close(mode, body, kw)
  return text
}
# hd_close — what a body hd_strip has read to its end leaves in the text.
function hd_close(mode, body, kw,   s) {
  if (mode == "subst") { s = kit_hd_subst_flush(); return (s == "") ? "" : s "\n" }
  if (mode != "shell" || body == "") return ""
  if (HD_DEPTH >= 8) return body
  HD_DEPTH++; s = hd_strip(kit_shell_text(body, kw), kw); HD_DEPTH--
  return s
}

# ---------------------------------------------------------------- the shell's own reading

# kit_qscan — the quote stack after reading l from stack q: s '…', e $'…', d "…",
# b `…`, p ( or $( (code again, inside "…" too), and S / D for the quote opening at
# position codeat, which the caller has identified as a wrapper's code payload
# (`sh -c "…"`).  The rules are kit_hd_ops's, so the two agree on what is
# quoted.  Three globals carry
# what a caller reading a line in pieces needs:
#   KQ_CONT     l ends in a backslash-newline continuation: not inside '…', and not
#               in a comment, which the shell never continues
#   KQ_COMMENT  a # comment began, so the rest of the line is prose.  It stays set
#               until the caller clears it at the next line, with KQ_PREV.
#   KQ_PREV     the last character read, for the next piece's # test
function kit_qscan(l, q, codeat,   i, L, c, top, p) {
  KQ_CONT = 0
  if (KQ_COMMENT) return q
  L = length(l)
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1); top = substr(q, length(q))
    if (top == "s" || top == "S") { if (c == SQ) q = substr(q, 1, length(q) - 1); continue }
    # e is $'…' (#301): a backslash escapes there, `\'` included, and continues nothing.
    if (top == "e") { if (c == "\\") i++; else if (c == SQ) q = substr(q, 1, length(q) - 1); continue }
    if (c == "\\") { if (i == L) KQ_CONT = 1; i++; continue }
    # In `…` only the closing backtick counts, as in kit_bt_end: no quote opens.
    if (top == "b") { if (c == "`") q = substr(q, 1, length(q) - 1); continue }
    if (top == "d" || top == "D") {
      if (c == "\"") q = substr(q, 1, length(q) - 1)
      else if (substr(l, i, 2) == "$(") { q = q "p"; i++ }
      else if (c == "`") q = q "b"
      continue
    }
    if (kit_pid(l, i)) i++                                 # `$$` is the PID (kit_pid)
    else if (c == "$" && substr(l, i + 1, 1) == SQ) { q = q "e"; i++ }
    else if (c == SQ) q = q (i == codeat ? "S" : "s")
    else if (c == "\"") q = q (i == codeat ? "D" : "d")
    else if (c == "`") q = (top == "b") ? substr(q, 1, length(q) - 1) : q "b"
    else if (c == "(") q = q "p"
    else if (c == ")") { if (top == "p") q = substr(q, 1, length(q) - 1) }
    else if (c == "#") {
      p = (i == 1) ? KQ_PREV : substr(l, i - 1, 1)
      if (p == "" || p ~ /[ \t;&|(]/) { KQ_COMMENT = 1; break }
    }
  }
  # Ending on a continuation, the character the next line follows is the one
  # before the backslash, since the shell deletes the pair.
  if (KQ_CONT) { if (L > 1) KQ_PREV = substr(l, L - 1, 1) }
  else if (L > 0) KQ_PREV = substr(l, L, 1)
  return q
}

# kit_code_top — text read in stack q is code: unquoted, in $( ), ( ) or `…`, or in
# a code payload.  Inside a plain '…' or "…" it is an argument, however much it
# looks like a command.
function kit_code_top(q,   t) {
  t = substr(q, length(q))
  return (t == "" || t == "p" || t == "b" || t == "S" || t == "D")
}

# kit_unreserve — st without the reserved words leading it, its indent kept.
function kit_unreserve(st,   lead) {
  lead = st; sub(/[^ \t].*$/, "", lead)
  st = substr(st, length(lead) + 1)
  while (match(st, /^[^ \t]+/) && kit_reserved(substr(st, 1, RLENGTH))) {
    st = substr(st, RLENGTH + 1); sub(/^[ \t]+/, "", st)
  }
  return lead st
}

# kit_unwrap — st without what stands between a statement's start and its
# command, for the patterns that anchor on the command word: the reserved words,
# a `function NAME` or `coproc NAME {` header, and the wrappers that run the next
# word as a command (`nice -n 5`, `timeout 5`, `env FOO=1`, `command`, `sudo -u
# me`) with their options and operands.  The indent and any VAR= assignment are
# kept, since the patterns read those.  Claude Code strips timeout, time, nice,
# nohup, stdbuf, command and builtin before matching a rule, so `nice npm
# publish` met `Bash(npm *)` in permissions.allow and nothing else; read here as
# it was, the publish pattern never saw npm in command position.  A text with
# nothing to drop comes back unchanged.
function kit_unwrap(st,   lead, n, A, i, w, cur, keep, out, j, r, u, ch) {
  lead = st; sub(/[^ \t].*$/, "", lead)
  n = split(substr(st, length(lead) + 1), A, /[ \t]+/)
  i = 1; keep = ""
  while (i <= n) {
    w = A[i]
    if (w == "") { i++; continue }
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep w " "; i++; continue }
    if ((r = kit_lead_redir(A, n, i)) > 0) { i += r; continue }
    # `coproc NAME { cmd; }` names the coprocess; the command is in the braces.
    if (w == "coproc" && i + 2 <= n && A[i + 2] == "{") { i += 2; continue }
    if (kit_reserved(w)) { i++; continue }
    if (w == "function" && i < n) { i += 2; continue }
    cur = base(kit_unq(w))
    if (!is_wrapper(cur) || cur == "eval") break
    i++
    while (i <= n) {
      if (A[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep A[i] " "; i++; continue }
      if (A[i] == "--") { i++; break }
      if (A[i] ~ /^-/) { if (i < n && kit_wrapper_optarg(cur, A[i])) i++; i++; continue }
      break
    }
    # One operand at most, as cmdword_x takes it: flock's lock file, timeout's
    # duration.  Read as a loop, every word after `flock f` was an operand.
    while (i <= n && (r = kit_lead_redir(A, n, i)) > 0) i += r
    if (i <= n && kit_wrapper_operand(cur, A[i])) i++
  }
  # Every word as the shell reads it (#293, #297): `npm "publish"` is npm publish.
  ch = 0
  for (j = i; j <= n; j++) { u = kit_unq(A[j], j > i); if (u != A[j]) { A[j] = u; ch = 1 } }
  if (i == 1 && !ch) return st
  out = ""
  for (j = i; j <= n; j++) if (A[j] != "") out = out (out == "" ? "" : " ") A[j]
  return lead keep out
}

# kit_stmt_sep — sep as the text after statement st should carry it, read from
# quote stack q (codeat as kit_qscan takes it).  A `)` in code that does not
# close a `$(` ends a case pattern or a function header, so a `;` is added after
# it and the command that follows starts a statement for the anchored patterns:
# `case x in a) anchor deploy …;;` and `f() { npm publish; }` were silent.
# After a subshell's `)` no command can follow, so the `;` changes nothing there.
# KP is the stack of the parentheses open in code, `$` for a substitution; the
# caller empties it at the start of a text.  KQ_PREV and KQ_COMMENT are left as
# they were, so the caller's own scan of the same text is undisturbed.
function kit_stmt_sep(st, sep, q, codeat,   sp, sc, qq, top, code, esc) {
  if (sep != "(" && sep != ")" && sep != "$(") return sep
  sp = KQ_PREV; sc = KQ_COMMENT
  qq = kit_qscan(st, q, codeat); top = substr(qq, length(qq))
  code = !KQ_COMMENT && kit_code_top(qq)
  esc = match(st, /\\+$/) && RLENGTH % 2 == 1
  KQ_PREV = sp; KQ_COMMENT = sc
  if (esc) return sep
  if (sep == "$(") { if (!KQ_COMMENT && top != "s" && top != "S" && top != "e") KP = KP "$"; return sep }
  if (!code) return sep
  if (sep == "(") { KP = KP "("; return sep }
  top = substr(KP, length(KP)); KP = substr(KP, 1, length(KP) - 1)
  return (top == "$") ? sep : sep ";"
}

# kit_shell_text — raw as the shell reads it, for the guards that match a regex
# over the text rather than walking tokens.  Every backslash-newline outside '…'
# is joined, as the shell joins it before splitting words; with kw set, the
# reserved words leading a command outside quotes are dropped as well, so
# `if true; then npm publish; fi` reads `true; npm publish; fi`.  The statement
# separators are the ones onchain-guard.awk splits on, read the same way.
# Nothing else changes: a text with neither comes back byte for byte, which is
# what keeps every other verdict where it was.
#
# With kw set, every code string another program runs (kit_inline_code) follows
# as lines of its own, read the same way, the strings nested in it included.  A
# pattern anchored on a statement start then finds one at the head of the string
# and after each separator in it, where in place the string is a quoted argument:
# `sh -c "npm publish"`, `git rebase --exec 'npm publish' main` and `git submodule
# foreach 'git push --force origin HEAD'` were silent at High, where the bare
# commands are denied.  Read apart from the line that carries it, the string
# keeps its own quoting: `bash -c 'git commit -m "x; then npm publish"'` is still
# a message.  Reading stops, and KIT_DEEP is set so the guard refuses, once a
# code string nests past KIT_MAXDEPTH or the bytes re-read pass 8 per byte of raw:
# either way the command is too deeply nested to read within the hook's timeout,
# and refusing beats reading a fraction and missing the inner command.  CD[k] is
# the depth of payload C[k]; the first generation is depth 1.
function kit_shell_text(raw, kw,   out, nc, C, CD, k, nc2, j, left) {
  out = kit_read_text(raw, kw)
  if (!kw) return out
  left = 8 * length(raw) + 4096
  nc = kit_payloads(KT_CODE, C, 0)
  for (k = 1; k <= nc; k++) CD[k] = 1
  for (k = 1; k <= nc; k++) {
    if ((left -= length(C[k])) < 0) { KIT_DEEP = 1; break }
    out = out (out ~ /\n$/ ? "" : "\n") kit_read_text(C[k], 1)
    # Refuse only on a code string actually found one deeper, not on the cheap
    # hint: `git push` at the limit names "sh" and runs no shell.  Past the limit
    # what kit_payloads appended is left beyond nc, so it is never read.
    nc2 = kit_payloads(KT_CODE, C, nc)
    if (nc2 == nc) continue
    if (CD[k] >= KIT_MAXDEPTH) { KIT_DEEP = 1; continue }
    for (j = nc + 1; j <= nc2; j++) CD[j] = CD[k] + 1
    nc = nc2
  }
  return out
}

# kit_read_text — kit_shell_text's reading of one text, without the code strings.
# With kw set it leaves the text's code in KT_CODE, heredoc bodies left out: a
# document naming `sh -c '…'` runs nothing.
#
# A heredoc body is copied untouched, since a document's `\` and `then` are not
# the shell's.  Only an operator the shell reads opens one (kit_hd_ops), quoted
# delimiter or not: a `<<` inside quotes or a comment is text, and reading it as
# an opener switched the normalising off for every line after `echo '<<X'`.  The
# delimiter is read by the shared kit_hd_delim and the body end by kit_hd_end, so a
# partly quoted delimiter and an indented `<<-` terminator are read as the shell
# reads them.
function kit_read_text(raw, kw,   nl, L, k, l, out, first, q, qj, nd, di, D, DDASH, rest, st, sep, cmd, np, j, mark) {
  KT_CODE = ""
  if (!kw && index(raw, "\\\n") == 0) return raw
  nl = split(raw, L, "\n")
  out = ""; first = 1; q = ""; nd = 0; di = 0; KP = ""
  for (k = 1; k <= nl; k++) {
    l = L[k]
    if (di < nd) {
      if (kit_hd_end(l, D[di + 1], DDASH[di + 1])) di++
    } else {
      # Each physical line is read once, from the state the last one left: a
      # rescan of the growing line per continuation was quadratic, and a hook
      # padded past its timeout does not block the call.
      KQ_PREV = ""; KQ_COMMENT = 0; qj = kit_qscan(l, q, 0)
      while (KQ_CONT && k < nl) {
        l = substr(l, 1, length(l) - 1)
        qj = kit_qscan(L[++k], qj, 0)
        l = l L[k]
      }
      np = (index(l, "<<") > 0) ? kit_hd_ops(l, q) : 0
      for (j = 1; j <= np; j++) {
        if (!kit_hd_delim(substr(l, KH_P[j]))) continue
        D[++nd] = KHD_DELIM; DDASH[nd] = KHD_DASH
      }
      if (!kw) q = qj
      else {
        KT_CODE = KT_CODE l "\n"
        KQ_PREV = ""; KQ_COMMENT = 0
        rest = l; l = ""
        while (length(rest)) {
          if (kit_sep(rest)) {
            st = substr(rest, 1, RSTART - 1); sep = substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RSTART + RLENGTH)
          } else { st = rest; sep = ""; rest = "" }
          cmd = !KQ_COMMENT && kit_code_top(q)
          mark = kit_stmt_sep(st, sep, q, 0)
          q = kit_qscan(st sep, q, 0)
          l = l (cmd ? kit_unwrap(st) : st) mark
        }
      }
    }
    out = first ? l : out "\n" l; first = 0
  }
  return out
}
