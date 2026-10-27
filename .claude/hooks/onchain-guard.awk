# onchain-guard.awk — statement normaliser for the on-chain write gate.
#
#   awk -f lib-tokenize.awk -f onchain-guard.awk
#
# stdin : raw command text.  stdout: the same text with leading VAR= assignments
# kept, wrapper binaries and their options dropped, whitespace runs collapsed,
# and statement separators preserved, and every heredoc body reduced to what
# runs (the library's hd_strip, #166): a document whose line begins with a gated
# verb is not a statement, while `bash <<'EOF' … solana program deploy … EOF`
# still is.
#
# Why this is NOT the shared tokenizer, even after #138 extracted one.
#
# The gate downstream is a position-anchored egrep: the gated verb has to START a
# statement.  That design needs the separators left IN the text, which split_cmd
# deliberately replaces with \001/\002.
#
# So this file takes from the library only what it can take identically — base(),
# is_wrapper(), is_shell(), kit_wrapper_optarg() and the heredoc reader, hd_strip
# — and keeps its own pass.  Rewriting it onto
# split_cmd is a behaviour change to the mainnet gate and belongs in its own
# change, with its own test corpus, not in a refactor.
#
# What it does take since: kit_shell_text, which joins backslash-newline
# continuations before anything else reads the text, and kit_qscan, which tells
# the pass below whether a statement starts in code or inside a quoted argument.
# A reserved word leading a statement (`if true; then anchor deploy …`) is
# dropped like a wrapper, but only in code: the split below is quote-blind on
# purpose, so `git commit -m "…; then anchor deploy …"` reaches strip() too.

# ---- the library's callbacks.  cmdword_x is never reached from here, but awk
# resolves a call lazily and a stray one would be a runtime error, so its
# kit_wrapper is defined.  hd_interp_line, which hd_strip calls, is below.
function kit_wrapper(b) { return wrapper(b) }

# wrapper — what this gate looks past.  The library's is_wrapper is exactly the
# non-shell half of the list this file used to carry; is_shell adds sh/bash/dash/
# zsh/ksh, and `ash` (BusyBox) is named here because the library's is_shell does
# not list it.  is_shell DOES list `fish`, which this file's own copy lacked — the
# one widening the extraction makes, and a plain fix: `fish -c "solana program
# deploy --url mainnet-beta"` made the gate silent before.
function wrapper(b) { return (is_wrapper(b) || is_shell(b) || b == "ash") }

