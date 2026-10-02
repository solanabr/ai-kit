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
# Stub solana so the results don't depend on this machine's CLI config. `-C`/`--config`
# is honored, because the on-chain gate has to resolve the cluster from the config file
# the command actually names — it mislabelled mainnet otherwise.
cat > "$WORK/bin/solana" <<'EOF'
#!/bin/sh
CFG=""
prev=""
for a in "$@"; do
  case "$prev" in -C|--config) CFG="$a" ;; esac
  case "$a" in --config=*) CFG="${a#--config=}" ;; esac
  prev="$a"
done
case "$1" in
  config)
    if [ -n "$CFG" ] && [ -r "$CFG" ]; then
      echo "RPC URL: $(sed -n 's/^json_rpc_url:[[:space:]]*//p' "$CFG" | head -1)"
    else
      echo "RPC URL: ${FAKE_RPC:-https://api.devnet.solana.com}"
    fi
    ;;
  address) echo 11111111111111111111111111111111 ;;
esac
EOF
chmod +x "$WORK/bin/solana"
printf 'json_rpc_url: https://api.mainnet-beta.solana.com\n' > "$WORK/mainnet-cli.yml"
printf 'json_rpc_url: https://api.devnet.solana.com\n' > "$WORK/devnet-cli.yml"

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
  OUT="$(cd "$2" && printf '%s' "$payload" | PATH="$WORK/bin:$PATH" FAKE_RPC="${4:-}" \
    CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugin" \
    KIT_FIREWALL_HEADLESS=0 sh -c "$1" 2>"$WORK/err")"
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
  # Matched by script name: the bodies live in .claude/hooks/*.sh now, so there is no
  # message text in settings.json to match on.
  SECRETS="$(hook "$FILE" PreToolUse 'secrets-guard')"
  CHAIN="$(hook "$FILE" PreToolUse 'onchain-guard')"
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

  # Cluster resolution, both sources the gate used to get wrong. An ANCHOR_PROVIDER_URL
  # prefix overrides Anchor.toml for anchor commands, and -C/--config overrides the
  # default solana config: resolving either one wrongly either mislabels mainnet as
  # devnet (no warning on a real mainnet write) or the reverse (a warning that cries wolf).
  run "$CHAIN" "$WORK/devnet" "ANCHOR_PROVIDER_URL=https://api.mainnet-beta.solana.com anchor deploy"
  assert_contains "$OUT" "MAINNET" "an ANCHOR_PROVIDER_URL prefix beats a devnet Anchor.toml"
  assert_contains "$OUT" "ANCHOR_PROVIDER_URL" "the prompt names ANCHOR_PROVIDER_URL as the source"
  run "$CHAIN" "$WORK/mainnet" "ANCHOR_PROVIDER_URL=https://api.devnet.solana.com anchor deploy"
  assert_eq "no" "$(printf '%s' "$OUT" | grep -q MAINNET && echo yes || echo no)" \
    "an ANCHOR_PROVIDER_URL devnet prefix is not labelled MAINNET despite a mainnet Anchor.toml"
  assert_contains "$OUT" '"permissionDecision":"ask"' "it still asks on devnet"
  run "$CHAIN" "$WORK" "solana program deploy target/deploy/x.so -C $WORK/mainnet-cli.yml"
  assert_contains "$OUT" "MAINNET" "-C <config> resolves the cluster from that config file"
  run "$CHAIN" "$WORK" "solana program deploy target/deploy/x.so --config $WORK/mainnet-cli.yml"
  assert_contains "$OUT" "MAINNET" "--config <config> resolves the cluster from that config file"
  run "$CHAIN" "$WORK" "solana program deploy target/deploy/x.so -C $WORK/devnet-cli.yml" \
    "https://api.mainnet-beta.solana.com"
  assert_eq "no" "$(printf '%s' "$OUT" | grep -q MAINNET && echo yes || echo no)" \
    "-C pointing at devnet is not labelled MAINNET even when the default config is mainnet"

  # Headless: Medium and High hard-fail on an ask by design, but an unconditional ask on
  # every cluster made every -p run fail at Relaxed too.
  run "$CHAIN" "$WORK/devnet" "anchor deploy"
  assert_eq "0" "$RC" "a devnet deploy does not exit 2 (a block would hard-fail headless)"
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
    # Containment, not equality: additionalContext also carries the firewall-tier
    # clause wherever a .claude/security.json is readable. What has to hold is that
    # the banner and the context name the same cluster and wallet.
    assert_contains "$AC" "Solana CLI: RPC https://mainnet.helius-rpc.com, wallet 11111111111111111111111111111111." "$V: Claude gets the same RPC and wallet in additionalContext"
    assert_eq "no" "$(printf '%s' "$SM" | grep -q k123 && echo yes || echo no)" "$V: the RPC API key stays out of the banner"
  done
  # Without the Solana CLI the user is told so instead of seeing an empty line.
  mkdir -p "$WORK/nosolana"
  for b in sh awk sed jq cat; do ln -sf "$(command -v "$b")" "$WORK/nosolana/$b"; done
  OUT="$(printf '{"source":"startup"}' | PATH="$WORK/nosolana" CLAUDE_PROJECT_DIR="$REPO_ROOT" sh -c "$SESSION")"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.systemMessage')" "Solana CLI not found on PATH." "without the Solana CLI the banner says so"
