# secrets-guard.awk — decide whether a command READS key material.
#
# Lifted out of secrets-guard.sh unchanged except for the tokenizer, which now
# comes from lib-tokenize.awk (issue #138).  Run as:
#
#   awk -f lib-tokenize.awk -f secrets-guard.awk
#
# stdin : raw command text (one tool call)
# stdout: "DENY <reason>", or nothing
# env   : KIT_VAULT_RE  egrep-style regex matching protected credential paths
#         KIT_LANG      the language named by an MCP tool call, for the message

# ---- the library's callbacks.  secrets looks past wrapper binaries but NOT past
# a wrapper's positional operand, and it skips VAR= assignments only at the front
# of a statement, so `env FOO=1 cat x` leaves the path in argument position where
# the argument scan below finds it.  Both were true of its own copy; keeping them
# is what makes this extraction verdict-for-verdict identical.
function kit_wrapper(w) { return is_wrapper(w) }
# Unused since #166 (hd_strip below replaces strip_heredocs), but the library
# references it and awk resolves calls lazily, so it stays defined.
function kit_heredoc_is_code(w) { return (is_shell(w) || is_interp(w)) }
function cmdword(T, n) { return cmdword_x(T, n, 0, 0) }

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
function hits(a) { a = unmark(a); return (a != "" && a ~ VAULTRE) }

# ---- heredoc classifier (#166).  This block, through hd_strip, is identical in
# secrets-guard.awk and onchain-guard.awk (tests/test_hooks.sh checks).  It
# belongs in lib-tokenize.awk once #233, which edits that file, has landed.
#
# The library's strip_heredocs keeps a body only when the delimiter is unquoted
# and the command on the left runs it.  Both halves miss: `python3 - <<'EOF'`
# runs a quoted body, and `cat <<EOF | sh` runs a body whose head is cat.  What
# decides is whether something RUNS the body: a shell or interpreter reading its
# program from stdin, as the command owning the heredoc, as a later stage of the
# pipeline, or as the inline-code command a `$(cat <<EOF …)` is spliced into
# (`bash -c "$(cat <<'EOF'`).  Quoting the delimiter changes expansion, not that.
# Every other body is data, except that an unquoted one still runs its $(…) and
# `…` substitutions, so those are kept and the prose around them is dropped.
#
# Each guard defines hd_interp_line(w, l): what an interpreter's body line
# becomes in the text the guard matches.

