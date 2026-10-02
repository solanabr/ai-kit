#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_hooks] Replaying tool payloads through the hooks the way Claude Code runs them (sh -c, JSON on stdin)"

WORK="${TMPDIR:-/tmp}/sak-test-hooks.$$"
mkdir -p "$WORK/bin" "$WORK/mainnet" "$WORK/devnet"
trap 'rm -rf "$WORK"' EXIT
printf '[provider]\ncluster = "mainnet"\n' > "$WORK/mainnet/Anchor.toml"
printf '[provider]\ncluster = "devnet"\n' > "$WORK/devnet/Anchor.toml"
# Stub solana so the results don't depend on this machine's CLI config.
cat > "$WORK/bin/solana" <<'EOF'
#!/bin/sh
case "$1" in
  config) echo "RPC URL: ${FAKE_RPC:-https://api.devnet.solana.com}" ;;
  address) echo 11111111111111111111111111111111 ;;
esac
EOF
chmod +x "$WORK/bin/solana"

# hook <file> <event> <marker>: the command of the <event> hook whose text contains <marker>
hook() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, event, marker = sys.argv[1:4]
cmds = [h["command"] for e in json.load(open(path))["hooks"].get(event, []) for h in e["hooks"]]
print(next((c for c in cmds if marker in c), ""))
PY
}

# run <hook> <dir> <bash command> [rpc url]: sets RC, OUT and ERR
run() {
  local payload
  payload="$(python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$3")"
  set +e
  OUT="$(cd "$2" && printf '%s' "$payload" | PATH="$WORK/bin:$PATH" FAKE_RPC="${4:-}" sh -c "$1" 2>"$WORK/err")"
  RC=$?
  set -e
  ERR="$(cat "$WORK/err")"
}

# A hook with a syntax error exits 2, which Claude Code treats as a block on every matching call.
SYNTAX="$(python3 - "$REPO_ROOT" <<'PY'
import json, os, shutil, subprocess, sys
bad = []
shells = ["sh"] + (["dash"] if shutil.which("dash") else [])
for rel in (".claude/settings.json", "plugin/hooks/hooks.json"):
    for event, entries in json.load(open(os.path.join(sys.argv[1], rel)))["hooks"].items():
        for entry in entries:
            for h in entry["hooks"]:
                for sh in shells:
                    r = subprocess.run([sh, "-n"], input=h["command"], capture_output=True, text=True)
                    if r.returncode:
                        bad.append(f"{rel} {event} ({sh}): {r.stderr.strip()[:120]}")
print("; ".join(bad) or "ok")
PY
)"
assert_eq "ok" "$SYNTAX" "every hook command parses with sh -n (and dash -n when present)"

for FILE in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/plugin/hooks/hooks.json"; do
  NAME="${FILE#"$REPO_ROOT"/}"
  echo "[$NAME]"
  SECRETS="$(hook "$FILE" PreToolUse 'Blocked: reading private keys')"
  CHAIN="$(hook "$FILE" PreToolUse 'permissionDecision')"
  assert_eq "yes" "$([ -n "$SECRETS" ] && echo yes || echo no)" "has the secrets gate"
  assert_eq "yes" "$([ -n "$CHAIN" ] && echo yes || echo no)" "has the on-chain write gate"

  # Ordinary edit/commit loop: both gates stay silent.
  for c in "ls -la" "git status" "git commit -m 'docs: explain anchor deploy'" "cargo test" "npm test" "anchor build"; do
    run "$SECRETS" "$WORK" "$c"
    assert_eq "0|" "$RC|$OUT$ERR" "secrets gate is silent for: $c"
    run "$CHAIN" "$WORK/mainnet" "$c"
    assert_eq "0|" "$RC|$OUT$ERR" "on-chain gate is silent for: $c"
  done

  # Secret access: exit 2 with a one-line alternative.
  run "$SECRETS" "$WORK" "cat ~/.config/solana/id.json"
  assert_eq "2" "$RC" "secrets gate blocks cat ~/.config/solana/id.json"
  assert_contains "$ERR" "solana address" "the block message says what to do instead"
  run "$SECRETS" "$WORK" "gh auth token"
  assert_eq "2" "$RC" "secrets gate blocks gh auth token"
  run "$SECRETS" "$WORK" "solana-keygen new --force -o ~/.config/solana/id.json"
  assert_eq "2" "$RC" "secrets gate blocks overwriting the default wallet with -o"

  # On-chain writes ask the user, and the prompt names the cluster and where it came from.
  run "$CHAIN" "$WORK/mainnet" "anchor deploy"
  assert_contains "$OUT" '"permissionDecision":"ask"' "anchor deploy asks for approval"
  assert_contains "$OUT" "MAINNET (from Anchor.toml)" "cluster comes from Anchor.toml"
  run "$CHAIN" "$WORK/devnet" "anchor deploy"
  assert_contains "$OUT" "devnet (from Anchor.toml)" "a devnet deploy says devnet"
  run "$CHAIN" "$WORK" "solana program deploy target/deploy/x.so -um"
  assert_contains "$OUT" "MAINNET (from command flag)" "-um resolves to mainnet"
  run "$CHAIN" "$WORK" "CONFIRM_MAINNET=1 solana program deploy target/deploy/x.so" "https://mainnet.helius-rpc.com/?api-key=k123"
  assert_contains "$OUT" "MAINNET (from solana config)" "an env prefix no longer skips the confirmation"
  assert_eq "no" "$(printf '%s' "$OUT" | grep -q k123 && echo yes || echo no)" "RPC API keys stay out of the prompt"
  run "$CHAIN" "$WORK" "solana program close --buffers -ud"
  assert_contains "$OUT" '"permissionDecision":"ask"' "reclaiming buffer SOL asks instead of failing"

  # Irreversible actions: exit 2.
  for c in "solana program set-upgrade-authority PID --final" "solana program close PID --bypass-warning" \
           "solana program deploy x.so --final" "spl-token authorize MINT mint --disable"; do
    run "$CHAIN" "$WORK" "$c"
    assert_eq "2" "$RC" "on-chain gate blocks: $c"
  done
