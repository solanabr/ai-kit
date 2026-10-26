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
  # A mutation fixture that failed to build must not read as "silent".
  [ -f "$g" ] || { echo "missing-guard:$g"; return; }
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
M="$(omutant headless 'LEVEL=3 MSG="On-chain write to the RPC host' 'LEVEL=2 MSG="On-chain write to the RPC host')"
assert_eq silent "$(hverdict "$M/onchain-guard.sh" high "anchor deploy --provider.cluster https://rpc.mycorp.io")" \
  "planted failure caught — an unidentified host only asks: it goes quiet headless again"
rm -rf "$M"

# ── every write in a command is judged by its own cluster ───────────────────
# The first --url/-u across the whole command used to label every write in it, and a
# write right after a single `;` or `|` was never matched at all (the match before it
# had consumed the separator). Either way a mainnet or unknown write beside a devnet
# one was judged as devnet: silent headless at every tier. The worst write decides.
echo "[each write judged by its own cluster; the most dangerous one decides]"
MULTI_MAIN=(
  "solana program deploy -ud a.so && solana program deploy -um b.so"
  "solana program deploy -ud a.so; solana program deploy -um b.so"
  "solana program deploy -ud a.so | solana transfer -um X 1"
  "solana program deploy -um a.so; solana program deploy -ud b.so"
  "ANCHOR_PROVIDER_URL=https://api.devnet.solana.com anchor deploy; solana program deploy --url mainnet-beta p.so"
)
for C in "${MULTI_MAIN[@]}"; do
  want relaxed ask  "interactive: a mainnet write beside a devnet one asks as mainnet" "$C"
  want high    deny "High: a mainnet write beside a devnet one is denied" "$C"
  assert_eq deny "$(hverdict "$GUARD" relaxed "$C")" "[relaxed] headless: the mainnet write is not hidden by the devnet one :: $C"
done
MULTI_UNKNOWN=(
  "solana program deploy -ud a.so; solana program deploy --url https://rpc.mycorp.io b.so"
  "solana program deploy -ud a.so && solana program deploy --url https://rpc.mycorp.io b.so"
)
for C in "${MULTI_UNKNOWN[@]}"; do
  for T in relaxed high; do
    assert_eq deny "$(hverdict "$GUARD" "$T" "$C")" "[$T] headless: the unidentified write is not hidden by the devnet one :: $C"
  done
done
# A known write beside a silent local one still asks; two known ones stay quiet headless.
want relaxed ask "a devnet write beside a Relaxed-silent local one still asks" \
  "solana program deploy -ul a.so; solana program deploy -ud b.so"
assert_eq silent "$(hverdict "$GUARD" relaxed "solana program deploy -ud a.so; solana program deploy -ut b.so")" \
  "[relaxed] headless: two known non-mainnet writes stay quiet"
# Controls.
M="$(omutant nosplit 'gsub(/[;&|`]/, "&\n")' 'x = 1')"
assert_eq silent "$(hverdict "$M/onchain-guard.sh" relaxed "solana program deploy -ud a.so; solana program deploy -um b.so")" \
  "planted failure caught — statements left joined: the write after the ; is never matched"
rm -rf "$M"
M="$(omutant firstonly '[ -n "$s" ] || continue' '[ "$WORST" = 0 ] || break')"
assert_eq silent "$(hverdict "$M/onchain-guard.sh" relaxed "solana program deploy -ud a.so && solana program deploy -um b.so")" \
  "planted failure caught — only the first write judged: the mainnet one beside it goes quiet"
rm -rf "$M"

