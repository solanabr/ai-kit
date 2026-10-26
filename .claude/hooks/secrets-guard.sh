#!/bin/sh
# secrets-guard.sh — PreToolUse(Bash): block reads of credential stores, key
# material and wallet vaults.  Active at every tier, including Off, because the
# never-allowed set does not vary by tier.  It also runs on the Read and Grep tools,
# for one file: gh's host file (see below).
#
# The invariant, and the whole reason this file replaced an inline grep:
#
#   a rule may match only a path in ARGUMENT POSITION of a command that would
#   touch that path — never the command's prose.
#
# Writing documentation, a commit message, an issue body or a test corpus that
# names a protected path is not access to it and must never be blocked.  The
# inline predecessor grepped the whole command string and produced five
# independent false positives in one session (a diagnostic `ls -l` on a wallet,
# a `gh issue create` body, the firewall spec itself, two test corpora), to the
# point where two shipped commands documented workarounds.
#
# Decisions come from an awk pass that quote-aware splits the command into
# statements and pipeline stages, strips heredoc bodies, finds each stage's real
# command word past env assignments and wrappers, and only then looks at that
# command's arguments.  The splitter now lives in lib-tokenize.awk, shared with
# the other guards (issue #138); the decision logic is secrets-guard.awk.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)

# ---- gh's host file: the Read and Grep tools, and context-mode's path readers.
#
# Off and Relaxed leave gh's host file readable so `gh` can start inside the sandbox
# (DENY_GH_HOSTS_READ in firewall.sh denies it at Medium and High only).  That opens it
# to Claude Code's file tools as well, and a Read or a Grep would put gh's login token in
# the transcript.  So both are refused on it here, at every tier: gh's own process keeps
# reading the file and the model does not.  At Medium and High the Read deny rule
# refuses the same calls, and this is a second layer.
#
# The file is gh's as gh resolves it: $GH_CONFIG_DIR/hosts.yml when GH_CONFIG_DIR is
# set, else ${XDG_CONFIG_HOME:-$HOME/.config}/gh/hosts.yml.  Paths are compared with
# `-ef`, which matches device and inode, so a symlink, a hard link, a $HOME spelling,
# `..` and another case on a case-insensitive volume all compare equal, with no fork.
# Each path is also compared after resolving `.` and `..` as text, in case the tool
# resolves them that way rather than as the kernel does through a symlinked directory.
#
# Grep reads every file under its search root, so a root that is the file or any
# directory above it is refused, on the spelled path and on the physical one.
# context-mode's `path` gets the same test, since ctx_index reads a whole directory.
# Glob is not registered: it returns names, never contents, so it cannot put the token
# in a transcript, and a hook on it would cost a process on every call for nothing.

