# decisions-guard.awk — does a command run the decision record's helper to write?
#
#   awk -f lib-tokenize.awk -f decisions-guard.awk
#
# stdin : raw command text (one tool call)
# stdout: "WRITE <verb>" when a statement runs decisions.sh add or supersede, or nothing
#
# The helper counts only in command position, the way the firewall guards read
# theirs: as the command word past assignments, reserved words and wrappers, or as
# the script a shell or `.`/`source` runs, with the verb the word after it. Code a
# shell takes with -c, and eval's argument, are read as statements of their own
# (kit_expand_code). Heredocs are read through the library's shared reader, as the
# firewall guards read them (hd_strip): a body a shell runs is read as commands, a
# body an interpreter runs as its lines (hd_interp_line below), and any other body
# is a document. Everything else names the helper without running it, and passes: a
# grep pattern, a commit message, an echo, a document.
#
# The readers (in-force, hash, export, path, help) pass too: they write nothing an
# agent chose.

# ---- the library's callbacks. Every guard that includes lib-tokenize.awk defines
# both: awk stops at a call to a function nobody defined, and decisions-guard.sh
# reads a stopped awk as a command that writes nothing.
function kit_wrapper(w) { return is_wrapper(w) }
# An interpreter's heredoc line, in the shape lib-headless.sh gives a non-shell MCP
# payload: string delimiters out and brackets kept, so os.system("… decisions.sh add
# …") starts a statement of its own.
function hd_interp_line(w, l) { gsub(/["\047]/, "", l); return l }

# Compared without case: on a filesystem that folds it, DECISIONS.SH runs the helper.
function is_helper(t) { return (tolower(base(t)) == "decisions.sh") }
function writes(v) { return (v == "add" || v == "supersede") }

# script_at — index of the script that the shell, `.` or `source` at T[ci] runs, past
# the shell's options; 0 for inline code (-c), which kit_expand_code reads instead.
function script_at(T, n, ci, w,   i) {
  for (i = ci + 1; i <= n; i++) {
    if (T[i] == "--") return (i < n) ? i + 1 : 0
    if (w != "." && w != "source") {
      if (T[i] == "-o" || T[i] == "+o" || T[i] == "-O" || T[i] == "+O") { i++; continue }
      if (T[i] ~ /^-[A-Za-z]*c[A-Za-z]*$/) return 0
      if (T[i] ~ /^[-+]/) continue
    }
    return i
  }
  return 0
}

{ KIT_RAW[NR] = $0 }
END {
  raw = kit_raw()
  nst = split(split_cmd(hd_strip(kit_shell_text(raw, 0), 0)), ST, /\001/)
  nst = kit_expand_code(ST, nst)
  for (q = 1; q <= nst; q++) {
    ng = split(ST[q], G, /\002/)
    for (g = 1; g <= ng; g++) {
      n = tokenize(G[g], T, Q)
      if (n == 0) continue
      w = cmdword_x(T, n, 1, 1)
      if (w == "") continue
      i = 0
      if (is_helper(w)) i = CWI
      else if (is_shell(w) || w == "." || w == "source") {
        i = script_at(T, n, CWI, w)
        if (i && !is_helper(T[i])) i = 0
      }
      if (i && i < n && writes(T[i + 1])) { print "WRITE " T[i + 1]; exit }
    }
  }
}