function hd_interp(w) {
  return (w == "python" || w == "python2" || w == "python3" || w == "node" || w == "deno" \
       || w == "bun" || w == "perl" || w == "ruby" || w == "php" || w == "osascript" \
       || w == "Rscript" || w == "lua" || w == "tclsh")
}
function hd_shell(w) { return (is_shell(w) || w == "ash") }
# hd_cmd — index of the command word, past assignments and non-shell wrappers.
function hd_cmd(T, n,   ci, w) {
  ci = 1
  while (ci <= n) {
    while (ci <= n && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ci++
    if (ci > n) break
    w = base(T[ci]); if (!is_wrapper(w) || w == "eval") break
    ci++
    while (ci <= n && T[ci] ~ /^-/) ci++
    if (ci <= n && kit_wrapper_operand(w, T[ci])) ci++
  }
  return ci
}
# hd_inline_flag — t makes w run its next argument as the program.
function hd_inline_flag(w, t) {
  if (hd_shell(w)) return (t ~ /^-[A-Za-z]*c[A-Za-z]*$/)
  return (t ~ /^-[A-Za-z]*[ceEp]$/ || t == "-m" || t ~ /^--(eval|print)/ || (w == "php" && t == "-r"))
}
# hd_stdin_path — t names the process's own stdin, which `-` also means.
function hd_stdin_path(t) { return (t == "-" || t == "/dev/stdin" || t == "/dev/fd/0" || t == "/proc/self/fd/0") }
# hd_stdin_code — the command at T[ci] reads its program from stdin.
function hd_stdin_code(T, n, ci,   w, sh, i, t) {
  w = base(T[ci])
  if (w == "source" || w == ".") return (ci < n && hd_stdin_path(T[ci + 1]))
  sh = hd_shell(w)
  if (!sh && !hd_interp(w)) return 0
  for (i = ci + 1; i <= n; i++) {
    t = T[i]
    if (hd_stdin_path(t)) return 1
    if (t ~ /^-/) {
      if (hd_inline_flag(w, t)) return 0             # stdin is that program's data
      if (sh ? t == "-o" : t ~ /^-[WX]$/) i++          # options taking a value
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
# line, or "" when its body is data.
function hd_consumer(head, tail,   ns, S, ng, G, g, n, T, Q, ci) {
  ns = split(split_cmd(head), S, "\001"); ng = split(S[ns], G, "\002")
  n = tokenize(G[ng], T, Q); ci = hd_cmd(T, n)
  if (ci <= n && hd_stdin_code(T, n, ci)) return base(T[ci])
  if (ng > 1 && G[ng-1] ~ /\$__X__[ \t]*$/) {
    n = tokenize(G[ng-1], T, Q); ci = hd_cmd(T, n)
    if (ci <= n && hd_inline(T, n, ci)) return base(T[ci])
  }
  ns = split(split_cmd(tail), S, "\001"); ng = split(S[1], G, "\002")
  for (g = 2; g <= ng; g++) {
    n = tokenize(G[g], T, Q); ci = hd_cmd(T, n)
    if (ci <= n && hd_stdin_code(T, n, ci)) return base(T[ci])
  }
  return ""
}
# hd_subst — the $(…) and `…` an unquoted body line still runs, one statement each.
function hd_subst(l,   out, i, j, c, d, L) {
  out = ""; L = length(l)
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1)
    if (c == "\\") { i++; continue }
    if (substr(l, i, 2) == "$(") {
      d = 0
      for (j = i + 1; j <= L; j++) { c = substr(l, j, 1); if (c == "(") d++; else if (c == ")" && --d == 0) break }
      out = out "; " substr(l, i, j - i + 1); i = j; continue
    }
    if (c == "`") {
      j = index(substr(l, i + 1), "`"); if (j == 0) j = L - i + 1
      out = out "; $(" substr(l, i + 1, j - 1) ")"; i += j
    }
  }
  return out
}
# hd_open — fills HD_P with the positions on l of each `<<` outside quotes and
# comments, and returns how many.  HD_Q is the quoting still open from earlier
# lines, as a stack: s '…', d "…", b `…`, p ( or $( (unquoted again inside "…").
# A `<<` inside quotes is text: `echo "<<X"` opens no heredoc.
function hd_open(l,   i, L, c, top, k) {
  k = 0; L = length(l)
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1); top = substr(HD_Q, length(HD_Q))
    if (top == "s") { if (c == SQ) HD_Q = substr(HD_Q, 1, length(HD_Q) - 1); continue }
    if (c == "\\") { i++; continue }
    if (top == "d") {
      if (c == "\"") HD_Q = substr(HD_Q, 1, length(HD_Q) - 1)
      else if (substr(l, i, 2) == "$(") { HD_Q = HD_Q "p"; i++ }
      else if (c == "`") HD_Q = HD_Q "b"
      continue
    }
    if (c == SQ) HD_Q = HD_Q "s"
    else if (c == "\"") HD_Q = HD_Q "d"
    else if (c == "`") HD_Q = (top == "b") ? substr(HD_Q, 1, length(HD_Q) - 1) : HD_Q "b"
    else if (c == "(") HD_Q = HD_Q "p"
    else if (c == ")") { if (top == "p") HD_Q = substr(HD_Q, 1, length(HD_Q) - 1) }
    else if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t;&|(]/)) break
    else if (substr(l, i, 3) == "<<<") i += 2                   # a here-string
    else if (substr(l, i, 2) == "<<") { HD_P[++k] = i; i++ }
  }
  return k
}
# hd_strip — the raw command with every heredoc body reduced to what runs.
function hd_strip(raw,   text, delim, mode, who, nl, L, k, l, t, quoted, d, s, np, j, at, HD_DQ, HD_SQ, HD_BARE) {
  HD_DQ = "<<-?[ \t]*\"[A-Za-z_][A-Za-z0-9_]*\""
  HD_SQ = "<<-?[ \t]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
  HD_BARE = "<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*"
  text = ""; delim = ""; HD_Q = ""
  nl = split(raw, L, "\n")
  for (k = 1; k <= nl; k++) {
    l = L[k]
    if (delim != "") {
      t = l; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == delim) { delim = ""; continue }
      if (mode == "shell") text = text l "\n"
      else if (mode == "interp") { s = hd_interp_line(who, l); if (s != "") text = text s "\n" }
      else if (mode == "subst") { s = hd_subst(l); if (s != "") text = text s "\n" }
      continue
    }
    np = hd_open(l); RSTART = 0
    for (j = 1; j <= np && RSTART == 0; j++) {
      at = HD_P[j]; s = substr(l, at); quoted = 0
      if (match(s, "^" HD_DQ) || match(s, "^" HD_SQ)) quoted = 1
      else if (!match(s, "^" HD_BARE)) RSTART = 0
      if (RSTART > 0) RSTART += at - 1
    }
    if (RSTART > 0) {
      d = substr(l, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", d); gsub(/"/, "", d); gsub(SQ, "", d)
      who = hd_consumer(substr(l, 1, RSTART - 1), substr(l, RSTART + RLENGTH))
      delim = d
      if (who == "") mode = quoted ? "drop" : "subst"
      else mode = (hd_shell(who) || who == "eval" || who == "source" || who == ".") ? "shell" : "interp"
    }
    text = text l "\n"
  }
  return text
}

