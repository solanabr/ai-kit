# kit-code-size.awk — whether a Bash command is small enough for the guards to read
# in time, for lib-headless.sh's kit_size_cap: prints "ok" when the code in it, its
# length less the heredoc bodies every guard copies rather than parses, is within
# KIT_CODE_LIMIT bytes, and "over" otherwise.  Run with lib-tokenize.awk, which
# calls back into the two functions below.  There is no line limit: the guards
# join their input once (kit_cat), so the 262,144 empty lines 256 KB can hold cost
# each whole hook about 1.5 s of CPU, where appending a line at a time had cost 10 s
# (#300).  This file reads line by line, and stops counting once the code limit is
# passed.
#
# It leaves a body out only when all of these hold, so a mistake here can only
# refuse more:
#   - the shell reads the `<<` as an operator (kit_hd_ops), outside every quote,
#     $( ), ( ) and `…`.  Inside a substitution the body's output may run as code:
#     `bash -c "$(cat <<'EOF' …)"`;
#   - the command it feeds is cat or tee, named as the command word itself,
#     and the line has no `|`, `(` or backquote, so nothing hands the body to a
#     program that runs it (`cat <<'EOF' | bash`).  Not behind a wrapper or a
#     shell: the guards disagree on which words to look past, and egress-guard
#     reads `bash cat <<EOF` as a body fed to bash, so it parsed one this file
#     had left out and ran past its timeout;
#   - it is the only heredoc on its line, and that line neither continues onto
#     the next nor is continued from the last: the guards read a continued line
#     joined, so `bash \<newline>cat <<'EOF'` is a heredoc fed to bash;
#   - its delimiter is quoted, or the body holds no $( or backquote, since an
#     unquoted body runs its substitutions and the guards read those as code;
#   - the delimiter line arrives.  An unterminated body counts.
function kit_wrapper(c) { return (is_wrapper(c) || is_shell(c)) }
function hd_interp_line(w, l) { return l }
function code_line(l,   np, hs, HS, hn, HT, HQ, hw, x, wascont, fw) {
  if (delim != "") {
    if (kit_hd_end(l, delim, dash)) { delim = ""; SIZE += length(l) + 1; return }
    if (!exempt) { SIZE += length(l) + 1; return }
    pend += length(l) + 1
    if (!quoted && (index(l, "$(") || index(l, "`"))) { exempt = 0; SIZE += pend; pend = 0 }
    return
  }
  SIZE += length(l) + 1
  if (SIZE > LIMIT) return
  np = kit_hd_ops(l, q); q = KH_QEND
  # Ending in a backslash outside '…' continues the line, as the shell reads it.
  wascont = cont; cont = (l ~ /\\$/ && q !~ /s$/)
  if (np == 0) return
  # A delimiter the shared parser cannot read is no opener, so the body counts.
  if (!kit_hd_delim(substr(l, KH_P[1]))) return
  quoted = KHD_QUOTED; dash = KHD_DASH
  hs = split(split_cmd(substr(l, 1, KH_P[1] - 1)), HS, /\001/)
  hs = split(HS[hs], HS, /\002/); hn = tokenize(HS[hs], HT, HQ)
  fw = first_word(HT, hn); hw = (fw <= hn) ? base(HT[fw]) : ""
  x = l; gsub(/\|\|/, "", x)
  exempt = (np == 1 && !cont && !wascont && KH_S[1] == "" && (hw == "cat" || hw == "tee") && x !~ /[|(`]/)
  delim = KHD_DELIM; pend = 0
}
BEGIN {
  LIMIT = ENVIRON["KIT_CODE_LIMIT"] + 0
  if (LIMIT < 1) LIMIT = 32768
  SIZE = 0; q = ""; delim = ""; cont = 0
}
SIZE <= LIMIT { code_line($0) }
END {
  # An unterminated body counts: nothing proves it is only data.
  if (delim != "" && exempt) SIZE += pend
  print (SIZE <= LIMIT) ? "ok" : "over"
}