# The options of those wrappers that swallow the next word (env -u HOME,
# xargs -I {}, nice -n 5, sudo -u me) are the library's kit_wrapper_optarg, the
# table this file carried first and lib-tokenize.awk now shares with the git gates.
#
# cmd is 1 when st starts in code, which is when a reserved word leading it is
# grammar to drop rather than text to keep.  ST_PAYLOAD comes back as the position
# in st of the quote that opens a wrapper's payload (`bash -c "…`), or 0, so the
# caller can read that quote as code and the rest of the payload with it.
function strip(st, cmd,   n, A, i, j, w, b, cur, hadw, keep, out, r) {
  n = split(st, A, /[ \t\r]+/)
  i = 1
  while (i <= n && A[i] == "") i++
  keep = ""; hadw = 0; ST_PAYLOAD = 0
  while (i <= n) {
    w = A[i]; b = base(kit_unq(w))
    # VAR=value is kept, not dropped: the cluster resolver in onchain-guard.sh
    # reads ANCHOR_PROVIDER_URL= out of this string, and the regex already allows
    # a run of assignments in front of the verb.
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep w " "; i++; continue }
    # A redirection is not the command (#287): `2>/dev/null anchor deploy …`.
    if (cmd && (r = kit_lead_redir(A, n, i)) > 0) { i += r; continue }
    # `coproc NAME { … }` and `function NAME` are headers; the command follows.
    if (cmd && w == "coproc" && i + 2 <= n && A[i + 2] == "{") { i += 2; continue }
    if (cmd && kit_reserved(w)) { i++; continue }
    if (cmd && w == "function" && i < n) { i += 2; continue }
    if (!wrapper(b)) break
    cur = b; hadw = 1; i++
    while (i <= n) {
      if (A[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep A[i] " "; i++; continue }
      if (A[i] == "--") { i++; break }
      if (A[i] ~ /^[-+]/) { if (kit_wrapper_optarg(cur, A[i]) && i < n) i++; i++; continue }
      break
    }
    # One operand at most: timeout's duration, flock's lock file.
    while (i <= n && (r = kit_lead_redir(A, n, i)) > 0) i += r
    if (i <= n && kit_wrapper_operand(cur, A[i])) i++
  }
  # The command word as the shell looks it up (#293), unless a shell or eval took
  # it as the payload whose opening quote is read below.
  if (cmd && i <= n && !(hadw && (is_shell(cur) || cur == "ash" || cur == "eval") && A[i] ~ /^["\047]/)) A[i] = kit_unq(A[i])
  # And every word after it (#297): `anchor "deploy" …` is anchor deploy.
  if (cmd) for (j = i + 1; j <= n; j++) A[j] = kit_unq(A[j], 1)
  out = ""
  for (j = i; j <= n; j++) out = out (out == "" ? "" : " ") A[j]
  # A wrapper was consumed, so a quote here opens its payload (sh -c "solana
  # ...") rather than being part of the command word.
  if (hadw && sub(/^["\047]/, "", out)) {
    ST_PAYLOAD = field_pos(st, i)
    if (cmd) out = kit_unreserve(out)
  }
  return keep out
}
# field_pos — where field i of split(s, A, /[ \t\r]+/) starts in s.
function field_pos(s, i,   p, f) {
  p = 1
  for (f = 1; f < i; f++) {
    if (!match(substr(s, p), /[ \t\r]+/)) return 0
    p += RSTART + RLENGTH - 1
  }
  return p
}
# An interpreter's heredoc keeps its brackets and loses its string delimiters,
# the shape lib-headless.sh gives a non-shell MCP payload for this gate:
# os.system("solana program deploy …") then anchors on its `(`.
function hd_interp_line(w, l) { gsub(/["\047]/, "", l); gsub(/[][,]/, " ", l); return l }

# norm — print text a line at a time, each statement through strip().  qs is the
# quote stack carried from statement to statement and line to line: a statement
# starting inside a plain quote is an argument, so its leading `then` stays and
# the regex never anchors on it.
function norm(text,   nl, LN, k, line, out, st, sep, cmd, qs) {
  nl = split(text, LN, "\n")
  qs = ""; KP = ""
  for (k = 1; k <= nl; k++) {
    line = LN[k]; out = ""
    if (k == nl && line == "") break
    KQ_PREV = ""; KQ_COMMENT = 0
    while (length(line)) {
      if (kit_sep(line)) {
        st = substr(line, 1, RSTART - 1)
        sep = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      } else { st = line; sep = ""; line = "" }
      cmd = !KQ_COMMENT && kit_code_top(qs)
      out = out strip(st, cmd)
      out = out kit_stmt_sep(st, sep, qs, ST_PAYLOAD)
      qs = kit_qscan(st sep, qs, ST_PAYLOAD)
    }
    # Buffered, not printed, so a command found too deeply nested below can be
    # refused as a whole instead of handing the gate a half-read normalisation.
    NORMOUT = NORMOUT out "\n"
  }
}

{ KIT_RAW[NR] = $0 }
END {
  raw = kit_raw()
  # Continuations are joined first, so a heredoc head split over two lines is
  # still one head to hd_strip.  Every code string another program runs follows
  # as text of its own, read the same way and under the same bound as
  # kit_shell_text's: in place a quoted argument, `git submodule foreach '…
  # --final'`, `flock /tmp/l -c '… --final'` and `git rebase --exec '… --final'
  # main` were silent at every tier, and `sh -c 'anchor deploy'` kept its closing
  # quote against the verb, so the anchored pattern never matched it.  CD[k] is the
  # depth of payload C[k]; past KIT_MAXDEPTH, or the byte budget, reading stops and
  # the command is refused (a deploy could be hiding in the unread inner code).
  text = hd_strip(kit_shell_text(raw, 0), 0)
  norm(text)
  nc = kit_payloads(text, C, 0); left = 8 * length(raw) + 4096
  for (k = 1; k <= nc; k++) CD[k] = 1
  for (k = 1; k <= nc; k++) {
    if ((left -= length(C[k])) < 0) { KIT_DEEP = 1; break }
    text = hd_strip(kit_shell_text(C[k], 0), 0)
    norm(text)
    # Refused only on a code string actually found one deeper (kit_shell_text says why).
    nc2 = kit_payloads(text, C, nc)
    if (nc2 == nc) continue
    if (CD[k] >= KIT_MAXDEPTH) { KIT_DEEP = 1; continue }
    for (j = nc + 1; j <= nc2; j++) CD[j] = CD[k] + 1
    nc = nc2
  }
  # A control char the normalised text never carries, so onchain-guard.sh can tell
  # the refusal from a command that merely prints this word.
  if (KIT_DEEP) printf "%cKITDEEP\n", 1
  else printf "%s", NORMOUT
}
