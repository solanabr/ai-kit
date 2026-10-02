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
#      Now: non-mainnet asks go silent with no interactive user, and mainnet
#      denies instead of slipping through.
#
# RPC URLs never reach the prompt text — only a cluster name, or a bare host for
# an endpoint that cannot be classified.  Private RPC URLs carry API keys.
#
# The --final / program-v4 finalize / authorize --disable block is exit 2 at
# every tier including Off: the matching permission rule
# `Bash(solana program deploy *--final*)` has the two-wildcard shape that was
# verified inert, so this hook is the only thing standing in front of them.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked, stdout JSON = ask.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
case $KIT_INPUT in *solana* | *anchor* | *spl-token*) ;; *) exit 0 ;; esac
kit_parse
[ -n "$KIT_CMD" ] || exit 0

# Position-anchored: the verb has to start a statement, optionally behind env
# assignments and a path prefix.  Matching the verb anywhere in the string is
# what makes a hook fire on prose about deploying.
RE='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?((solana|anchor) program (deploy|write-buffer|upgrade|extend|migrate|close|set-upgrade-authority|set-buffer-authority)|solana program-v4 (deploy|retract|transfer-authority|finalize)|anchor (deploy|upgrade)|solana (transfer|withdraw-stake|withdraw-from-vote-account|withdraw-from-nonce-account)|spl-token (transfer|burn|close|authorize))([[:space:]][^;&|]*)?([;&|)]|$)'
SEG=$(printf '%s\n' "$KIT_CMD" | grep -oE "$RE") || SEG=
[ -n "$SEG" ] || exit 0

# ---- irreversible: deny at every tier, no env escape.  The user runs these.
if printf '%s\n' "$SEG" | grep -qE -e '--final|--bypass-warning|program-v4 finalize|spl-token authorize[^;&|]*--disable'; then
  kit_deny "irreversible on-chain action (--final, program close --bypass-warning, program-v4 finalize or authorize --disable). If the user wants it, they run it themselves outside Claude."
fi

TIER=$(kit_tier)
[ "$TIER" = "off" ] && exit 0

# ---- resolve the cluster.  Precedence: command-line flag, then an
# ANCHOR_PROVIDER_URL assignment in the command, then -C/--config, then the
# exported ANCHOR_PROVIDER_URL, then Anchor.toml or `solana config`.
set -f
CL= SRC= CFG= prev=
for w in $SEG; do
  case $prev in
    --url | -u | --provider.cluster) [ -z "$CL" ] && { CL=$w; SRC='command flag'; } ;;
    -C | --config) [ -z "$CFG" ] && CFG=$w ;;
  esac
  case $w in
    --url=* | --provider.cluster=*) [ -z "$CL" ] && { CL=${w#*=}; SRC='command flag'; } ;;
    --config=*) [ -z "$CFG" ] && CFG=${w#--config=} ;;
    ANCHOR_PROVIDER_URL=*) ANCHOR_IN_CMD=${w#ANCHOR_PROVIDER_URL=} ;;
    # Any other long option. Must precede -u?* or --upgrade-authority reads as
    # `-u pgrade-authority`, which is how the inline hook mislabelled it.
    --*) ;;
    -u?*) [ -z "$CL" ] && { CL=${w#-u}; SRC='command flag'; } ;;
    -C?*) [ -z "$CFG" ] && CFG=${w#-C} ;;
  esac
  prev=$w
done
set +f

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

if [ -z "$CL" ] && [ -n "${ANCHOR_IN_CMD-}" ]; then
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
  case $SEG in
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
      if command -v solana >/dev/null 2>&1; then
        CL=$(solana config get json_rpc_url 2>/dev/null | awk '{print $NF}')
      fi
      [ -n "$CL" ] || CL=$(read_cfg_url "${SOLANA_CONFIG_FILE:-$HOME/.config/solana/cli/config.yml}") || CL=
      ;;
  esac
fi
[ -n "$SRC" ] || SRC='an unknown source'

# Normalise for classification only.  Nothing below prints the URL: HOST keeps
# scheme, path, query and userinfo out, so an api-key cannot reach the prompt.
CL=$(printf '%s' "${CL#=}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9:/._?=&%~-')
HOST=$(printf '%s' "$CL" | sed -e 's#^[a-z][a-z0-9+.-]*://##' -e 's#[/?].*$##' -e 's#^[^@]*@##')

case $CL in
  m | *mainnet*)
    R="MAINNET (from $SRC): spends real SOL or changes a live program. Approve only if the user asked for mainnet."
    if [ "$TIER" = "high" ]; then
      kit_deny "$R At the High firewall tier mainnet writes are denied; drop to Medium or run it yourself."
    fi
    kit_gate mainnet "$R"
    ;;
  d | *devnet*) kit_ask "On-chain write to devnet (from $SRC)." ;;
  t | *testnet*) kit_ask "On-chain write to testnet (from $SRC)." ;;
  l | localnet | *localhost* | *127.0.0.1*) kit_ask "On-chain write to localnet (from $SRC)." ;;
  '') kit_ask "On-chain write to an unknown cluster (no --url, -C config, ANCHOR_PROVIDER_URL, Anchor.toml or solana config found). Check the target before approving." ;;
  *) kit_ask "On-chain write to the RPC host ${HOST:-unknown} (from $SRC). That host is not a public Solana cluster name, so it may well be mainnet — check before approving." ;;
esac
exit 0
