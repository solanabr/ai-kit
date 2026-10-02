# egress-guard.awk — outbound-data guard for the Bash tool.
#
# Decides on ARGUMENT POSITION, never on prose.  Documentation that merely
# mentions or demonstrates an exfil command must never be blocked.
#
# stdin : raw Bash command text (one Bash tool call)
# stdout: "<CLASS> <reason>", or nothing at all
#   DENY  a secret reaches a network command — as a body, as an argument, via a
#         reader in the same statement, or named in inline interpreter code
#   ASK1  a request body or upload sourced from a file or from stdin
#   ASK2  an inline request body (literal data)
#   ASK3  no body, but an expansion ($VAR / $(...)) rides in the request
# env   : KIT_SECRET_RE  egrep-style regex matching secret FILE PATHS
#         KIT_MAXCLASS   1 = ASK1 only (Relaxed), 2 = +ASK2 (Medium), 3 = +ASK3 (High)
#         (both travel in the environment: awk -v performs escape processing,
#          which mangles \. and \( differently from one awk to the next)
#
# Separators: \001 = statement boundary (data cannot flow across)
#             \002 = stage boundary inside one statement (data CAN flow across)
#             \003 = a backslash-escaped space that must not split a token

function base(p) { sub(/^\\/, "", p); sub(/^.*\//, "", p); return p }
function unmark(s) { gsub(/\003/, " ", s); return s }

# A URL or an scp/ssh remote spec is a destination, never a local file path.
# Without this, `curl -sL https://docs.example.com/.aws/guide.html` reads as an
# attempt to exfiltrate ~/.aws.
function looks_remote(a) {
  return (a ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\// || a ~ /^[^\/ ]+@[^\/ ]+:/)
}

# ---------------------------------------------------------------- quote-aware split
# Honours SQ...SQ (fully literal) and "..." (literal except $( ) and backticks).
function split_cmd(s,   i, c, c2, st, sp, out, j) {
  out = ""; sp = 0; st[0] = "code"
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1); c2 = substr(s, i, 2)
    if (st[sp] == "sq") { out = out c; if (c == SQ) sp--; continue }
    if (st[sp] == "dq") {
      if (c == "\\" && i < length(s)) { out = out substr(s, i+1, 1); i++; continue }
      if (c2 == "$(") { out = out " $__X__\002 "; st[++sp] = "code"; i++; continue }
      if (c == "`")    { out = out " $__X__\002 "; st[++sp] = "bt";   continue }
      if (c == "\"")   { sp--; out = out c; continue }
      out = out c; continue
    }
    if (c == "\\" && i < length(s)) {
      i++; c = substr(s, i, 1)
      if (c == " ") out = out "\003"; else out = out c
      continue
    }
    if (c == SQ)    { st[++sp] = "sq"; out = out c; continue }
    if (c == "\"")  { st[++sp] = "dq"; out = out c; continue }
    # ${VAR} is one token, not a brace group.
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

function tokenize(s, T,   i, c, q, cur, n, hadq) {
  n = 0; cur = ""; q = ""; hadq = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; else cur = cur c; continue }
    if (c == SQ || c == "\"") { q = c; hadq = 1; continue }
    if (c == " " || c == "\t") { if (cur != "" || hadq) { T[++n] = cur; cur = ""; hadq = 0 } ; continue }
    cur = cur c
  }
  if (cur != "" || hadq) T[++n] = cur
  return n
}

# cls: what a curl/wget flag does with its value.
function cls(f) {
  if (f == "T" || f == "upload-file" || f == "K" || f == "config" \
      || f == "post-file" || f == "body-file") return "FILE"
  if (f == "d" || f == "data" || f == "data-ascii" || f == "data-binary" \
      || f == "data-urlencode" || f == "json" || f == "url-query" \
      || f == "F" || f == "form" || f == "post-data" || f == "body-data") return "DATA"
  if (f == "data-raw" || f == "form-string") return "LIT"
  if (f == "H" || f == "header") return "HDR"
  return ""
}

function is_reader(c) {
  return (c == "cat" || c == "base64" || c == "gzip" || c == "gunzip" || c == "zstd" \
       || c == "xz" || c == "bzip2" || c == "xxd" || c == "od" || c == "hexdump" \
       || c == "strings" || c == "head" || c == "tail" || c == "cut" || c == "tr" \
       || c == "rev" || c == "tac" || c == "nl" || c == "jq" || c == "yq" || c == "dd" \
       || c == "openssl" || c == "gpg" || c == "uuencode" || c == "tar" || c == "zip")
}
function is_sender(c) { return (c == "curl" || c == "wget") }

# ---- destination awareness (see patch_egress.py for the rationale) -------------
function safe_host(h) {
  if (h == "") return 0
  return (h ~ /(^|\.)solana\.com$/ \
       || h ~ /(^|\.)helius-rpc\.com$/ || h == "api.helius.xyz" \
       || h ~ /(^|\.)quiknode\.pro$/   || h ~ /(^|\.)jup\.ag$/ \
       || h == "hermes.pyth.network"   || h == "release.solana.com" \
       || h == "localhost" || h ~ /^127\./ || h == "0.0.0.0" \
       || h == "github.com" || h == "api.github.com" || h == "codeload.github.com" \
       || h ~ /(^|\.)githubusercontent\.com$/ \
       || h ~ /(^|\.)npmjs\.org$/ || h ~ /(^|\.)crates\.io$/ \
       || h == "sh.rustup.rs" || h ~ /(^|\.)rust-lang\.org$/ \
       || h == "pypi.org" || h == "files.pythonhosted.org")
}

# Pull the host out of a token that looks like a URL or a bare host[:port].
function url_host(tok,   h) {
  h = tok
  if (h ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", h)
  else if (h !~ /\./ && h !~ /^localhost/) return ""
  sub(/[\/?#].*$/, "", h)
  sub(/^[^@]*@/, "", h)
  sub(/:[0-9]+$/, "", h)
  if (h ~ /[^A-Za-z0-9.:_-]/) return ""
  return tolower(h)
}
function is_interp(c) {
  return (c == "python" || c == "python2" || c == "python3" || c == "node" || c == "deno" \
       || c == "bun" || c == "perl" || c == "ruby" || c == "php" || c == "osascript")
}
function is_netcmd(c) {
  return (is_sender(c) || is_interp(c) || c == "nc" || c == "ncat" || c == "netcat" \
       || c == "socat" || c == "telnet" || c == "ssh" || c == "scp" || c == "sftp" \
       || c == "rsync" || c == "dig" || c == "nslookup" || c == "host" \
       || c == "gh" || c == "glab" || c == "aws" || c == "gsutil" || c == "az" \
       || c == "http" || c == "xh" || c == "ftp" || c == "lftp")
}
function is_netsink(c) { return (is_netcmd(c) && !is_interp(c)) }
function is_shell(c) {
  return (c == "sh" || c == "bash" || c == "zsh" || c == "dash" || c == "ksh" || c == "fish")
}
function is_wrapper(c) {
  return (c == "env" || c == "command" || c == "builtin" || c == "exec" || c == "nohup" \
       || c == "nice" || c == "time" || c == "timeout" || c == "stdbuf" || c == "xargs" \
       || is_shell(c) || c == "eval" || c == "sudo" || c == "doas" || c == "setsid")
}

# An interpreter is only a network sink when its inline code actually names a
# network API.  `cat .env | python3 -c "print(sys.stdin.read())"` is local work.
function code_has_net(a) {
  return (a ~ /urlopen|urlretrieve|urllib|requests\.|httpx|http\.client|socket\.|socket\(/ \
       || a ~ /fetch\(|XMLHttpRequest|axios|net\.connect|https?\.request|got\(/ \
       || a ~ /Net::HTTP|open-uri|LWP|HTTParty|websocket|WebSocket|sendto|smtplib/)
}

# Template and documentation suffixes are not secrets: this repo ships a
# .env.example and the docs name it.
function is_template(a) { return (a ~ /\.(example|sample|template|dist|tpl|md)$/) }

function arg_is_secret(a,   t) {
  if (SECRETRE == "") return 0
  if (looks_remote(a)) return 0
  a = unmark(a)
  if (!is_template(a) && a ~ SECRETRE) return 1
  t = a
  if (t ~ /[@=]/) { sub(/^.*[@=]/, "", t); if (!looks_remote(t) && !is_template(t) && t ~ SECRETRE) return 1 }
  return 0
}

# Scan an interpreter's inline code blob (python -c, node -e) for a secret path.
function code_has_secret(a,   i, n, P, t) {
  a = unmark(a)
  gsub(/[(),;]/, " ", a); gsub(SQ, " ", a); gsub(/"/, " ", a)
  n = split(a, P, /[ \t]+/)
  for (i = 1; i <= n; i++) {
    t = P[i]
    if (t != "" && !looks_remote(t) && !is_template(t) && t ~ SECRETRE) return t
  }
  return ""
}

# The literal first word, wrappers included.  cmdword() looks past shells on
# purpose (to reach `sh -c "<inner>"`), which is wrong when the question is
# "what is this heredoc being fed to".
function firstword(T, n,   ci) {
  ci = 1
  while (ci <= n && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ci++
  return (ci <= n) ? base(T[ci]) : ""
}

function cmdword(T, n,   ci, w) {
  ci = 1
  while (ci <= n) {
    while (ci <= n && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ci++
    if (ci > n) return ""
    w = base(T[ci])
    if (!is_wrapper(w)) { CWI = ci; return w }
    ci++
    while (ci <= n && T[ci] ~ /^-/) ci++
  }
  return ""
}

BEGIN {
  SQ = sprintf("%c", 39)
  SECRETRE = ENVIRON["KIT_SECRET_RE"]
  MAXCLASS = ENVIRON["KIT_MAXCLASS"] + 0
  if (MAXCLASS < 1) MAXCLASS = 1
  HD_DQ = "<<-?[ \t]*\"[A-Za-z_][A-Za-z0-9_]*\""
  HD_SQ = "<<-?[ \t]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
  HD_BARE = "<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*"
}
{ raw = raw $0 "\n" }
END {
  # ---- strip heredoc BODIES: a doc that merely SHOWS a curl must never fire.
  # Exception: an UNQUOTED delimiter feeding a shell or interpreter is code.
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
      hn = tokenize(split_cmd(substr(l, 1, RSTART - 1)), HT); hw = firstword(HT, hn)
      if (quoted || !(is_shell(hw) || is_interp(hw))) delim = d
    }
    text = text l "\n"
  }

  text = split_cmd(text)
  nst = split(text, ST, "\001")

  for (q = 1; q <= nst; q++) {
    stmt = ST[q]
    if (stmt !~ /[^ \t\002]/) continue
    nstg = split(stmt, STG, "\002")

    # unwrap one level of `sh -c "<inner>"` / eval: the inner string is code
    for (g = 1; g <= nstg && nstg < 64; g++) {
      n = tokenize(STG[g], T); if (n == 0) continue
      ci = 1
      while (ci <= n && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ci++
      if (ci > n) continue
      if (!is_wrapper(base(T[ci]))) continue
      for (i = ci + 1; i <= n; i++) if (T[i] ~ / / && T[i] !~ /^-/) { STG[++nstg] = split_cmd(T[i]); break }
    }

    # ---- pass 1: a secret reaching a network command
    leak = ""; sender = 0
    for (g = 1; g <= nstg; g++) {
      n = tokenize(STG[g], T); if (n == 0) continue
      c0 = cmdword(T, n); if (c0 == "") continue
      ci = CWI
      if (is_netsink(c0)) sender = 1

      if (is_reader(c0)) {
        for (i = ci + 1; i <= n; i++) {
          if (T[i] ~ /^-/) continue
          if (arg_is_secret(T[i])) { leak = T[i]; break }
        }
      }
      if (is_netcmd(c0)) {
        for (i = ci + 1; i <= n; i++) {
          a = T[i]
          if (a ~ /^-/ && a !~ /[@=]/) continue
          if (arg_is_secret(a)) { print "DENY secret path \"" unmark(a) "\" is an argument to network command " c0; exit }
          if (is_interp(c0)) {
            if (code_has_net(a)) sender = 1
            if ((t = code_has_secret(a)) != "") { print "DENY inline " c0 " code names a secret path: " t; exit }
          }
        }
      }
      if (match(STG[g], /<[ \t]*[^ \t<][^ \t]*/)) {
        a = substr(STG[g], RSTART, RLENGTH); sub(/^<[ \t]*/, "", a)
        if (arg_is_secret(a)) leak = a
      }
    }
    if (sender && leak != "") { print "DENY a secret file (" unmark(leak) ") is read into a network command in the same statement"; exit }

    # ---- pass 2: curl/wget flag analysis
    for (g = 1; g <= nstg; g++) {
      n = tokenize(STG[g], T); if (n == 0) continue
      if (!is_sender(cmdword(T, n))) continue     # <- prose can never reach here
      ci = CWI

      body = 0; inline = 0; src = ""; secret = ""; expand = 0; dest = ""
      for (i = ci + 1; i <= n; i++) {
        tok = T[i]; name = ""; val = ""; have = 0

        if (tok ~ /^--[A-Za-z]/) {
          name = tok; sub(/^--/, "", name)
          if (name ~ /=/) { val = name; sub(/^[^=]*=/, "", val); sub(/=.*$/, "", name); have = 1 }
          else if (i < n) { val = T[i+1]; have = 1 }
        } else if (tok ~ /^-[A-Za-z]/) {
          rest = tok; sub(/^-/, "", rest); j = 1
          while (j <= length(rest)) {
            ch = substr(rest, j, 1)
            if (cls(ch) != "") { name = ch; val = substr(rest, j + 1); if (val == "" && i < n) val = T[i+1]; have = 1; break }
            if (ch !~ /[A-Za-z]/) break
            j++
          }
        }

        if (have && (c = cls(name)) != "") {
          if (c == "FILE") {
            body = 1; f = val; sub(/^@/, "", f)
            if (f == "-") src = "stdin"
            else { if (src == "") src = f; if (arg_is_secret(f)) secret = f }
          } else if (c == "DATA") {
            body = 1
            if (val ~ /^@/ || val ~ /=@/ || val ~ /=</) {
              f = val; sub(/^.*[@<]/, "", f)
              if (f == "-") src = "stdin"
              else { if (src == "") src = f; if (arg_is_secret(f)) secret = f }
            } else inline = 1
            if (val ~ /\$/) expand = 1
          } else if (c == "LIT") {
            body = 1; inline = 1
            if (val ~ /\$/) expand = 1
          } else if (c == "HDR") {
            if (val ~ /^@/) {
              body = 1; f = val; sub(/^@/, "", f)
              if (f == "-") src = "stdin"
              else { if (src == "") src = f; if (arg_is_secret(f)) secret = f }
            } else if (val ~ /\$/) expand = 1
          }
        }
        if (tok ~ /\$/) expand = 1
        if (dest == "" && tok !~ /^-/) { h = url_host(tok); if (h != "") dest = h }
      }

      if (secret != "") { print "DENY request body is sourced from a secret file: " unmark(secret); exit }
      if (body && src == "stdin")       { print "ASK1 uploads piped stdin as a request body"; exit }
      else if (body && src != "")       { print "ASK1 uploads file \"" unmark(src) "\" as a request body"; exit }
      else if (body && inline) {
        if (expand)                     { print "ASK1 sends an expanded value as a request body"; exit }
        if (MAXCLASS >= 2 && !safe_host(dest)) { print "ASK2 sends an inline request body to " (dest == "" ? "an unparsed destination" : dest); exit }
      }
      else if (body && MAXCLASS >= 2 && !safe_host(dest)) { print "ASK2 sends a request body"; exit }
      else if (expand && MAXCLASS >= 3) { print "ASK3 an expansion rides in the request (possible GET-smuggled body)"; exit }
    }
  }
}
