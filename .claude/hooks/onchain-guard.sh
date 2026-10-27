#!/bin/sh
# onchain-guard.sh — PreToolUse(Bash): gate on-chain writes, and hard-block the
# irreversible ones.
#
# Ported from the inline hook that shipped in .claude/settings.json, with three
# changes:
#
#   1. ANCHOR_PROVIDER_URL=... anchor deploy      now resolves that URL.
#      The old regex let leading assignments through but never read them, so it
#      fell back to Anchor.toml and reported the wrong cluster — a mainnet
#      deploy announced as devnet.
#   2. solana program deploy -C /tmp/mainnet.yml  now reads that config file.
#      -C / --config was accepted and ignored, so the gate described the
#      machine's default cluster instead of the one being deployed to.
#   3. It is headless-aware.  The old hook returned `ask` for every on-chain
#      write on every cluster, which is an unconditional failure under -p.
#      Now: devnet, testnet and localnet asks go silent with no interactive
#      user, and mainnet — or a cluster the hook cannot identify — denies
#      instead of slipping through.
#
# RPC URLs never reach the prompt text — only a cluster name, or a bare host for
# an endpoint that cannot be classified.  Private RPC URLs carry API keys.
#
# The --final / program-v4 finalize / authorize --disable / anchor idl
# erase-authority block is exit 2 at
# every tier including Off: the matching permission rule
# `Bash(solana program deploy *--final*)` has the two-wildcard shape that was
# verified inert, so this hook is the only thing standing in front of them.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked, stdout JSON = ask.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
# Cheap pre-filter on the raw JSON.  The last arm is a backslash-newline as JSON
# spells it: the shell deletes that pair before it reads words, so
# `sol\<newline>ana program deploy` is `solana program deploy` and must reach the
# normaliser below, which joins it.
# A quote or backslash inside a word does not hide it from bash either: `a"n"chor
# deploy` is anchor deploy (#297).  So the words are looked for in a copy without
# them as well, and the continuation in the input as it came.
KIT_PRE="$KIT_INPUT
$(kit_unquoted "$KIT_INPUT")"
case $KIT_PRE in *solana* | *anchor* | *spl-token* | *'\\\n'*) ;; *) exit 0 ;; esac
kit_parse
[ -n "$KIT_CMD" ] || exit 0

