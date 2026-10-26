#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_onchain_guard] localnet silent at Relaxed, exact hosts only (D-C8/item 6)"

GUARD="$REPO_ROOT/.claude/hooks/onchain-guard.sh"
assert_file_exists "$GUARD" "the guard ships"
assert_file_exists "$REPO_ROOT/.claude/hooks/onchain-guard.awk" "the decision awk ships"

# verdict <tier> <command> -> deny | ask | silent
# Headless forced off so an interactive `ask` is visible; the write gates go silent
# headless by design, which is a different property (covered in test_hooks.sh).
verdict() {
  local pay out
  pay="$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2")"
  out="$(cd "$REPO_ROOT" && printf '%s' "$pay" | CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    KIT_FIREWALL_TIER="$1" KIT_FIREWALL_HEADLESS=0 sh "$GUARD" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
want() {
  local got; got="$(verdict "$1" "$4")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$2" ]; then echo "  PASS: [$1] $2  $3"; PASS=$((PASS + 1))
  else echo "  FAIL: [$1] want $2, got $got  $3  ::  $4"; FAIL=$((FAIL + 1)); fi
}

# ── exact local hosts: silent at Relaxed, ask at Medium and High ────────────
# A local validator is day-to-day work, so Relaxed must not prompt on it. Medium and
# High still ask (an interactive prompt, ignored headless), so the exact-host test is
# what this change turns on. Hosts: localhost, 127.0.0.1, ::1, 0.0.0.0 (with or without
# a port), and the solana CLI's own `l` / `localnet` shorthands.
echo "[exact local hosts: silent at Relaxed]"
LOCAL=(
  "solana program deploy --url http://localhost:8899 p.so"
  "solana program deploy --url http://127.0.0.1:8899 p.so"
  "solana program deploy --url http://[::1]:8899 p.so"
  "solana program deploy --url http://0.0.0.0:8899 p.so"
  "solana program deploy --url http://localhost p.so"
  "solana program deploy --url https://127.0.0.1 p.so"
  "solana program deploy --url localhost p.so"
  "solana program deploy -ul p.so"
  "solana program deploy --url l p.so"
  "anchor deploy --provider.cluster localnet"
  "solana program deploy --url http://LOCALHOST:8899 p.so"
)
for C in "${LOCAL[@]}"; do
  want relaxed silent "a loopback the agent runs itself" "$C"
  want medium  ask    "Medium still prompts on a local write"   "$C"
  want high    ask    "High still prompts on a local write"     "$C"
done

# ── the *localhost* mislabel is closed ──────────────────────────────────────
# The old glob matched any host CONTAINING "localhost"/"127.0.0.1", so an
# attacker-controlled host was labelled localnet and (post-change) would be waved
# through silently at Relaxed. These are NOT exact local hosts, so they fall to the
# possibly-mainnet branch, which ASKS at every tier — never silent at Relaxed.
echo "[attacker hosts that merely contain a loopback string: not localnet]"
ATTACKER=(
  "solana program deploy --url https://localhost.attacker.example p.so"
  "solana program deploy --url http://127.0.0.1.attacker.example p.so"
  "solana program deploy --url http://localhost@evil.example p.so"
  "solana program deploy --url http://evil.example/localhost p.so"
  "solana program deploy --url http://localhost.evil.example:8899 p.so"
)
for C in "${ATTACKER[@]}"; do
  want relaxed ask "an external host is possibly-mainnet, not localnet" "$C"
done

# ── the rest of the matrix is unchanged by this item ────────────────────────
# A mainnet write still gates (ask below High, deny at High); devnet/testnet still
# ask; the irreversible set still denies. Spot-checks so a localnet change that
# leaked into these shows here.
echo "[the rest of the on-chain matrix is untouched]"
want relaxed ask  "mainnet asks at Relaxed"       "solana program deploy --url https://api.mainnet-beta.solana.com p.so"
want high    deny "mainnet denied at High"        "solana program deploy --url https://api.mainnet-beta.solana.com p.so"
want relaxed ask  "devnet asks"                   "solana program deploy --url https://api.devnet.solana.com p.so"
want relaxed deny "the irreversible set denies"   "solana program deploy --url http://localhost:8899 --final p.so"