# kit_gh_hosts — GH_HOSTS_LIST: every host file that may hold a gh token, one per line,
# only the ones that exist.  gh reads $GH_CONFIG_DIR/hosts.yml when GH_CONFIG_DIR is set,
# else ${XDG_CONFIG_HOME:-$HOME/.config}/gh/hosts.yml — but setting GH_CONFIG_DIR for one
# command does not move or empty the default file, which keeps its token and is still
# readable by the file tools, so the default ~/.config/gh/hosts.yml (and the XDG one) is
# protected whatever the env points at now.  GH_HAVE is set when the list is non-empty.
kit_gh_hosts() {
  GH_HOSTS_LIST= GH_HAVE=
  for _ghc in "${GH_CONFIG_DIR:+$GH_CONFIG_DIR/hosts.yml}" \
            "${XDG_CONFIG_HOME:-${HOME-}/.config}/gh/hosts.yml" \
            "${HOME-}/.config/gh/hosts.yml"; do
    [ -n "$_ghc" ] || continue
    case $_ghc in /*) ;; *) _ghc=$PWD/$_ghc ;; esac
    case "$GH_HOSTS_LIST" in *"$_ghc$KIT_NL"*) continue ;; esac   # dedup by exact string
    [ -e "$_ghc" ] || continue
    GH_HOSTS_LIST=$GH_HOSTS_LIST$_ghc$KIT_NL GH_HAVE=1
  done
}

# kit_lex <path> — KIT_LEX: the path with `.`, `..` and repeated `/` resolved as text.
kit_lex() {
  _rest=$1 KIT_LEX=
  while [ -n "$_rest" ]; do
    case $_rest in
      */*) _seg=${_rest%%/*} _rest=${_rest#*/} ;;
      *) _seg=$_rest _rest= ;;
    esac
    case $_seg in
      '' | .) ;;
      ..) KIT_LEX=${KIT_LEX%/*} ;;
      *) KIT_LEX=$KIT_LEX/$_seg ;;
    esac
  done
  [ -n "$KIT_LEX" ] || KIT_LEX=/
}

# kit_abs <path> — KIT_ABS: a leading ~ expanded, and a relative path anchored at the
# session's working directory.
kit_abs() {
  KIT_ABS=$1
  case $KIT_ABS in
    '~') KIT_ABS=${HOME-} ;;
    '~/'*) KIT_ABS=${HOME-}/${KIT_ABS#'~/'} ;;
  esac
  case $KIT_ABS in /*) ;; *) KIT_ABS=${KIT_CWD:-$PWD}/$KIT_ABS ;; esac
}

# kit_is_gh_hosts <path> — the path names one of the gh host files in GH_HOSTS_LIST.
kit_is_gh_hosts() {
  kit_abs "$1"
  kit_lex "$KIT_ABS"
  _ra=$KIT_ABS _rl=$KIT_LEX _rest=$GH_HOSTS_LIST
  while [ -n "$_rest" ]; do
    _h=${_rest%%"$KIT_NL"*} _rest=${_rest#*"$KIT_NL"}
    [ -n "$_h" ] || continue
    if [ "$_ra" -ef "$_h" ] || [ "$_rl" -ef "$_h" ]; then return 0; fi
  done
  return 1
}

# kit_gh_dirs <hostfile> — the directories a search of that host file must not start
# from, as three chain starts: GH_LDIR, the file's directory as spelled; GH_PDIR, the
# same directory with symlinks resolved; GH_TDIR, the directory of the file's own link
# target when it is a symlink.
kit_gh_dirs() {
  kit_lex "$1"
  GH_LDIR=${KIT_LEX%/*} GH_PDIR= GH_TDIR=
  [ -n "$GH_LDIR" ] || GH_LDIR=/
  _here=$PWD
  if CDPATH= cd -P -- "${1%/*}" 2>/dev/null; then GH_PDIR=$PWD; fi
  if [ -L "$1" ]; then
    _lt=$(readlink -- "$1" 2>/dev/null) || _lt=
    case $_lt in '' | /*) ;; *) _lt=${1%/*}/$_lt ;; esac
    if [ -n "$_lt" ] && CDPATH= cd -P -- "${_lt%/*}" 2>/dev/null; then GH_TDIR=$PWD; fi
  fi
  CDPATH= cd -- "$_here" 2>/dev/null || :
}

# kit_holds_gh_hosts <root> — a search from <root> reads a gh host file: the root is one
# of them, a directory on the way up from one of them to /, or a directory with an
# immediate child that is a symlink into one of them (a stow-style `config/gh` link, say).
# The sideways-symlink check is one level deep, which ripgrep and ctx_index reach only
# with --follow / followSymlinks; a symlink nested deeper is a residual, documented in
# docs/firewall.md.
kit_holds_gh_hosts() {
  kit_abs "$1"
  kit_lex "$KIT_ABS"
  _ra=$KIT_ABS _rl=$KIT_LEX _rest=$GH_HOSTS_LIST
  while [ -n "$_rest" ]; do
    _h=${_rest%%"$KIT_NL"*} _rest=${_rest#*"$KIT_NL"}
    [ -n "$_h" ] || continue
    if [ "$_ra" -ef "$_h" ] || [ "$_rl" -ef "$_h" ]; then return 0; fi
    kit_gh_dirs "$_h"
    for _d in "$GH_LDIR" "$GH_PDIR" "$GH_TDIR"; do
      while [ -n "$_d" ]; do
        if [ "$_ra" -ef "$_d" ] || [ "$_rl" -ef "$_d" ]; then return 0; fi
        [ "$_d" != / ] || break
        _d=${_d%/*}
        [ -n "$_d" ] || _d=/
      done
    done
  done
  kit_dir_gh_link "$_ra"
}

# kit_dir_gh_link <dir> — an immediate child of <dir> is a symlink that resolves to a gh
# host file or its directory.  Only runs when the walk above found no ancestor, and only
# on the Grep and context-mode paths, which already early-exit unless a host file exists.
kit_dir_gh_link() {
  [ -d "$1" ] || return 1
  for _e in "$1"/* "$1"/.*; do
    [ -L "$_e" ] || continue
    case ${_e##*/} in . | ..) continue ;; esac
    _rest=$GH_HOSTS_LIST
    while [ -n "$_rest" ]; do
      _h=${_rest%%"$KIT_NL"*} _rest=${_rest#*"$KIT_NL"}
      [ -n "$_h" ] || continue
      if [ "$_e" -ef "$_h" ]; then return 0; fi
      kit_gh_dirs "$_h"
      for _d in "$GH_LDIR" "$GH_PDIR" "$GH_TDIR"; do
        [ -n "$_d" ] && [ "$_e" -ef "$_d" ] && return 0
      done
    done
  done
  return 1
}

