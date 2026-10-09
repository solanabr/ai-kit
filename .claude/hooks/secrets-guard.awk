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
  # never fire.  An unquoted delimiter feeding a shell or an interpreter is code,
  # so that body is kept and inspected (kit_heredoc_is_code above).
  text = split_cmd(strip_heredocs(raw))
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