# ── #307: cluster names are exact, and an unidentified cluster is mainnet headless ──
# The old `*devnet*`/`*testnet*` globs read any URL that merely contained the word as
# that cluster, and a devnet ask goes silent headless, so a mainnet RPC carrying
# `?devnet` ran unprompted in a pipeline at every tier, High included. An unknown host
# did the same through its own ask. Now devnet and testnet are exact monikers and hosts,
# and anything unidentified takes mainnet's headless path: denied (High outright, below
# it unless CONFIRM_MAINNET=1). Interactive verdicts are unchanged: still an ask.
echo "[#307: exact devnet/testnet, unidentified clusters denied headless]"
# hverdict <guard> <tier> <command> [env...] -> deny | ask | silent, headless
hverdict() {
  local g=$1 t=$2 c=$3 pay out; shift 3
  pay="$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$c")"
  out="$(cd "$REPO_ROOT" && printf '%s' "$pay" | env CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    KIT_FIREWALL_TIER="$t" KIT_FIREWALL_HEADLESS=1 "$@" sh "$g" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
KNOWN=(
  "solana program deploy --url https://api.devnet.solana.com p.so"
  "solana program deploy --url https://API.DEVNET.SOLANA.COM/ p.so"
  "solana program deploy --url https://devnet.helius-rpc.com/?api-key=k p.so"
  "solana program deploy -ud p.so"
  "solana program deploy --url devnet p.so"
  "anchor deploy --provider.cluster devnet"
  "solana program deploy --url https://api.testnet.solana.com p.so"
  "solana program deploy -ut p.so"
  "solana program deploy --url http://localhost:8899 p.so"
)
for C in "${KNOWN[@]}"; do
  for T in relaxed medium high; do
    assert_eq silent "$(hverdict "$GUARD" "$T" "$C")" "[$T] headless: a known non-mainnet cluster still goes quiet :: $C"
  done
done
for C in "solana program deploy --url https://api.devnet.solana.com p.so" \
         "solana program deploy --url https://api.testnet.solana.com p.so"; do
  want relaxed ask "a known cluster still asks interactively" "$C"
done
UNKNOWN=(
  "anchor deploy --provider.cluster https://rpc.mycorp.io"
  "solana program deploy --url https://solana-rpc.publicnode.com/?devnet p.so"
  "solana program deploy --url https://rpc.example/devnet p.so"
  "solana program deploy --url https://devnet.attacker.example p.so"
  "solana program deploy --url https://api.devnet.solana.com.attacker.example p.so"
  "solana program deploy --url https://api.devnet.solana.com@evil.example p.so"
  "solana program deploy --url https://my-testnet-rpc.example p.so"
  "solana program deploy --url https://localhost.attacker.example p.so"
)
for C in "${UNKNOWN[@]}"; do
  for T in relaxed medium high; do
    assert_eq deny "$(hverdict "$GUARD" "$T" "$C")" "[$T] headless: an unidentified cluster is denied like mainnet :: $C"
    want "$T" ask "interactive: an unidentified cluster still asks" "$C"
  done
  assert_eq silent "$(hverdict "$GUARD" relaxed "$C" CONFIRM_MAINNET=1)" "[relaxed] CONFIRM_MAINNET=1 is the escape, as for mainnet :: $C"
  assert_eq deny "$(hverdict "$GUARD" high "$C" CONFIRM_MAINNET=1)" "[high] no escape, as for mainnet :: $C"
done
# The denial names the host, never the URL: an RPC URL can carry an API key.
OUT307="$(cd "$REPO_ROOT" && python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
  "solana program deploy --url https://rpc.mycorp.io/?api-key=k123 p.so" | CLAUDE_PROJECT_DIR="$REPO_ROOT" \
  KIT_FIREWALL_TIER=relaxed KIT_FIREWALL_HEADLESS=1 sh "$GUARD" 2>&1 || true)"