# ---- strip wrapper binaries before matching (issue #110).
#
# The matcher-evading wrappers are denied outright by permissions (spec §2), but
# a deny there does not give this hook an opinion, and the ones spec §2 calls
# "NOT evasions" because the matcher decomposes them (nohup, time, nice,
# timeout, stdbuf, command, builtin, noglob, bare xargs) still reach this hook
# with the wrapper attached.  Since the regex below is position-anchored, every
# one of those made the gate silent — no cluster warning, and no exit 2 on the
# irreversible set, which this hook is the only thing standing in front of.
#
# The normaliser is onchain-guard.awk; its header says why it keeps its own pass
# instead of moving onto the shared tokenizer's split_cmd (#138).
if [ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/onchain-guard.awk" ]; then
  KIT_NORM=$(printf '%s\n' "$KIT_CMD" |
    awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/onchain-guard.awk" 2>/dev/null) || KIT_NORM=
else
  KIT_NORM=
fi
[ -n "$KIT_NORM" ] || KIT_NORM=$KIT_CMD

# Fail closed, like kit_size_cap and at every tier as it is: onchain-guard.awk
# prints only this marker (a control character, so no command's own text matches
# it) when the command's code strings nest deeper than the hooks can read in time.
# Refused before the verb match, so an irreversible action or a mainnet deploy in
# the unread inner code cannot pass.
if [ "$KIT_NORM" = "$(printf '\001KITDEEP')" ]; then
  kit_deny_deep
fi

# Position-anchored: the verb has to start a statement, optionally behind env
# assignments and a path prefix.  Matching the verb anywhere in the string is
# what makes a hook fire on prose about deploying.
#
# The verb is found behind the CLI's global options too (#306): clap takes them
# before the subcommand, so `solana -um transfer`, `solana --url <rpc> transfer`,
# `solana -k kp.json transfer` and `anchor --provider.cluster mainnet idl
# erase-authority` all run, and the old `solana transfer` literal saw none of them.
# GO is any run of options, each followed by any number of value words; a value word
# never starts with `-`.  The normaliser splits words on whitespace without reading
# quotes, so `-k 'my kp.json'` and `-k my\ kp.json` reach this text as `-k my kp.json`:
# one option and two value words, which a one-value GO missed (the verb went unread).
# A value word may carry `(` and `)`: `--url $(cat .rpc)` and `--provider.wallet
# $(pwd)/id.json` are option values, and a GO that stopped at the paren left the verb
# behind them unread.  `;`, `&` and `|` still end it, so it never runs into the next
# statement.
GO='( -[^[:space:];&|()]*( [^-[:space:];&|][^[:space:];&|]*)*)*'
# verbs <GO> — the gated subcommand paths, with <GO> between the words.
verbs() {
  printf '%s' "((solana|anchor)$1 program$1 (deploy|write-buffer|upgrade|extend|migrate|close|set-upgrade-authority|set-buffer-authority)|solana$1 program-v4$1 (deploy|retract|transfer-authority|finalize)|anchor$1 (deploy|upgrade|idl$1 (erase-authority|set-authority))|solana$1 (transfer|withdraw-stake|withdraw-from-vote-account|withdraw-from-nonce-account|close-vote-account|stake-authorize(-checked)?|vote-authorize-voter(-checked)?|vote-authorize-withdrawer(-checked)?|authorize-nonce-account)|spl-token$1 (transfer|burn|close|authorize|approve))"
}
LEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?'
RE="$LEAD$(verbs "$GO")"'([[:space:]][^;&|]*)?([;&|)]|$)'
# One write per line.  A match consumes the separator that ends it, so with the
# statements left on one line a write right after a `;` or `|` had no separator
# left to start on and was never seen: `deploy -ud a.so; deploy --url <mainnet>
# b.so` was judged by the devnet half alone.  Breaking the line after every
# separator first gives each statement its own start.
#
# Redirections go first.  Their `&` is not a separator (`2>&1`, `>&2`, `<&0`,
# `2>&-`, `&>file`, `&>>file`, and `>|` is not a pipe), and read as one the write
# ended at the redirection: every flag after it was never seen, so `deploy a.so
# 2>&1 -um` resolved to the default cluster and `deploy a.so -ud 2>&1 --final`
# passed the irreversible check.  The redirection decides nothing here, so it is
# removed and the words either side of it stay in the one statement.  `|&` is a
# real pipe and stays a separator.
#
# Backticks are read exactly as before this change: an ordinary character, so a
# backtick substitution is part of the words around it.  `` echo `solana program
# deploy b.so -um` `` therefore starts no statement and meets no gate; that gap
# predates this file's per-statement split and is tracked as a follow-up.
#
# The normaliser also treats `)` as a statement end and drops the space after it, so
# `--url $(cat .rpc) program deploy` reaches here as `$(cat .rpc)program deploy`; the
# space is put back before matching.
SEG=$(printf '%s\n' "$KIT_NORM" | awk '{
    gsub(/[0-9]*[<>]&[0-9]*-?/, " ")
    gsub(/&>>?/, " ")
    gsub(/>\|/, ">")
    gsub(/[;&|]/, "&\n")
    print
  }' | sed 's/)\([^[:space:];&|)]\)/) \1/g' | grep -oE "$RE") || SEG=
[ -n "$SEG" ] || exit 0

