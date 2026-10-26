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
function hits(a) { a = unmark(a); return (a != "" && (a ~ VAULTRE || glob_hits(a))) }

# ---- glob-aware vault matching.
#
# A literal path is matched by VAULTRE directly.  A path carrying a shell glob
# metacharacter (`*`, `?`, `[...]`, `{a,b}`) is not a literal: `cat ~/.np*` reads
# ~/.npmrc, `cat ~/.config/solana/id.jso?` reads the wallet, and neither matches
# VAULTRE, whose alternatives pin the literal basename.  So a glob is DENIED when
# some expansion of it could be a protected path.
#
# Structural, not a list of spellings, which would drift from the shell's own glob
# rules the way any hand-kept list does: the glob is compiled to an ERE
# the shell's own globbing would produce (`*`->[^/]*, `?`->[^/], classes kept,
# `{a,b}`->(a|b)), and that ERE is tested against the canonical protected PATHS
# (GLOBW, in the prefix forms a model types) and protected BASENAMES (GLOBE, the
# extension families).  A match means "this glob can name that credential", which
# is exactly the read being blocked.  The witness sets mirror the vault regex;
# tests/test_secrets_guard.sh asserts every one of them matches VAULTRE, so a
# future narrowing of the regex that drops a credential is caught there.
#
# The directory is kept, so `cat ./*.json` (a build dir) and `cat host*.yml` (a
# local file) do not match — only a glob whose own path structure reaches a
# credential does.  Leading $HOME/${HOME} is first folded to ~ so the ~ and the
# env-var spelling resolve alike.
#
# A catch-all glob (`cat *`, `cat src/*`, `rm -rf target/*`) also "could" name a
# credential, the way any `cat *` could — but so could it name an ordinary file,
# so it is NOT a targeted read and must not be blocked (blocking it is the Relaxed
# friction this change exists to remove).  glob_hits tells the two apart with a
# set of benign project files: a glob that matches a protected witness AND an
# ordinary file is generic and passes; one that matches a credential and no
# ordinary file (`~/.np*`, `*.pem`, `id.jso?`) is targeting and is blocked.
function has_glob(s) { return (s ~ /[*?[]/ || s ~ /\{[^}]*,[^}]*\}/) }
function glob_re_char(c) {
  if (c == "." || c == "^" || c == "$" || c == "(" || c == ")" || c == "|" \
   || c == "+" || c == "{" || c == "}" || c == "[" || c == "]" || c == "*" \
   || c == "?" || c == "\\") return "\\" c
  return c
}
function glob_to_re(s,   i, L, c, out, j, inner) {
  out = ""; L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (c == "*") { out = out "[^/]*"; continue }
    if (c == "?") { out = out "[^/]"; continue }
    if (c == "[") {
      j = i + 1; inner = ""
      if (substr(s, j, 1) == "!" || substr(s, j, 1) == "^") { inner = "^"; j++ }
      while (j <= L && substr(s, j, 1) != "]") { inner = inner substr(s, j, 1); j++ }
      if (j <= L) { out = out "[" inner "]"; i = j; continue }
      out = out "\\["; continue                          # unmatched [ is literal
    }
    if (c == "{") {
      j = i + 1; inner = ""
      while (j <= L && substr(s, j, 1) != "}") { inner = inner substr(s, j, 1); j++ }
      if (j <= L && index(inner, ",") > 0) { gsub(/,/, "|", inner); out = out "(" inner ")"; i = j; continue }
      out = out "\\{"; continue
    }
    out = out glob_re_char(c)
  }
  return out
}
# brace_expand — expand unquoted `pre{a,b,c}post` the way the shell does before
# globbing, so `cat ~/.{npmrc,ssh/id_rsa}` is seen as the two paths it names.  The
# shared tokenizer splits a bare `{`/`}` as a group boundary, which would scatter a
# brace list across stages; expanding here, in secrets-guard only, keeps that
# tokenizer behaviour for every other guard.  Quote-aware (a brace inside '…'/"…" is
# literal), skips `${VAR}` and a `{ cmd; }` group (a blank or no comma inside), one
# level per pass, bounded — nested or multiplicative braces are rare and each
# expansion is still checked.
function brace_expand(s,   iter) {
  for (iter = 0; iter < 24; iter++) { if (!brace_once(s)) break; s = BE_OUT }
  return s
}
function brace_once(s,   L, i, c, q, depth, j, comma, pre, post, nseg, SEG, k, ws, we, out) {
  L = length(s); q = ""
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; else if (c == "\\" && q == "\"") i++; continue }
    if (c == SQ || c == "\"") { q = c; continue }
    if (c == "\\") { i++; continue }
    if (c == "$" && substr(s, i + 1, 1) == "{") { i++; continue }   # ${VAR}, not a brace list
    if (c != "{") continue
    depth = 1; comma = 0
    for (j = i + 1; j <= L; j++) {
      c = substr(s, j, 1)
      if (c == "{") depth++
      else if (c == "}") { if (--depth == 0) break }
      else if (c == "," && depth == 1) { if (comma == 0) comma = 1 }
      else if ((c == " " || c == "\t" || c == "\n") && depth == 1) comma = -1   # a space/newline => a group, not a list
    }
    if (depth != 0 || comma != 1) continue
    ws = i; while (ws > 1 && substr(s, ws - 1, 1) !~ /[ \t\n;&|<>()]/) ws--
    we = j; while (we < L && substr(s, we + 1, 1) !~ /[ \t\n;&|<>()]/) we++
    pre = substr(s, ws, i - ws); post = substr(s, j + 1, we - j)
    nseg = split(substr(s, i + 1, j - i - 1), SEG, ",")
    out = ""
    for (k = 1; k <= nseg; k++) out = out (k > 1 ? " " : "") pre SEG[k] post
    BE_OUT = substr(s, 1, ws - 1) out substr(s, we + 1)
    return 1
  }
  return 0
}
function glob_hits(a,   g, re, bn, bre, i, j) {
  g = a
  sub(/^\$\{HOME\}/, "~", g); sub(/^\$HOME/, "~", g)      # fold the home var to ~
  if (!has_glob(g)) return 0
  re = "^" glob_to_re(g) "$"
  # A credential-distinctive PATH (`~/.config/solana/*.json`, `~/.ss*/id_rsa`): a
  # glob whose own structure reaches the protected path.  But a bare wildcard
  # (`cat *`, `cat src/*`) also matches `.npmrc`/`_netrc` here, and it is not a
  # read — it only "could" name a credential the way any `cat *` could.  So a path
  # that also names an ordinary project file (BENIGNW) is a generic wildcard, not
  # a targeting one, and is not blocked; the red team's holes carry literal
  # credential text and match no benign control, so they still fire.
  for (i = 1; i <= GLOBWN; i++) if (GLOBW[i] ~ re) {
    for (j = 1; j <= BENIGNWN; j++) if (BENIGNW[j] ~ re) return 0
    return 1
  }
  bn = g; sub(/^.*\//, "", bn)                            # the basename alone
  if (has_glob(bn)) {
    bre = "^" glob_to_re(bn) "$"
    # The same discrimination on the BASENAME branch (the extension families):
    # `*.pem` matches `x.pem` and no benign basename, so it is a read; a bare `*`
    # or `src/*` matches `x.pem` AND `index.js`, so it is a generic wildcard.
    for (i = 1; i <= GLOBEN; i++) if (GLOBE[i] ~ bre) {
      for (j = 1; j <= BENIGNEN; j++) if (BENIGNE[j] ~ bre) return 0
      return 1
    }
  }
  return 0
}
# glob_witnesses — build GLOBW (full protected paths, in the prefix forms a glob
# carries) and GLOBE (protected basenames, for the extension families).  Run once
# from BEGIN.  HOME lets an absolute glob of the real home dir resolve too.
function glob_witnesses(   home, np, P, i, pf, npf, PF, j, be, E, k, nb, BW, bnm) {
  home = ENVIRON["HOME"]
  # One canonical path per vault alternative (dirs carry a child; names are whole).
  np = split(".ssh/id_rsa .gnupg/key .aws/credentials .config/solana/id.json " \
             ".npmrc .netrc _netrc .git-credentials .config/gh/hosts.yml .config/gh/hosts.yaml " \
             ".kube/config .cargo/credentials .cargo/credentials.toml .docker/config.json " \
             ".pypirc .gem/credentials .claude/.credentials.json Library/Keychains/login.keychain-db " \
             ".local/share/keyrings/x .gnome2/keyrings/x .password-store/x " \
             ".zsh_history .bash_history .python_history .node_repl_history .psql_history " \
             ".sqlite_history .lesshst .rediscli_history .mysql_history .zhistory fish/fish_history", P, " ")
  GLOBWN = 0
  for (i = 1; i <= np; i++) {
    npf = split("B ~ H .", PF, " ")                       # bare, ~/P, $HOME/P, ./P
    for (j = 1; j <= npf; j++) {
      if (PF[j] == "B") GLOBW[++GLOBWN] = P[i]
      else if (PF[j] == "~") GLOBW[++GLOBWN] = "~/" P[i]
      else if (PF[j] == ".") GLOBW[++GLOBWN] = "./" P[i]
      else if (PF[j] == "H" && home != "") GLOBW[++GLOBWN] = home "/" P[i]
    }
  }
  # The extension families the vault regex pins by basename.  `x.key` is NOT here:
  # .key is not in kit_vault_re (it is exfil-only, kit_secret_re), so `cat x.key`
  # is not a read-block and `cat *.key` must agree with it — one spelling of an act.
  be = split("x.pem x.p12 x.pfx x.jks x.keystore x.kdbx x.asc x.ppk login.keychain login.keychain-db", E, " ")
  GLOBEN = 0
  for (k = 1; k <= be; k++) GLOBE[++GLOBEN] = E[k]

  # Benign controls for glob_hits' generic-wildcard test: ordinary project files a
  # catch-all glob also covers.  Built in the forms a glob carries (bare, ./P, and
  # the real home dir) with the basename alone for the extension branch.  NONE is a
  # home dotfile on purpose: `cat ~/.*` must stay a read, so a benign `~/.x` here
  # would open a hole rather than close friction.
  nb = split("index.js index.ts main.rs app.tsx bundle.js styles.css package.json " \
             "tsconfig.json Cargo.toml README.md lib.rs schema.json out.txt data.csv " \
             "src/index.ts dist/bundle.js app/page.tsx docs/guide.md target/debug/app", BW, " ")
  BENIGNWN = 0; BENIGNEN = 0
  for (i = 1; i <= nb; i++) {
    BENIGNW[++BENIGNWN] = BW[i]
    BENIGNW[++BENIGNWN] = "./" BW[i]
    if (home != "") BENIGNW[++BENIGNWN] = home "/" BW[i]
    bnm = BW[i]; sub(/^.*\//, "", bnm)
    BENIGNE[++BENIGNEN] = bnm
  }
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

# ---- shell, a hard block at every tier when it runs a program the matcher cannot read.
#
# A shell (bash/sh/zsh/dash/ksh, and ash/fish) runs a program no permission rule can
# read when it is given one inline with -c or fed one through stdin.  The permission
# layer denies `sh -c *`, `bash -lc *` and `zsh -c *` at every tier (DENY_WRAPPERS) and
# `bash -c *` at Medium and High (DENY_BASH_C), and this block is the layer behind them:
# on the Bash-tool and MCP surface, where this hook fires, such an invocation is denied
# at every tier including Off — the forms the rules name and the ones they never covered
# alike.  For `bash -c` at Off and Relaxed, and for every form in a plugin install, which
# ships no permission rules, it is the only layer.  The one memsearch line is cleared
# (kit_allow) in secrets-guard.sh before this awk runs.
#
# Three un-inspectable shapes, all read through lib-tokenize.awk's shared helpers so they
# agree with #294's heredoc reader on what a shell runs:
#   * an inline -c string (hd_inline_flag), past a separate-word option before it
#     (`bash -O extglob -c …`, `--rcfile F -c …` — hd_optarg);
#   * a program read from stdin: a bare shell, `-s`, a `<` redirection, and so the shell
#     end of `… | bash` (each pipeline stage is scanned on its own);
#   * `busybox sh`/`busybox ash`, where the applet is the real shell.
# A shell given a script path argument (`bash x.sh`) runs that file, which the rules and
# the sandbox still see, so it is left alone.  A variable-named shell (`"$SHELL" -c`) a
# static matcher cannot resolve; that residual is documented in docs/firewall.md.
function is_cshell(c) { return (is_shell(c) || c == "ash") }     # is_shell adds fish
function shellc_hit(T, n,   ci, w, r) {
  ci = first_word(T, n)
  while (ci <= n) {
    w = base(T[ci])
    if (w == "busybox" && ci < n && is_cshell(base(T[ci + 1]))) { ci++; w = base(T[ci]) }
    if (is_cshell(w)) return shellc_shell(T, n, ci)
    if (!is_wrapper(w)) return 0
    ci++
    while (ci <= n && T[ci] ~ /^-/) { if (kit_wrapper_optarg(w, T[ci]) && ci < n) ci++; ci++ }   # walk a wrapper's options
    while (ci <= n && (r = kit_redir(T, n, ci)) > 0) ci += r
    if (ci <= n && kit_wrapper_operand(w, T[ci])) ci++
    while (ci <= n && (T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || kit_reserved(T[ci]))) ci++
  }
  return 0
}
# shellc_shell — the shell at T[ci] runs an un-inspectable program: 1 for an inline -c,
# 2 for a program read from stdin, 0 for a script path.  The two are told apart so the
# deny names what the command does: `… | base64 -d | sh` has no -c in it.  The -c and
# option-value tests are lib-tokenize.awk's (hd_inline_flag, hd_optarg).
#
# -s does not end the walk here: `bash -s -c 'id'` runs the -c string, so a -c anywhere
# in the options wins and the stdin verdict stands only when none follows.  After -s,
# `--` or the first operand ends the options: what follows is positional parameters
# (`bash -s -- -c x` is a stdin program with $1=-c), so the walk ends as stdin.  This
# differs from the heredoc reader, whose walk in lib-tokenize.awk still stops at -s;
# both deny, since a shell -c and a stdin program are refused at every tier, so only
# the message the agent sees depends on which shape is named.
function shellc_shell(T, n, ci,   w, i, t, r, s) {
  w = base(T[ci]); s = 0
  for (i = ci + 1; i <= n; i++) {
    t = T[i]
    if ((r = kit_redir(T, n, i)) > 0) { i += r - 1; continue }   # `bash < f`: reads stdin
    if (s && t == "--") return 2                                  # after -s, `--` ends options
    if (hd_inline_flag(w, t)) return 1                            # -c, -lc, -ic …
    if (t ~ /^-[A-Za-z]*s[A-Za-z]*$/) { s = 1; continue }        # -s reads stdin, unless a -c follows
    if (t ~ /^[-+]/) { if (hd_optarg(w, 1, t)) i++; continue }   # a separate-word option takes a value
    if (s) return 2                                               # after -s an operand is an argument
    return 0                                                      # a script path: its file, not stdin
  }
  return 2                                                        # no script arg, or -s: reads stdin
}

BEGIN { VAULTRE = ENVIRON["KIT_VAULT_RE"]; glob_witnesses() }
{ raw = raw $0 "\n" }
END {
  if (VAULTRE == "") exit 0

  # Heredoc BODIES go first: a document that merely names a credential path must
  # never fire.  A body that something runs is code and is inspected (the
  # library's hd_strip, which calls hd_interp_line above for an interpreter's).
  # Continuations are joined before that, so a head split over two lines
  # (`bash \<newline><<'EOF'`) is still read as one.
  text = split_cmd(brace_expand(hd_strip(kit_shell_text(raw, 0), 0)))
  if (HD_HIT != "") { print "DENY a heredoc fed to " HD_WHO " reads a credential path: " unmark(HD_HIT); exit }
  # Regex separators: macOS's awk also splits a one-character string separator
  # on newline, which cut a multi-line quoted argument into statements there.
  # A shell's -c string adds its own statements after them (kit_expand_code).
  nst = split(text, ST, /\001/)
  nst = kit_expand_code(ST, nst)
  # Too deeply nested to read in time: refuse rather than scan a fraction and miss
  # the credential read in the unread inner code.  "DEEP" so secrets-guard.sh denies.
  if (KIT_DEEP) { print "DEEP"; exit }

  # Shell -c: hard block at every tier (see is_cshell/shellc_hit above). Scanned
  # after kit_expand_code, so a `bash -c` reached through eval or a nested -c is
  # caught by its expanded statement too. The memsearch line never reaches here
  # (secrets-guard.sh allows it first), so any shell -c that does is denied.
  for (q = 1; q <= nst; q++) {
    shc = split(ST[q], SHG, /\002/)
    for (g = 1; g <= shc; g++) {
      sn = tokenize(SHG[g], ST_T); if (sn == 0) continue
      shk = shellc_hit(ST_T, sn)
      if (shk == 1) { print "SHELLC a shell -c invocation runs a program the firewall cannot inspect"; exit }
      if (shk == 2) { print "SHELLIN a shell reads its program from stdin, which the firewall cannot inspect"; exit }
    }
  }

  for (q = 1; q <= nst; q++) {
    nstg = split(ST[q], STG, /\002/)

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
        # A pattern tool's first positional is its program/script, even when empty.
        # `sed '' f`, `sed -n '' f`, `awk 1 f` must still have f checked, so the
        # program consumes the pattern slot here rather than the empty string being
        # dropped below (where the file would then be read as the pattern and skipped).
        if (pat && skipfirst && i >= patfrom && a !~ /^-/) { skipfirst = 0; continue }
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