GH_HOSTS_WHY="It holds the GitHub CLI's login token, which only gh's own process reads, so the token stays out of the transcript."
GH_HOSTS_HOW="To check gh's login, run \`gh auth status\`."

# The Read and Grep tools.  Their payloads carry no command, so they are decided here
# and never reach the Bash corpus below.  The case is a cheap pre-filter; the tool name
# the payload really carries is what decides.
case $KIT_INPUT in
  *'"tool_name"'*'"Read"'* | *'"tool_name"'*'"Grep"'*)
    _t= _f= _r= _c=
    if command -v jq >/dev/null 2>&1; then
      eval "$(printf '%s' "$KIT_INPUT" | jq -r '
        def s($v): $v | if type == "string" then . elif . == null then "" else tostring end;
        @sh "_t=\(s(.tool_name // .toolName)) _f=\(s(.tool_input.file_path // .toolInput.file_path)) _r=\(s(.tool_input.path // .toolInput.path)) _c=\(s(.cwd))"' 2>/dev/null)"
    fi
    if [ -z "$_t" ]; then
      # jq is absent, or it read nothing from the payload: scan the text instead, so a
      # failing jq never lets a Read through.  The tool name and cwd sit beside
      # tool_input, never in it (kit_field_top).
      _t=$(kit_field_top tool_name) _f=$(kit_field file_path) _r=$(kit_field path) _c=$(kit_field_top cwd)
      [ -n "$_t" ] || _t=$(kit_field_top toolName)
    fi
    case $_t in
      Read | Grep)
        kit_gh_hosts
        [ -n "$GH_HAVE" ] || exit 0
        KIT_CWD=$_c
        [ -n "$KIT_CWD" ] && [ -d "$KIT_CWD" ] || KIT_CWD=$PWD
        if [ "$_t" = Read ]; then
          ! kit_is_gh_hosts "$_f" || kit_deny "Read on gh's host file is refused. $GH_HOSTS_WHY $GH_HOSTS_HOW"
        else
          ! kit_holds_gh_hosts "${_r:-.}" || kit_deny "this Grep would search gh's host file. $GH_HOSTS_WHY Search a narrower path that leaves it out. $GH_HOSTS_HOW"
        fi
        exit 0
        ;;
    esac
    ;;
esac

kit_parse
[ -n "$KIT_CMD" ] || exit 0

# context-mode's `path` (ctx_execute_file, ctx_index): the same test as Grep's root.
# lib-headless.sh also hands each path to the corpus below as `cat <path>`, which
# catches the spelled path; this catches a link, another case and a directory above it.
if [ -n "${KIT_MCP-}" ]; then
  kit_gh_hosts
  if [ -n "$GH_HAVE" ]; then
    if [ -n "${KIT_HAVE_JQ-}" ]; then
      eval "set -- $(printf '%s' "$KIT_INPUT" | jq -r \
        '[(.tool_input // .toolInput // {}) | .. | objects | .path? | strings] | @sh' 2>/dev/null)"
    else
      set -f; _ifs=$IFS; IFS=$KIT_NL
      # shellcheck disable=SC2046
      set -- $(kit_field_all path 2>/dev/null)
      IFS=$_ifs; set +f
    fi
    for _p in "$@"; do
      ! kit_holds_gh_hosts "$_p" || kit_deny "would read gh's host file. $GH_HOSTS_WHY Pass a narrower path that leaves it out. $GH_HOSTS_HOW"
    done
  fi
fi