# ── redirections, backticks and repeated cluster flags ──────────────────────
# A redirection's `&` (2>&1, >&2, &>, &>>, <&0, 2>&-) was read as a separator, so the
# write ended there and every flag after it was lost: the cluster fell back to the
# project default and --final/--disable slipped past the irreversible check. These run
# with a devnet default (Anchor.toml and a stub `solana config`), which is what made
# the mainnet flag after the redirection matter.
echo "[redirections do not end a write; backticks start one; every cluster flag counts]"
DEVP="$(mktemp -d "${TMPDIR:-/tmp}/onchain-devnet.XXXXXX")"
mkdir -p "$DEVP/bin"
printf '[provider]\ncluster = "devnet"\n' > "$DEVP/Anchor.toml"
printf '#!/bin/sh\necho "RPC URL: https://api.devnet.solana.com"\n' > "$DEVP/bin/solana"
chmod +x "$DEVP/bin/solana"
# dverdict <guard> <tier> <headless 0|1> <command> -> deny | ask | silent, devnet defaults
dverdict() {
  local g=$1 pay out
  [ -f "$g" ] || { echo "missing-guard:$g"; return; }
  pay="$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$4")"
  out="$(cd "$DEVP" && printf '%s' "$pay" | PATH="$DEVP/bin:$PATH" CLAUDE_PROJECT_DIR="$DEVP" \
    SOLANA_CONFIG_FILE=/nonexistent KIT_FIREWALL_TIER="$2" KIT_FIREWALL_HEADLESS="$3" sh "$g" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
# The premise: with no flag these really are devnet, and a redirection alone is harmless.
for C in "solana program deploy a.so" "anchor deploy" "solana program deploy -ud a.so 2>&1" "anchor deploy 2>&1"; do
  assert_eq silent "$(dverdict "$GUARD" relaxed 1 "$C")" "[relaxed] headless, devnet default: quiet :: $C"
done
REDIR_MAIN=(
  "solana program deploy a.so 2>&1 -um"
  "anchor deploy 2>&1 --provider.cluster mainnet"
  "solana program deploy a.so >&2 -um"
  "solana program deploy a.so 1>&2 --url mainnet-beta"
  "solana program deploy a.so &> deploy.log -um"
  "solana program deploy a.so &>> deploy.log -um"
  "solana program deploy a.so 2>&- -um"
  "solana program deploy a.so <&0 -um"
  "solana program deploy a.so 2>&1 --url https://rpc.mycorp.io"
  "solana program deploy -ud a.so |& solana program deploy -um b.so"
)
for C in "${REDIR_MAIN[@]}"; do
  assert_eq deny "$(dverdict "$GUARD" relaxed 1 "$C")" "[relaxed] headless: the flag after the redirection is read :: $C"
  assert_eq deny "$(dverdict "$GUARD" high 1 "$C")" "[high] headless: the flag after the redirection is read :: $C"
done
REDIR_IRREV=(
  "solana program deploy a.so -ud 2>&1 --final"
  "solana program set-upgrade-authority PID 2>&1 --final"
  "spl-token authorize MINT mint 2>&1 --disable"
  "spl-token authorize MINT mint >&2 --disable"
)
for C in "${REDIR_IRREV[@]}"; do
  for T in relaxed high; do
    assert_eq deny "$(dverdict "$GUARD" "$T" 0 "$C")" "[$T] the irreversible flag after a redirection still denies :: $C"
  done
done
M="$(omutant redir 'gsub(/[0-9]*[<>]&[0-9]*-?/, " ")' 'x = 1')"
assert_eq silent "$(dverdict "$M/onchain-guard.sh" relaxed 1 "solana program deploy a.so 2>&1 -um")" \
  "planted failure caught — redirections read as separators again: the mainnet flag is lost"
rm -rf "$M"

# A backtick substitution runs its command exactly as $( ) does.
BTICK=(
  'echo `solana program deploy b.so -um`'
  'X=`anchor deploy --provider.cluster mainnet`'
  'echo ok `solana program deploy b.so --url https://rpc.mycorp.io` done'
)
for C in "${BTICK[@]}"; do
  assert_eq deny "$(dverdict "$GUARD" relaxed 1 "$C")" "[relaxed] headless: a write in backticks is gated :: $C"
  assert_eq deny "$(dverdict "$GUARD" high 1 "$C")" "[high] headless: a write in backticks is gated :: $C"
  assert_eq ask "$(dverdict "$GUARD" relaxed 0 "$C")" "[relaxed] interactive: a write in backticks asks :: $C"
done
assert_eq deny "$(dverdict "$GUARD" relaxed 0 'echo `solana program deploy b.so --final`')" \
  "[relaxed] an irreversible write in backticks denies"
assert_eq silent "$(dverdict "$GUARD" relaxed 0 'echo `solana balance -um`')" \
  "[relaxed] a read in backticks stays silent"