# ---- irreversible: deny at every tier, no env escape.  The user runs these.
# `anchor idl erase-authority` sets the IDL authority to none; no instruction gives it back.
# Read on every statement, and before the help exemption below, so no help word can
# quiet these: `solana transfer -h; anchor idl erase-authority …` and `solana transfer
# X 1; solana program deploy --final p.so` each reach this check as two statements.
if printf '%s\n' "$SEG" | grep -qE -e '--final|--bypass-warning|program-v4 finalize|spl-token[^;&|]* authorize[^;&|]*--disable|idl[^;&|]* erase-authority'; then
  kit_deny "irreversible on-chain action (--final, program close --bypass-warning, program-v4 finalize, authorize --disable or anchor idl erase-authority). If the user wants it, they run it themselves outside Claude."
fi

# ---- a help or version call sends nothing.  clap prints and exits on -h, --help, -V
# or --version, so `solana -ud transfer --help` is a read.  The exemption is narrow on
# purpose, because the normalised text above has lost what made a word an argument:
#   - the help word must sit directly after the binary (`solana --help transfer`) or
#     directly after the verb (`spl-token approve --help`), behind options of plain
#     words with at most one value each, so it cannot be an option's value;
#   - the command as written must carry no quote, backslash, `#`, `$`, backtick or
#     redirection, so the word is an argv word of that command, and not a comment
#     (`--final # --help`), a redirection target (`2> -h`), a substitution
#     (`$(: --help)`) or one piece of a quoted value (`--with-memo 'a -h b'`).
# A statement that fails either test is gated as a write, which is the safe reading.
# The test is per statement: only the help call's own line leaves SEG, so the write
# beside it (`spl-token approve --help; anchor deploy …`) is still judged below.
case $KIT_CMD in
  *[\'\"\\#\$\`\<\>]*) ;;
  *)
    GO1='( -[A-Za-z0-9][A-Za-z0-9._:/=-]*( [A-Za-z0-9._:/][A-Za-z0-9._:/=-]*)?)*'
    HW='(-h|--help|-V|--version)([[:space:];&|)]|$)'
    HRE="^$LEAD((solana|anchor|spl-token) $HW|$(verbs "$GO1") $HW)"
    SEG=$(printf '%s\n' "$SEG" | grep -vE "$HRE") || SEG=
    [ -n "$SEG" ] || exit 0
    ;;
esac

TIER=$(kit_tier)
[ "$TIER" = "off" ] && exit 0

read_cfg_url() { # read_cfg_url <config.yml> — prints json_rpc_url, or fails
  [ -n "${1-}" ] && [ -r "$1" ] || return 1
  _u=$(awk '/^[[:space:]]*json_rpc_url:/ {
         sub(/^[^:]*:[[:space:]]*/, "")
         gsub(/[^A-Za-z0-9:\/._?=&%~@-]/, "")
         if ($0 != "") { print; exit }
       }' "$1" 2>/dev/null)
  [ -n "$_u" ] || return 1
  printf '%s' "$_u"
}

