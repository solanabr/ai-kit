#!/bin/sh
# secrets-guard.sh — PreToolUse(Bash): block reads of credential stores, key
# material and wallet vaults.  Active at every tier, including Off, because the
# never-allowed set does not vary by tier.
#
# The invariant, and the whole reason this file replaced an inline grep:
#
#   a rule may match only a path in ARGUMENT POSITION of a command that would
#   touch that path — never the command's prose.
#
# Writing documentation, a commit message, an issue body or a test corpus that
# names a protected path is not access to it and must never be blocked.  The
# inline predecessor grepped the whole command string and produced five
# independent false positives in one session (a diagnostic `ls -l` on a wallet,
# a `gh issue create` body, the firewall spec itself, two test corpora), to the
# point where two shipped commands documented workarounds.
#
# Decisions come from an awk pass that quote-aware splits the command into
# statements and pipeline stages, strips heredoc bodies, finds each stage's real
# command word past env assignments and wrappers, and only then looks at that
# command's arguments.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
kit_parse
[ -n "$KIT_CMD" ] || exit 0

# The regex travels in the environment, not through -v: awk processes escape
# sequences in -v assignments, which mangles \. and \( differently per awk.
VERDICT=$(printf '%s\n' "$KIT_CMD" | KIT_VAULT_RE="$(kit_vault_re)" KIT_LANG="${KIT_LANG-}" awk '
function is_benign(c) {
  # Metadata-only or prose-only commands: they never hand file CONTENT back.
  return (c == "ls" || c == "l" || c == "ll" || c == "la" || c == "stat" || c == "file" \
       || c == "test" || c == "[" || c == "echo" || c == "printf" || c == "true" \
       || c == "false" || c == ":" || c == "basename" || c == "dirname" \
       || c == "realpath" || c == "readlink" || c == "which" || c == "type" \
       || c == "hash" || c == "du" || c == "df" || c == "wc" || c == "pwd" \
       || c == "cd" || c == "export" || c == "set" || c == "unset" || c == "shasum" \
       || c == "sha256sum" || c == "md5sum" || c == "md5" || c == "cksum")
}
function is_wrapper(c) {
  return (c == "env" || c == "command" || c == "builtin" || c == "exec" || c == "nohup" \
       || c == "nice" || c == "ionice" || c == "time" || c == "timeout" || c == "stdbuf" \
       || c == "xargs" || c == "sudo" || c == "doas" || c == "setsid" || c == "flock" \
       || c == "watch" || c == "noglob" || c == "eval")
}
function is_shell(c) {
  return (c == "sh" || c == "bash" || c == "zsh" || c == "dash" || c == "ksh" || c == "fish")
}
function is_interp(c) {
  # kit_mcp_code is not a binary: it is the marker lib-headless.sh puts in command
  # position when an MCP tool carries code in a language that is not shell (see
  # kit_mcp_normalize).  Inline-code treatment is exactly right for it — the
  # payload is a program, not a command line.
  return (c == "python" || c == "python2" || c == "python3" || c == "node" || c == "deno" \
       || c == "bun" || c == "perl" || c == "ruby" || c == "php" || c == "osascript" \
       || c == "Rscript" || c == "lua" || c == "tclsh" || c == "kit_mcp_code")
}
# How to name the interpreter in a message.  The marker word would read as a
# binary nobody has, so the language named by the tool call is used instead.
# (No apostrophes in here: the whole program is one single-quoted shell word.)
function interp_name(c) {
  return (c == "kit_mcp_code" && ENVIRON["KIT_LANG"] != "") ? ENVIRON["KIT_LANG"] : c
}
function is_pattern_tool(c) {
  # The first positional, and any quoted argument, is a pattern or a script.
  return (c == "grep" || c == "egrep" || c == "fgrep" || c == "zgrep" || c == "rg" \
       || c == "ag" || c == "ack" || c == "sed" || c == "awk" || c == "nawk" \
       || c == "gawk" || c == "jq" || c == "yq")
}
function is_msg_flag(f) {
  return (f == "-m" || f == "--message" || f == "--body" || f == "--title" \
       || f == "--notes" || f == "--note" || f == "--description" || f == "--desc" \
       || f == "--comment" || f == "--text" || f == "--subject" || f == "--label" \
       || f == "--grep" || f == "--author" || f == "--committer" || f == "-S" || f == "-G" \
       || f == "--reason" || f == "--summary" || f == "--prompt" || f == "--query")
}
function is_pattern_flag(f) {
  return (f == "-e" || f == "--regexp" || f == "-f" || f == "--file" || f == "-g" \
       || f == "--glob" || f == "--iglob" || f == "-v" || f == "--arg" || f == "--argjson")
}
function base(p) { sub(/^\\/, "", p); sub(/^.*\//, "", p); return p }
function unmark(s) { gsub(/\003/, " ", s); return s }
function looks_remote(a) {
  # A URL or an scp/ssh remote spec is a destination, never a local path.
  return (a ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\// || a ~ /^[^\/ ]+@[^\/ ]+:/)
}
function hits(a) { a = unmark(a); return (a != "" && a ~ VAULTRE) }
function code_hits(a,   i, n, P, t) {
  a = unmark(a)
  gsub(/[(),;=]/, " ", a); gsub(SQ, " ", a); gsub(/"/, " ", a)
  n = split(a, P, /[ \t]+/)
  for (i = 1; i <= n; i++) { t = P[i]; if (t != "" && !looks_remote(t) && t ~ VAULTRE) return t }
  return ""
}

# Quote-aware split.  \001 = statement boundary (no data flow across),
# \002 = stage boundary, \003 = a backslash-escaped space inside a token.
function split_cmd(s,   i, c, c2, st, sp, out) {
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
    # ${VAR} is one token, not a brace group: keep it verbatim.
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

# tokenize: T[] holds tokens, Q[] is 1 when the token carried a quote.
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

# first_word: index of the first token that is not a VAR=value assignment.
function first_word(T, n,   i) {
  i = 1
  while (i <= n && T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
  return i
}

# cmdword: the real command, past leading assignments and wrappers.  Sets CWI.
function cmdword(T, n,   ci, w) {
  ci = first_word(T, n)
  while (ci <= n) {
    w = base(T[ci])
    if (!is_wrapper(w)) { CWI = ci; return w }
    ci++
    while (ci <= n && T[ci] ~ /^-/) ci++
  }
  CWI = n + 1
  return ""
}

BEGIN {
  SQ = sprintf("%c", 39)
  VAULTRE = ENVIRON["KIT_VAULT_RE"]
  HD_DQ = "<<-?[ \t]*\"[A-Za-z_][A-Za-z0-9_]*\""
  HD_SQ = "<<-?[ \t]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
  HD_BARE = "<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*"
}
{ raw = raw $0 "\n" }
END {
  if (VAULTRE == "") exit 0

  # ---- strip heredoc BODIES.  A document that merely names a credential path
  # must never fire.  One exception: an UNQUOTED delimiter feeding a shell or
  # an interpreter is code, not prose, so that body is kept and inspected.
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
      hn = tokenize(split_cmd(head), HT, HQ); hw = cmdword(HT, hn)
      if (quoted || !(is_shell(hw) || is_interp(hw))) delim = d
    }
    text = text l "\n"
  }

  text = split_cmd(text)
  nst = split(text, ST, "\001")
  for (q = 1; q <= nst; q++) {
    nstg = split(ST[q], STG, "\002")

    # Unwrap one level of `sh -c "<inner>"` / `eval "<inner>"`: the quoted
    # string is code, so it becomes a stage of its own.
    for (g = 1; g <= nstg && nstg < 64; g++) {
      n = tokenize(STG[g], T, Q); if (n == 0) continue
      ci = first_word(T, n); if (ci > n) continue
      w = base(T[ci])
      if (!(is_shell(w) || w == "eval" || is_wrapper(w))) continue
      for (i = ci + 1; i <= n; i++) if (Q[i] && T[i] ~ /[ \t]/) { STG[++nstg] = split_cmd(T[i]); break }
    }

    # `echo <path> | xargs cat` turns prose into an argument one stage later.
    # xargs is the only shape that does that, so prose-only commands lose
    # their exemption in a statement that pipes into xargs.
    piped_to_xargs = 0
    for (g = 1; g <= nstg; g++) {
      n = tokenize(STG[g], T, Q); if (n == 0) continue
      ci = first_word(T, n)
      if (ci <= n && base(T[ci]) == "xargs") piped_to_xargs = 1
    }

    for (g = 1; g <= nstg; g++) {
      n = tokenize(STG[g], T, Q); if (n == 0) continue
      c0 = cmdword(T, n)

      # Assignment values are arguments too: `S=~/.ssh/id_rsa; cat $S`.
      for (i = 1; i < CWI && i <= n; i++) {
        if (T[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        v = T[i]; sub(/^[^=]*=/, "", v)
        if (!looks_remote(v) && hits(v)) {
          print "DENY a credential path (" unmark(v) ") is being stashed in a shell variable"; exit
        }
      }

      # Redirect targets, checked even for prose-only commands: `echo x > wallet`
      # destroys a key just as surely as `solana-keygen new -o wallet`.
      for (i = 1; i <= n; i++) {
        if (Q[i] || T[i] !~ /^[0-9]*>>?\|?/) continue
        v = T[i]; sub(/^[0-9]*>>?\|?/, "", v)
        if (v == "" && i < n) v = T[i+1]
        if (!looks_remote(v) && hits(v)) {
          print "DENY the command redirects output onto a protected credential path: " unmark(v); exit
        }
      }
      if (c0 == "" || (is_benign(c0) && !piped_to_xargs)) continue

      # Credential-printing commands, recognised in command position only.
      p1 = (CWI + 1 <= n) ? T[CWI+1] : ""
      p2 = (CWI + 2 <= n) ? T[CWI+2] : ""
      if (c0 == "gh" && p1 == "auth" && p2 == "token") { print "DENY gh auth token prints the GitHub token"; exit }
      if (c0 == "security" && (p1 ~ /^find-(generic|internet)-password$/ || p1 == "dump-keychain")) {
        print "DENY security " p1 " reads the macOS keychain"; exit }
      if (c0 == "secret-tool" && p1 == "lookup") { print "DENY secret-tool lookup reads the login keyring"; exit }
      if (c0 == "gcloud" && p1 == "auth" && p2 ~ /^print-(access|identity)-token$/) {
        print "DENY gcloud auth " p2 " prints a live credential"; exit }
      if (c0 == "aws" && p1 == "configure" && p2 == "get") { print "DENY aws configure get reads stored credentials"; exit }

      pat = is_pattern_tool(c0); skipfirst = pat; interp = is_interp(c0)
      if (pat) for (i = CWI + 1; i <= n; i++) {
        f = T[i]; sub(/=.*$/, "", f)
        if (is_pattern_flag(f)) { skipfirst = 0; break }
      }

      for (i = CWI + 1; i <= n; i++) {
        a = T[i]
        if (a == "") continue
        if (a == "--show-token" && (c0 == "gh" || c0 == "glab" || c0 == "npm" || c0 == "aws" || c0 == "az" || c0 == "doctl")) {
          print "DENY --show-token prints a live credential"; exit
        }
        if (is_msg_flag(a)) { i++; continue }               # prose, not a path
        if (a ~ /^-/) {
          if (a ~ /[=@]/) {
            f = a; sub(/[=@].*$/, "", f)
            if (is_msg_flag(f)) continue
            sub(/^[^=@]*[=@]/, "", a)
          } else if (a ~ /^-[A-Za-z]+[~\/]/) {
            sub(/^-[A-Za-z]+/, "", a)                        # -o/path, -C~/path
          } else continue                                    # a bare flag
        }
        if (a == "" || looks_remote(a)) continue
        if (interp) {
          t = code_hits(a)
          if (t != "") { print "DENY inline " interp_name(c0) " code reads a credential path: " t; exit }
          continue
        }
        if (pat) {
          if (skipfirst) { skipfirst = 0; continue }         # the pattern / script
          if (Q[i]) continue                                 # a quoted pattern
        }
        if (hits(a)) { print "DENY " c0 " would read a protected credential path: " unmark(a); exit }
      }
    }
  }
}
' 2>/dev/null) || exit 0

case $VERDICT in
  DENY*)
    kit_deny "${VERDICT#DENY } — reading private keys, wallet vaults or credentials is not allowed. Use \`solana address\` for the pubkey; ask the user to run anything that needs the secret."
    ;;
esac
exit 0