M="$(omutant btick 'gsub(/[;&|`]/, "&\n")' 'gsub(/[;&|]/, "&\n")')"
python3 - "$M/onchain-guard.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
find = "RE='(^|[;&|(`]|"
assert s.count(find) == 1, "RE prefix not found; update the mutation"
open(p, "w", encoding="utf-8").write(s.replace(find, "RE='(^|[;&|(]|"))
PY
assert_eq silent "$(dverdict "$M/onchain-guard.sh" relaxed 1 'echo `solana program deploy b.so -um`')" \
  "planted failure caught — a backtick is no statement start again: the write in it is not seen"
rm -rf "$M"

# Every cluster flag in a statement counts; clap lets the last repeat win, so the first
# is not safe to trust.
REPEAT=(
  "anchor deploy --provider.cluster devnet --provider.cluster mainnet"
  "solana program deploy -ud -um p.so"
  "solana program deploy --url devnet --url=mainnet-beta p.so"
  "solana program deploy -ud p.so -u https://api.mainnet-beta.solana.com"
)
for C in "${REPEAT[@]}"; do
  assert_eq deny "$(dverdict "$GUARD" high 0 "$C")" "[high] a repeated cluster flag is judged by its worst value :: $C"
  assert_eq deny "$(dverdict "$GUARD" relaxed 1 "$C")" "[relaxed] headless: same :: $C"
done
assert_eq deny "$(dverdict "$GUARD" relaxed 1 "solana program deploy --url devnet --url https://rpc.mycorp.io p.so")" \
  "[relaxed] headless: an unidentified repeat beside devnet is denied"
assert_eq silent "$(dverdict "$GUARD" relaxed 1 "solana program deploy -ud --url https://api.devnet.solana.com p.so")" \
  "[relaxed] headless: two devnet spellings stay quiet"
M="$(omutant firstflag 'CANDS=${FLAGS#"$KIT_LF"} SRC='"'"'command flag'"'"'' 'CANDS=$(printf "%s\n" "$FLAGS" | sed -n 2p) SRC='"'"'command flag'"'"'')"
assert_eq ask "$(dverdict "$M/onchain-guard.sh" high 0 "anchor deploy --provider.cluster devnet --provider.cluster mainnet")" \
  "planted failure caught — only the first cluster flag read: the mainnet repeat is judged devnet"
rm -rf "$M"
rm -rf "$DEVP"

# ── the headless signal: what a hook actually gets ─────────────────────────
# Claude Code starts each hook as its own session leader with no controlling
# terminal, so `(exec 3</dev/tty)` fails in an INTERACTIVE session too; keyed on that
# probe, the #307 denies replaced every interactive prompt. These run the hooks the
# way Claude Code does — no KIT_FIREWALL_HEADLESS, a new session with no terminal, a
# clean environment (no CI markers) — and vary only what Claude Code sets.
echo "[headless signal: no override, no terminal, the environment Claude Code gives a hook]"
EGRESS="$REPO_ROOT/.claude/hooks/egress-guard.sh"
# nottyverdict <guard> <tier> <command> [VAR=value...] -> deny | ask | silent
nottyverdict() {
  [ -f "$1" ] || { echo "missing-guard:$1"; return; }
  python3 - "$REPO_ROOT" "$@" <<'PY'
import json, os, subprocess, sys
root, guard, tier, cmd, *extra = sys.argv[1:]
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/"),
       "CLAUDE_PROJECT_DIR": root, "KIT_FIREWALL_TIER": tier}
env.update(kv.split("=", 1) for kv in extra)
pay = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": cmd}})
r = subprocess.run(["sh", guard], input=pay, capture_output=True, text=True, cwd=root, env=env,
                   start_new_session=True)
out = r.stdout
print("deny" if '"deny"' in out or r.returncode == 2 else "ask" if '"ask"' in out else "silent")
PY
}
# The premise: in that runner the terminal probe fails, as it does in a real hook.
NOTTY="$(python3 -c '
import subprocess
r = subprocess.run(["sh", "-c", "(exec 3</dev/tty) 2>/dev/null && echo tty || echo notty"],
                   capture_output=True, text=True, start_new_session=True, stdin=subprocess.DEVNULL)