# resolve <segment> — set CANDS (one raw cluster per line) and SRC for ONE write.
# Precedence: command-line flags, then an ANCHOR_PROVIDER_URL assignment in that
# statement, then -C/--config, then the exported ANCHOR_PROVIDER_URL, then
# Anchor.toml or `solana config`.
# Per write, not per command: the first --url across the whole command used to
# label every write in it, so `deploy -ud a.so && deploy -um b.so` was devnet.
# Every cluster flag in the statement is a candidate, not just the first: which
# repeat a CLI honours is its parser's business (clap lets the last one win), so
# `--provider.cluster devnet --provider.cluster mainnet` is judged by the worst.
SOLANA_CFG_DONE= SOLANA_CFG_CL=
KIT_LF='
'
resolve() {
  CL= SRC= CFG= ANCHOR_IN_CMD= FLAGS= prev=
  set -f
  for w in $1; do
    case $prev in
      --url | -u | --provider.cluster) FLAGS="$FLAGS$KIT_LF$w" ;;
      -C | --config) [ -z "$CFG" ] && CFG=$w ;;
    esac
    case $w in
      --url=* | --provider.cluster=*) FLAGS="$FLAGS$KIT_LF${w#*=}" ;;
      --config=*) [ -z "$CFG" ] && CFG=${w#--config=} ;;
      ANCHOR_PROVIDER_URL=*) ANCHOR_IN_CMD=${w#ANCHOR_PROVIDER_URL=} ;;
      # Any other long option. Must precede -u?* or --upgrade-authority reads as
      # `-u pgrade-authority`, which is how the inline hook mislabelled it.
      --*) ;;
      -u?*) FLAGS="$FLAGS$KIT_LF${w#-u}" ;;
      -C?*) [ -z "$CFG" ] && CFG=${w#-C} ;;
    esac
    prev=$w
  done
  set +f
  if [ -n "$FLAGS" ]; then
    CANDS=${FLAGS#"$KIT_LF"} SRC='command flag'
    return
  fi

  if [ -z "$CL" ] && [ -n "$ANCHOR_IN_CMD" ]; then
    CL=$ANCHOR_IN_CMD; SRC=ANCHOR_PROVIDER_URL
  fi
  if [ -z "$CL" ] && [ -n "$CFG" ]; then
    if CL=$(read_cfg_url "$CFG"); then
      SRC='solana config file'
    else
      CL=; SRC=
    fi
  fi
  if [ -z "$CL" ]; then
    case $1 in
      *anchor*)
        if [ -n "${ANCHOR_PROVIDER_URL-}" ]; then
          CL=$ANCHOR_PROVIDER_URL; SRC=ANCHOR_PROVIDER_URL
        else
          SRC=Anchor.toml
          for d in "$PWD" "${KIT_CWD-}" "${CLAUDE_PROJECT_DIR-}"; do
            [ -n "$d" ] && [ -r "$d/Anchor.toml" ] || continue
            CL=$(awk -F'"' '/^[[:space:]]*cluster[[:space:]]*=/{print $2; exit}' "$d/Anchor.toml" 2>/dev/null)
            [ -n "$CL" ] && break
          done
        fi
        ;;
      *)
        SRC='solana config'
        if [ -z "$SOLANA_CFG_DONE" ]; then
          if command -v solana >/dev/null 2>&1; then
            SOLANA_CFG_CL=$(solana config get json_rpc_url 2>/dev/null | awk '{print $NF}')
          fi
          [ -n "$SOLANA_CFG_CL" ] || SOLANA_CFG_CL=$(read_cfg_url "${SOLANA_CONFIG_FILE:-$HOME/.config/solana/cli/config.yml}") || SOLANA_CFG_CL=
          SOLANA_CFG_DONE=1
        fi
        CL=$SOLANA_CFG_CL
        ;;
    esac
  fi
  [ -n "$SRC" ] || SRC='an unknown source'
  CANDS=$CL
}

# normalise <raw cluster> — set CL, HOST and HNP for classification only.  Nothing
# below prints the URL: HOST keeps scheme, path, query and userinfo out, so an
# api-key cannot reach the prompt.
normalise() {
  CL=$(printf '%s' "${1#=}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9:/._?=&%~-')
  HOST=$(printf '%s' "$CL" | sed -e 's#^[a-z][a-z0-9+.-]*://##' -e 's#[/?].*$##' -e 's#^[^@]*@##')
  # HOST with the IPv6 brackets and the :port stripped, for an EXACT local-host test.
  HNP=$(printf '%s' "$HOST" | sed -e 's#^\[##' -e 's#\].*$##' -e 's#:[0-9]*$##')
}

# is_localnet — the cluster is a loopback the agent runs itself.  EXACT hosts only:
# the old `*localhost*` glob also matched localhost.attacker.example, an
# attacker-controlled host, and labelled an on-chain write to it "localnet".  Such a
# host now falls through to the possibly-mainnet branch, which is stricter.  `l` and
# `localnet` are the solana CLI's own shorthands (`-ul`).
is_localnet() {
  case $CL in l | localnet) return 0 ;; esac
  case $HNP in localhost | 127.0.0.1 | ::1 | 0.0.0.0) return 0 ;; esac
  return 1
}