assert_contains "$OUT307" "rpc.mycorp.io" "the headless denial names the host"
assert_contains "$OUT307" "CONFIRM_MAINNET=1" "the headless denial names the escape"
assert_eq no "$(grep -q k123 <<<"$OUT307" && echo yes || echo no)" "the API key in the URL never reaches the message"

# Controls: the fix planted back out, and the verdict has to move.
# omutant <name> <find> <replace> -> a hooks dir whose onchain-guard.sh carries it.
omutant() {
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/onchain-mut-$1.XXXXXX")" || return 1
  cp -R "$REPO_ROOT/.claude/hooks/." "$dir/"
  python3 - "$dir/onchain-guard.sh" "$2" "$3" <<'PY' || return 1
import sys
path, find, repl = sys.argv[1:4]
s = open(path, encoding="utf-8").read()
if s.count(find) != 1:
    sys.exit("mutation target %r matched %d times, wanted 1" % (find, s.count(find)))
open(path, "w", encoding="utf-8").write(s.replace(find, repl))
PY
  printf '%s' "$dir"
}
M="$(omutant glob 'case $CL in d | devnet) return 0 ;; esac' 'case $CL in d | *devnet*) return 0 ;; esac')"
assert_eq silent "$(hverdict "$M/onchain-guard.sh" high "solana program deploy --url https://solana-rpc.publicnode.com/?devnet p.so")" \
  "planted failure caught — the *devnet* glob back: a mainnet RPC carrying ?devnet goes quiet headless again"
rm -rf "$M"
M="$(omutant headless 'unidentified() {' 'unidentified() { kit_ask "$1"; }
_was_unidentified() {')"
assert_eq silent "$(hverdict "$M/onchain-guard.sh" high "anchor deploy --provider.cluster https://rpc.mycorp.io")" \
  "planted failure caught — an unidentified cluster only asks: it goes quiet headless again"
rm -rf "$M"

# A command that names no on-chain write stays silent (the guard's prefilter).
echo "[no on-chain verb: silent]"
want relaxed silent "a local build is not an on-chain write" "cargo build-sbf"
want relaxed silent "a solana query is not a write"          "solana balance --url http://localhost:8899"

# ── an MCP call's own tool_name or command argument changes nothing ─────────
# kit_parse reads the tool name from the payload's top level and always rebuilds an
# MCP call's command from the fields the tool runs. A context-mode call carrying a
# tool_name or command argument of its own skipped that rebuild, and a mainnet deploy
# in its code met no gate at any tier.
echo "[an MCP call's own tool_name or command argument: the mainnet gate still holds]"
# raw <tier> <headless> <payload> -> deny | ask | silent
raw() {
  local out
  out="$(cd "$REPO_ROOT" && printf '%s' "$3" | CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    KIT_FIREWALL_TIER="$1" KIT_FIREWALL_HEADLESS="$2" sh "$GUARD" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
# mcp_pay <code> <extra tool_input JSON> [tool_input first: 1]
mcp_pay() {
  python3 -c '
import json, sys
ti = {"language": "shell", "code": sys.argv[1]}; ti.update(json.loads(sys.argv[2]))
top = [("hook_event_name", "PreToolUse"), ("tool_name", "mcp__context-mode__ctx_execute")]
pairs = [("tool_input", ti)] + top if sys.argv[3] == "1" else top + [("tool_input", ti)]
print(json.dumps(dict(pairs)))' "$1" "$2" "${3:-0}"
}
DEPLOY="solana program deploy --url mainnet-beta x.so"
for EXTRA in '{}' '{"tool_name":"x"}' '{"tool_name":"Bash"}' '{"command":"ls"}'; do
  for FIRST in 0 1; do
    P="$(mcp_pay "$DEPLOY" "$EXTRA" "$FIRST")"
    assert_eq deny "$(raw relaxed 1 "$P")" "headless Relaxed denies a mainnet deploy in ctx_execute carrying $EXTRA (tool_input first: $FIRST)"
    assert_eq ask  "$(raw relaxed 0 "$P")" "interactive Relaxed asks on it (tool_input first: $FIRST, $EXTRA)"
    assert_eq deny "$(raw high 0 "$P")" "High denies it (tool_input first: $FIRST, $EXTRA)"
  done
done

print_summary