done

echo "[SessionStart]"
SESSION="$(hook "$REPO_ROOT/.claude/settings.json" SessionStart 'SessionStart')"
OUT="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | PATH="$WORK/bin:$PATH" FAKE_RPC='https://mainnet.helius-rpc.com/?api-key=k123' CLAUDE_PROJECT_DIR="$REPO_ROOT" sh -c "$SESSION")"
assert_contains "$OUT" "Solana CLI: RPC https://mainnet.helius-rpc.com, wallet 11111111111111111111111111111111." "Claude gets one line with the RPC host and wallet"
assert_eq "no" "$(printf '%s' "$OUT" | grep -q k123 && echo yes || echo no)" "the RPC API key stays out of the session context"
PLUGIN_SESSION="$(hook "$REPO_ROOT/plugin/hooks/hooks.json" SessionStart 'SessionStart')"
if command -v jq >/dev/null 2>&1; then
  assert_contains "$OUT" '"systemMessage"' "the banner goes to the user as a systemMessage, not into context"
  # The user sees the cluster and wallet under the banner (#115), and Claude keeps the same
  # values in additionalContext, so a session pointed at mainnet is visible to both.
  # Same check for the plugin variant, run where there is no full install.
  mkdir -p "$WORK/plugin-project"
  for V in settings plugin; do
    if [ "$V" = settings ]; then CMDV="$SESSION" DIR="$REPO_ROOT"; else CMDV="$PLUGIN_SESSION" DIR="$WORK/plugin-project"; fi
    OUT="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | PATH="$WORK/bin:$PATH" FAKE_RPC='https://mainnet.helius-rpc.com/?api-key=k123' CLAUDE_PROJECT_DIR="$DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugin" sh -c "$CMDV")"
    SM="$(printf '%s' "$OUT" | jq -r '.systemMessage')"
    AC="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')"
    assert_contains "$SM" "SuperteamBR" "$V: the systemMessage still carries the banner"
    assert_contains "$SM" "🔗 https://mainnet.helius-rpc.com  👛 11111111111111111111111111111111" "$V: the user sees the cluster and wallet under the banner"
    assert_eq "Solana CLI: RPC https://mainnet.helius-rpc.com, wallet 11111111111111111111111111111111." "$AC" "$V: Claude gets the same RPC and wallet in additionalContext"
    assert_eq "no" "$(printf '%s' "$SM" | grep -q k123 && echo yes || echo no)" "$V: the RPC API key stays out of the banner"
  done
  # Without the Solana CLI the user is told so instead of seeing an empty line.
  mkdir -p "$WORK/nosolana"
  for b in sh awk sed jq cat; do ln -sf "$(command -v "$b")" "$WORK/nosolana/$b"; done
  OUT="$(printf '{"source":"startup"}' | PATH="$WORK/nosolana" CLAUDE_PROJECT_DIR="$REPO_ROOT" sh -c "$SESSION")"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.systemMessage')" "Solana CLI not found on PATH." "without the Solana CLI the banner says so"
fi
OUT="$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" sh -c "$SESSION")"
assert_eq "Solana CLI: RPC https://api.devnet.solana.com, wallet 11111111111111111111111111111111." "$OUT" "after /compact or /clear only the context line is re-added"
OUT="$(printf '{"source":"startup"}' | PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugin" sh -c "$PLUGIN_SESSION")"
assert_eq "" "$OUT" "the plugin SessionStart stays quiet next to a full install"

print_summary
