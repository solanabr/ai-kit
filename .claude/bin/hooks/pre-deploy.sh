#!/usr/bin/env bash
# Pre-deploy gate. Blocks a mainnet deploy unless the command is prefixed with
# CONFIRM_MAINNET=1, and blocks any Anchor deploy with no build artifact.
#
# Claude Code and Codex share this contract: one JSON object on stdin with the
# shell command at .tool_input.command, and exit 2 + a stderr reason to block.
# So one script serves both; settings.json and .codex/hooks.json both call it.
set -u

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || printf '%s' "$INPUT")
printf '%s' "$CMD" | grep -qE 'solana program deploy|anchor deploy' || exit 0

echo "🚨 PRE-DEPLOY CHECKS"
NETWORK=$(solana config get 2>/dev/null | grep "RPC URL" | awk '{print $3}')
echo "Network: $NETWORK"

# Match on the whole command string, not on argv[0]: a leading VAR=value
# assignment would hide `solana program deploy` from prefix-style matching.
if printf '%s\n%s' "$NETWORK" "$CMD" | grep -q mainnet; then
  if ! printf '%s' "$CMD" | grep -q 'CONFIRM_MAINNET=1'; then
    echo "⚠️ MAINNET DEPLOY blocked. Re-run with CONFIRM_MAINNET=1 prefixed to the command to confirm." >&2
    exit 2
  fi
  echo "⚠️ MAINNET DEPLOY confirmed via CONFIRM_MAINNET=1"
fi

if [ -f "Anchor.toml" ]; then
  ls target/deploy/*.so >/dev/null 2>&1 || { echo "❌ No build found (target/deploy/*.so) — run anchor build first" >&2; exit 2; }
fi

echo "✅ Pre-deploy checks passed"