print(r.stdout.strip())')"
assert_eq notty "$NOTTY" "the runner has no controlling terminal, like a Claude Code hook"
ATT=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli)
UNATT=(CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli)
PUBC="npm publish --access public"
UNK="solana program deploy --url https://rpc.mycorp.io p.so"
MAIN="solana program deploy --url mainnet-beta p.so"
DEV="solana program deploy -ud p.so"
# Interactive Claude Code: the prompts survive the failed probe.
assert_eq ask "$(nottyverdict "$EGRESS" relaxed "$PUBC" "${ATT[@]}")" "interactive (attended): a Relaxed publish asks, not a probe-driven deny"
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$UNK" "${ATT[@]}")" "interactive (attended): an unidentified cluster asks"
assert_eq ask "$(nottyverdict "$GUARD" high "$UNK" "${ATT[@]}")" "interactive (attended): High asks on an unidentified cluster too"
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$MAIN" "${ATT[@]}")" "interactive (attended): mainnet asks below High"
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$DEV" "${ATT[@]}")" "interactive (attended): a devnet write asks instead of going silent"
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$UNK" CLAUDE_CODE_ENTRYPOINT=cli)" "entrypoint cli alone reads as interactive"
# claude -p and the Agent SDK: the denies hold.
assert_eq deny "$(nottyverdict "$EGRESS" relaxed "$PUBC" "${UNATT[@]}")" "claude -p (unattended): a Relaxed publish is denied"
assert_eq silent "$(nottyverdict "$EGRESS" relaxed "$PUBC" "${UNATT[@]}" CONFIRM_PUBLISH=1)" "claude -p: CONFIRM_PUBLISH=1 lets it run"
assert_eq deny "$(nottyverdict "$GUARD" relaxed "$UNK" "${UNATT[@]}")" "claude -p (unattended): an unidentified cluster is denied"
assert_eq deny "$(nottyverdict "$GUARD" relaxed "$MAIN" "${UNATT[@]}")" "claude -p (unattended): mainnet is denied"
assert_eq silent "$(nottyverdict "$GUARD" relaxed "$DEV" "${UNATT[@]}")" "claude -p (unattended): a devnet write goes quiet"
assert_eq deny "$(nottyverdict "$GUARD" relaxed "$UNK" CLAUDE_CODE_ENTRYPOINT=sdk-ts)" "an sdk-* entrypoint alone reads as headless"
assert_eq deny "$(nottyverdict "$EGRESS" relaxed "$PUBC" CI=true)" "a CI marker alone reads as headless"
# No signal at all (another harness): never a probe-driven deny. The gated actions
# ask, which a real headless run refuses; plain asks go silent as before.
assert_eq ask "$(nottyverdict "$EGRESS" relaxed "$PUBC")" "no signal: a publish asks rather than being denied or running silently"
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$UNK")" "no signal: an unidentified cluster asks"
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$MAIN")" "no signal: mainnet asks"
assert_eq silent "$(nottyverdict "$GUARD" relaxed "$DEV")" "no signal: a devnet ask still goes quiet on the failed probe"
# An unrecognised value decides nothing.
assert_eq ask "$(nottyverdict "$GUARD" relaxed "$UNK" CLAUDE_CODE_SESSION_ATTENDED=maybe CLAUDE_CODE_ENTRYPOINT=other)" \
  "unrecognised values: no signal, so an ask"
# Control: key kit_confirm on the terminal probe again and the interactive prompt
# becomes the probe-driven deny the review observed.
M="$(mktemp -d "${TMPDIR:-/tmp}/onchain-mut-probe.XXXXXX")"
cp -R "$REPO_ROOT/.claude/hooks/." "$M/"
python3 - "$M/lib-headless.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
find = "  kit_known_headless || return 0\n"
assert s.count(find) == 1, "kit_confirm's headless test not found; update the mutation"
open(p, "w", encoding="utf-8").write(s.replace(find, "  (exec 3</dev/tty) 2>/dev/null && return 0\n"))
PY
assert_eq deny "$(nottyverdict "$M/egress-guard.sh" relaxed "$PUBC" "${ATT[@]}")" \
  "planted failure caught — the probe back in kit_confirm: an interactive publish is denied"
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
