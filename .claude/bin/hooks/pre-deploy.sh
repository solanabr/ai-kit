#!/usr/bin/env bash
# Pre-deploy gate. Blocks a mainnet program operation unless the command is
# prefixed with CONFIRM_MAINNET=1, and blocks an Anchor deploy with no build.
#
# Claude Code and Codex share this contract: one JSON object on stdin with the
# shell command at .tool_input.command, and exit 2 + a stderr reason to block.
# One script serves settings.json, plugin/hooks/hooks.json and .codex/hooks.json.
#
# Everything here fails CLOSED: if the command looks like a program operation and
# we cannot prove the target is not mainnet, we block and ask for confirmation.
set -u

block() { echo "$1" >&2; exit 2; }

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
# No jq, or a payload we can't parse: fall back to the raw stdin, but never let a
# stray CONFIRM_MAINNET=1 elsewhere in the JSON (a cwd, say) count as consent.
if [ -z "$CMD" ]; then CMD=$INPUT; RAW_FALLBACK=1; else RAW_FALLBACK=0; fi

# Program operations that write to a cluster. Irreversible ones (--final,
# set-upgrade-authority) matter as much as deploy.
printf '%s' "$CMD" | grep -qE \
  '(solana[[:space:]]+program[[:space:]]+(deploy|write-buffer|upgrade|set-upgrade-authority|set-buffer-authority|close|extend))|(anchor[[:space:]]+(program[[:space:]]+)?(deploy|upgrade))' \
  || exit 0

echo "🚨 PRE-DEPLOY CHECKS"

# Explicit target on the command line wins over the configured cluster.
TARGET=""
if printf '%s' "$CMD" | grep -qE '(--url|-u)[[:space:]]+(m|mainnet-beta|mainnet)([[:space:]]|$)|mainnet'; then
  TARGET=mainnet
elif printf '%s' "$CMD" | grep -qE '(--url|-u)[[:space:]]+(d|devnet|t|testnet|l|localhost|http://127\.0\.0\.1|http://localhost)([[:space:]]|$)|(--provider\.cluster[[:space:]]+(devnet|testnet|localnet))'; then
  TARGET=safe
elif printf '%s' "$CMD" | grep -qE '(--url|-u)[[:space:]]+https?://'; then
  # A custom RPC endpoint. We cannot tell which cluster it serves, so treat it as
  # mainnet — a paid endpoint usually is, and guessing wrong the other way is worse.
  TARGET=mainnet
else
  NETWORK=$(solana config get 2>/dev/null | grep "RPC URL" | awk '{print $3}')
  echo "Network: ${NETWORK:-unknown}"
  case "$NETWORK" in
    *devnet*|*testnet*|*localhost*|*127.0.0.1*) TARGET=safe ;;
    "") TARGET=mainnet ;;   # no CLI / no config: assume the worst
    *) TARGET=mainnet ;;
  esac
fi

# --final is unrecoverable wherever it points.
printf '%s' "$CMD" | grep -qE -- '--final([[:space:]]|$)' && TARGET=mainnet

if [ "$TARGET" = mainnet ]; then
  # The confirmation must be a leading assignment — at the start, or right after a
  # command separator. An unanchored match lets `echo CONFIRM_MAINNET=1 && deploy`
  # or a variable merely ending in it disarm the gate.
  CONFIRMED=0
  if [ "$RAW_FALLBACK" = 0 ] \
     && printf '%s' "$CMD" | grep -qE '(^|[;&|]|^[[:space:]]*)[[:space:]]*CONFIRM_MAINNET=1[[:space:]]'; then
    CONFIRMED=1
  fi
  if [ "$CONFIRMED" = 0 ]; then
    block "⚠️ MAINNET operation blocked. Prefix the command with CONFIRM_MAINNET=1 to confirm."
  fi
  echo "⚠️ MAINNET operation confirmed via CONFIRM_MAINNET=1"
fi

if [ -f "Anchor.toml" ] && printf '%s' "$CMD" | grep -qE 'deploy|upgrade'; then
  ls target/deploy/*.so >/dev/null 2>&1 \
    || block "❌ No build found (target/deploy/*.so) — run anchor build first"
fi

echo "✅ Pre-deploy checks passed"