# An interpreter's heredoc is a program in a foreign syntax: scanned the way
# `python3 -c '…'` is, and kept out of the shell text.
function hd_interp_line(w, l,   t) {
  if (HD_HIT == "") { t = code_hits(l); if (t != "") { HD_HIT = t; HD_WHO = w } }
  return ""
}
function code_hits(a,   i, n, P, t) {
  a = unmark(a)
  gsub(/[(),;=]/, " ", a); gsub(SQ, " ", a); gsub(/"/, " ", a)
  n = split(a, P, /[ \t]+/)
  for (i = 1; i <= n; i++) { t = P[i]; if (t != "" && !looks_remote(t) && t ~ VAULTRE) return t }
  return ""
}

BEGIN { VAULTRE = ENVIRON["KIT_VAULT_RE"] }
{ raw = raw $0 "\n" }
END {
  if (VAULTRE == "") exit 0

  # Heredoc BODIES go first: a document that merely names a credential path must
  # never fire.  A body that something runs is code and is inspected (hd_strip).
  text = split_cmd(hd_strip(raw))
  if (HD_HIT != "") { print "DENY a heredoc fed to " HD_WHO " reads a credential path: " unmark(HD_HIT); exit }
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

      # solana-keygen new|recover with a force flag and NO outfile destroys the default
      # wallet keypair, ~/.config/solana/id.json.  That path is in the vault regex, but
      # it never appears in the command text, so the argument scan below cannot see it:
      # the target is implied by the ABSENCE of -o.  The explicit spelling
      # (`solana-keygen new --force -o ~/.config/solana/id.json`) has always been blocked
      # by that scan, and two spellings of one act must not get different answers.
      #
      # Why a hook and not a rule: a glob cannot express "and no -o".  A deny on
      # `solana-keygen new *--force*` would also stop
      # `solana-keygen new --force -o target/deploy/x-keypair.json`, which is how a
      # program keypair gets regenerated — ordinary work at every tier.
      #
      # Why a deny and not an ask: without a force flag solana-keygen refuses to
      # overwrite an existing outfile by itself, so the flag is only ever needed when a
      # wallet is already there.  On a machine (or a fresh CI container) with no wallet
      # yet, dropping the flag runs the identical command — which is what the message
      # says, so there is nothing for a prompt to add.
      if (c0 == "solana-keygen" && (p1 == "new" || p1 == "recover")) {
        kgf = 0; kgo = 0
        for (i = CWI + 2; i <= n; i++) {
          a = T[i]
          if (a == "") continue
          # --no-outfile writes nothing at all, so there is no target to protect.
          if (a ~ /^--no-outfile/) { kgo = 1; continue }
          if (a == "-o" || a ~ /^--outfile/ || a ~ /^-o./ || a ~ /^-[A-Za-z]*o$/) { kgo = 1; continue }
          if (a == "--force" || a ~ /^--force=/) { kgf = 1; continue }
          # Clustered short flags (-sf, -fs).  Long options are excluded first, so
          # --no-bip39-passphrase and friends cannot reach this test.
          if (a !~ /^--/ && a ~ /^-[A-Za-z]*f/) { kgf = 1; continue }
        }
        if (kgf && !kgo) {
          print "WIPE solana-keygen " p1 " --force"; exit
        }
      }

      # A search pattern is not a path read (#166).  `git grep` is a pattern tool
      # whose pattern is the first positional after `grep`, behind git's global
      # options; patfrom marks where the pattern rules start.
      pat = is_pattern_tool(c0); patfrom = CWI + 1
      if (c0 == "git") {
        for (j = CWI + 1; j <= n && T[j] ~ /^-/; j++)
          if (T[j] ~ /^(-C|-c|--git-dir|--work-tree|--namespace)$/) j++
        if (j <= n && T[j] == "grep") { pat = 1; patfrom = j + 1 }
      }
      skipfirst = pat; interp = is_interp(c0)
      if (pat) for (i = patfrom; i <= n; i++) {
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
        if (c0 == "find" && a ~ /^-(i?name|i?path|i?wholename|i?regex|i?lname)$/) { i++; continue }  # a name pattern
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
        if (pat && i >= patfrom) {
          if (skipfirst) { skipfirst = 0; continue }         # the pattern / script
          if (Q[i]) continue                                 # a quoted pattern
        }
        if (hits(a)) { print "DENY " c0 " would read a protected credential path: " unmark(a); exit }
      }
    }
  }
}
