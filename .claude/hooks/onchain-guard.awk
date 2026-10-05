# onchain-guard.awk — statement normaliser for the on-chain write gate.
#
#   awk -f lib-tokenize.awk -f onchain-guard.awk
#
# stdin : raw command text.  stdout: the same text with leading VAR= assignments
# kept, wrapper binaries and their options dropped, whitespace runs collapsed,
# and statement separators preserved.
#
# Why this is NOT the shared tokenizer, even after #138 extracted one.
#
# The gate downstream is a position-anchored egrep: the gated verb has to START a
# statement.  That design needs the separators left IN the text, which split_cmd
# deliberately replaces with \001/\002, and it needs heredoc bodies left alone.
# Dropping heredoc bodies here would fix a known false positive (a document whose
# line begins with a gated verb is matched as a statement) but would also lose a
# case tests/test_hooks.sh asserts: `bash <<'EOF' … solana program deploy … EOF`
# must still ask, because that body really does execute.  A quoted delimiter is
# the tokenizer's signal for "prose", and here it is not prose.
#
# So this file takes from the library only what it can take identically — base(),
# is_wrapper() and is_shell() — and keeps its own pass.  Rewriting it onto
# split_cmd is a behaviour change to the mainnet gate and belongs in its own
# change, with its own test corpus, not in a refactor.

# ---- the library's callbacks.  cmdword_x and strip_heredocs are never reached
# from here, but awk resolves a call lazily and a stray one would be a runtime
# error, so both are defined.
function kit_wrapper(b) { return wrapper(b) }
function kit_heredoc_is_code(b) { return is_shell(b) }

# wrapper — what this gate looks past.  The library's is_wrapper is exactly the
# non-shell half of the list this file used to carry; is_shell adds sh/bash/dash/
# zsh/ksh, and `ash` (BusyBox) is named here because the library's is_shell does
# not list it.  is_shell DOES list `fish`, which this file's own copy lacked — the
# one widening the extraction makes, and a plain fix: `fish -c "solana program
# deploy --url mainnet-beta"` made the gate silent before.
function wrapper(b) { return (is_wrapper(b) || is_shell(b) || b == "ash") }

# Options of those wrappers that swallow the next word, so the word is not
# mistaken for the command: env -u HOME, xargs -I {}, nice -n 5, sudo -u me.
function optarg(b, f) {
  return (b == "env" && f ~ /^(-u|-C|--unset|--chdir)$/) \
      || (b == "xargs" && f ~ /^(-I|-L|-n|-P|-s|-d|-E|-a|-J|-R|-S)$/) \
      || ((b == "sudo" || b == "doas") && f ~ /^-[ugphCDrtTU]$/) \
      || (b == "nice" && f == "-n") || (b == "timeout" && f ~ /^-[sk]$/) \
      || (b == "stdbuf" && f ~ /^-[ioe]$/) || (b == "exec" && f == "-a") \
      || (b == "time" && f ~ /^-[fo]$/)
}
function strip(st,   n, A, i, j, w, b, cur, hadw, keep, out) {
  n = split(st, A, /[ \t\r]+/)
  i = 1
  while (i <= n && A[i] == "") i++
  keep = ""; hadw = 0
  while (i <= n) {
    w = A[i]; b = base(w)
    # VAR=value is kept, not dropped: the cluster resolver in onchain-guard.sh
    # reads ANCHOR_PROVIDER_URL= out of this string, and the regex already allows
    # a run of assignments in front of the verb.
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep w " "; i++; continue }
    if (!wrapper(b)) break
    cur = b; hadw = 1; i++
    while (i <= n) {
      if (A[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep A[i] " "; i++; continue }
      if (A[i] == "--") { i++; break }
      if (A[i] ~ /^[-+]/) { if (optarg(cur, A[i]) && i < n) i++; i++; continue }
      if (cur == "timeout" && A[i] ~ /^[0-9]/) { i++; continue }
      break
    }
  }
  out = ""
  for (j = i; j <= n; j++) out = out (out == "" ? "" : " ") A[j]
  # A wrapper was consumed, so a quote here opens its payload (sh -c "solana
  # ...") rather than being part of the command word.
  if (hadw) sub(/^["\047]/, "", out)
  return keep out
}
{
  line = $0; out = ""
  while (length(line)) {
    if (match(line, /(\|\||&&|\$\(|[;&|()])/)) {
      st = substr(line, 1, RSTART - 1)
      sep = substr(line, RSTART, RLENGTH)
      line = substr(line, RSTART + RLENGTH)
    } else { st = line; sep = ""; line = "" }
    out = out strip(st) sep
  }
  print out
}