# is_devnet / is_testnet — EXACT monikers and hosts, for the same reason as
# is_localnet.  The old `*devnet*` glob read any URL that merely contained the word
# as devnet, `https://solana-rpc.publicnode.com/?devnet` (a mainnet endpoint) among
# them, and devnet asks go silent headless (#307).  A devnet provider not listed here
# falls to the unidentified branch below: still an ask interactively, and denied
# headless unless CONFIRM_MAINNET=1.  The monikers are the solana CLI's (`-ud`,
# `devnet`) and Anchor.toml's `cluster = "devnet"`.
is_devnet() {
  case $CL in d | devnet) return 0 ;; esac
  case $HNP in api.devnet.solana.com | devnet.helius-rpc.com) return 0 ;; esac
  return 1
}
is_testnet() {
  case $CL in t | testnet) return 0 ;; esac
  case $HNP in api.testnet.solana.com) return 0 ;; esac
  return 1
}

# classify — LEVEL and MSG for the write resolve() just read.  4 mainnet, 3 a
# cluster none of the tests can name, 2 a known cluster that asks, 1 silent.
# `*mainnet*` stays a substring test on purpose: it errs towards the strict branch,
# so a URL that only mentions mainnet is gated as mainnet, never waved through.
classify() {
  case $CL in
    m | *mainnet*)
      LEVEL=4 MSG="MAINNET (from $SRC): spends real SOL or changes a live program. Approve only if the user asked for mainnet."
      return ;;
  esac
  if is_devnet; then
    LEVEL=2 MSG="On-chain write to devnet (from $SRC)."
  elif is_testnet; then
    LEVEL=2 MSG="On-chain write to testnet (from $SRC)."
  elif is_localnet; then
    # Localnet is silent at Relaxed — a local validator is day-to-day work and
    # Relaxed must not get in the way.  Medium and High still ask (an interactive
    # prompt, ignored headless).
    LEVEL=2 MSG="On-chain write to localnet (from $SRC)."
    [ "$TIER" = "relaxed" ] && LEVEL=1
  elif [ -z "$CL" ]; then
    LEVEL=3 MSG="On-chain write to an unknown cluster (no --url, -C config, ANCHOR_PROVIDER_URL, Anchor.toml or solana config found). Check the target before approving."
  else
    LEVEL=3 MSG="On-chain write to the RPC host ${HOST:-unknown} (from $SRC). That host is not a known Solana cluster endpoint, so it may well be mainnet — check before approving."
  fi
}

# Judge every write, and answer for the most dangerous one: a command is approved
# or refused whole, so a devnet deploy beside a mainnet one is a mainnet command.
WORST=0 WMSG=
while IFS= read -r s; do
  [ -n "$s" ] || continue
  resolve "$s"
  # One pass per candidate cluster; an empty CANDS is one pass with no cluster.
  while IFS= read -r c; do
    normalise "$c"
    classify
    if [ "$LEVEL" -gt "$WORST" ]; then WORST=$LEVEL WMSG=$MSG; fi
  done <<CANDS
$CANDS
CANDS
done <<EOF
$SEG
EOF

case $WORST in
  4)
    if [ "$TIER" = "high" ]; then
      kit_deny "$WMSG At the High firewall tier mainnet writes are denied; drop to Medium or run it yourself."
    fi
    kit_gate mainnet "$WMSG"
    ;;
  3)
    # A cluster nobody could name.  Interactive, an ask.  Known to be headless, the
    # ask would go silent and the write would run on what may well be mainnet, so
    # it takes mainnet's path: denied at High, below High unless CONFIRM_MAINNET=1
    # (#307).  When headless cannot be established, kit_gate asks — which a real
    # headless run treats as a refusal, so it never runs unprompted either.
    if [ "$TIER" = "high" ] && kit_known_headless; then
      kit_deny "$WMSG At the High firewall tier a write to a cluster that may be mainnet is denied with no interactive user; drop to Medium or run it yourself."
    fi
    kit_gate mainnet "$WMSG"
    ;;
  2) kit_ask "$WMSG" ;;
esac
exit 0