fi
OUT="$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" sh -c "$SESSION")"
# The property is that a compact re-adds the context line and NOT the banner; the line
# itself grew a firewall-tier clause, so match on shape rather than pinning it verbatim.
assert_contains "$OUT" "Solana CLI: RPC https://api.devnet.solana.com, wallet 11111111111111111111111111111111." "after /compact or /clear the context line is re-added"
assert_eq "no" "$(printf '%s' "$OUT" | grep -q 'SOLANA\|systemMessage' && echo yes || echo no)" "after /compact or /clear the banner is not re-sent"
OUT="$(printf '{"source":"startup"}' | PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugin" sh -c "$PLUGIN_SESSION")"
assert_eq "" "$OUT" "the plugin SessionStart stays quiet next to a full install"

# ── the firewall tier at session start ──────────────────────────────────────
# Claude has to know which tier it is working under: at High a write outside the repo is
# denied outright, and a model that does not know that reads the EPERM as a broken tool.
# The declared-vs-enforced check is the other half — permission lists merge from four
# sources, so the tier in security.json can silently stop describing the live policy.
echo "[firewall tier in SessionStart]"
FIX="$WORK/tierfix"
mkdir -p "$FIX/.claude"
cp "$REPO_ROOT/.claude/VERSION" "$FIX/.claude/VERSION"

# session_start <tier> <settings json path> -> OUT
session_start() {
  python3 - "$REPO_ROOT/.claude/security.json" "$FIX/.claude/security.json" "$1" "${2:-}" <<'PY'
import json, sys
src, dst, tier, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    d = json.load(open(src))
except Exception:
    d = {}
d["tier"] = tier
if extra == "mismatch":
    d["enforced"] = {"ruleIds": ["Bash(a-rule-that-is-not-in-settings *)"], "hash": "0" * 16}
json.dump(d, open(dst, "w"), indent=2)
PY
  cp "$REPO_ROOT/.claude/settings.json" "$FIX/.claude/settings.json"
  printf '{"hook_event_name":"SessionStart","source":"startup"}' \
    | PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$FIX" sh -c "$SESSION"
}

if [ -f "$REPO_ROOT/.claude/security.json" ]; then
  for t in relaxed high; do
    OUT="$(session_start "$t")"
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$OUT" | grep -q "$t" && printf '%s' "$OUT" | grep -qiE 'firewall|tier'; then
      echo "  PASS: SessionStart names the $t tier"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: SessionStart does not name the $t tier"
      FAIL=$((FAIL + 1))
    fi
  done
  # A healthy record is quiet; a drifted one warns the user, not the context.
  OUT="$(session_start relaxed)"
  assert_eq "no" "$(printf '%s' "$OUT" | grep -qiE 'does not match|mismatch|drift' && echo yes || echo no)" \
    "no mismatch warning when the record matches the live policy"
  OUT="$(session_start relaxed mismatch)"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$OUT" | grep -q '"systemMessage"'; then
    echo "  PASS: a declared-vs-enforced mismatch is reported as a systemMessage"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: a declared-vs-enforced mismatch produced no systemMessage"
    FAIL=$((FAIL + 1))
  fi
  # Whatever it says, an RPC key still never reaches the prompt.
  OUT="$(FAKE_RPC='https://mainnet.helius-rpc.com/?api-key=k123' session_start high mismatch)"
  assert_eq "no" "$(printf '%s' "$OUT" | grep -q k123 && echo yes || echo no)" \
    "the tier line and the mismatch warning both keep the RPC API key out"
else
  echo "  FAIL: .claude/security.json is missing, so the tier line cannot be checked"
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
fi

print_summary