# ---- Shell -c: a hard block, and the one line it lets through.
#
# Every `bash|sh|zsh|dash|ksh -c` an agent runs on the Bash tool or through context-mode
# is denied below (SHELLC), at every tier, Off included: a -c string is a program no
# permission rule can read.  A shell fed its program on stdin (`… | sh`, `sh < f`, -s)
# is the same block under its own verdict (SHELLIN), so its message does not claim -c.  In a full install the permission layer also denies
# `sh -c *`, `bash -lc *` and `zsh -c *` at every tier, and `bash -c *` at Medium and
# High only (DENY_WRAPPERS and DENY_BASH_C in firewall.sh).  So for an agent's `bash -c`
# at Off and Relaxed, and for every shell -c in a plugin install, which carries no
# permission rules, this block is the only layer; elsewhere it is the second.
#
# The one exception is memsearch's memory-recall collection-derivation line, matched
# WHOLE: not a prefix, not a pattern, nothing prepended or appended, so nothing can
# ride a second command in behind it.  The string is memory-recall/SKILL.md's inline
# command verbatim, with `${CLAUDE_PLUGIN_ROOT}` and `$MEMSEARCH_DIR` left as written;
# tests/test_secrets_guard.sh pins it and the near-misses.  When the skill runs that
# line as its own set-up step, no hook sees it: Claude Code checks a skill's set-up
# line against the permission rules only.  So recall runs at Off and Relaxed, where no
# rule names `bash -c`, and stops at Medium and High, where `Bash(bash -c *)` denies it
# whatever a hook returns.  This match is for the agent running the same line through
# the Bash tool.  kit_allow rather than a silent exit, because a silent exit hands the
# call to the normal permission flow, which prompts for it wherever no rule decides.
MEMSEARCH_CMD=$(cat <<'KIT_MEMSEARCH_EOF'
bash -c 'if [ -n "${MEMSEARCH_DIR:-}" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh" "$MEMSEARCH_DIR"; else root=$(git rev-parse --show-toplevel 2>/dev/null || true); if [ -n "$root" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh" "$root"; else bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh"; fi; fi'
KIT_MEMSEARCH_EOF
)
if [ "$KIT_CMD" = "$MEMSEARCH_CMD" ]; then
  kit_allow "memsearch memory-recall collection-derivation line (the one shell -c this guard lets through)."
fi

[ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/secrets-guard.awk" ] || exit 0

# The regex travels in the environment, not through -v: awk processes escape
# sequences in -v assignments, which mangles \. and \( differently per awk.
VERDICT=$(printf '%s\n' "$KIT_CMD" | KIT_VAULT_RE="$(kit_vault_re)" KIT_LANG="${KIT_LANG-}" \
  awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/secrets-guard.awk" 2>/dev/null) || exit 0

case $VERDICT in
  DEEP*)
    # Fail closed, like the size cap: a command whose code strings nest deeper than
    # the hooks can read in time is refused, not read in part and let through.
    kit_deny_deep
    ;;
  SHELLC*)
    kit_deny "runs a shell with -c (bash, sh, zsh, dash or ksh), which executes an arbitrary program the firewall cannot inspect. It is denied at every tier. Run the command directly instead of wrapping it in a shell -c."
    ;;
  SHELLIN*)
    # The same block, reached by a shell that reads its program from stdin (a pipe into
    # it, a `<` redirect, -s, or no script argument), so the message cannot say -c.
    kit_deny "feeds a program to a shell on stdin (a pipe or redirect into bash, sh, zsh, dash or ksh, or -s), which executes code the firewall cannot inspect. It is denied at every tier. Run the commands directly instead of piping them into a shell."
    ;;
  WIPE*)
    # Destroying key material, not reading it, so the "use solana address instead"
    # trailer would be nonsense here. The route around is the flag, not the command.
    kit_deny "${VERDICT#WIPE } overwrites the default wallet keypair at ~/.config/solana/id.json, and a Solana keypair cannot be recovered without its seed phrase. Drop --force to keep the existing wallet (solana-keygen refuses to overwrite one without it, so the command works unchanged where no wallet exists yet), or pass -o <path> to write somewhere else. If the user really means to replace their default wallet, they run it themselves."
    ;;
  DENY*)
    kit_deny "${VERDICT#DENY } — reading private keys, wallet vaults or credentials is not allowed. Use \`solana address\` for the pubkey; ask the user to run anything that needs the secret."
    ;;
esac
exit 0
