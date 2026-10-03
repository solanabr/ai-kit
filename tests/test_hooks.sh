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
# A PATH without jq, so the hooks' awk fallback for reading the payload gets exercised too.
mkdir -p "$WORK/nojq"
for b in sh awk sed cat tr head grep dirname; do ln -s "$(command -v "$b")" "$WORK/nojq/$b"; done
ln -s "$WORK/bin/solana" "$WORK/nojq/solana"
NL='
'

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
  OUT="$(cd "$2" && printf '%s' "$payload" | PATH="${HOOK_PATH:-$WORK/bin:$PATH}" FAKE_RPC="${4:-}" \
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

  # Wrapper forms get the bare command's decision (#110): the gate normalises each
  # statement before matching, dropping wrapper binaries with their own options.
  DEPLOY="solana program deploy p.so --url mainnet-beta"
  FINAL="solana program set-upgrade-authority PID --final"
  for w in "env %s" "env -u HOME FOO=1 %s" "echo p.so | xargs -I{} %s" "sh -c '%s'" "bash -lc \"%s\"" \
           "/usr/local/bin/%s" "nohup %s &" "time %s" "command %s" "sudo -E %s" "timeout 60 %s" \
           "sudo env X=1 nohup %s" "cd x && %s" "x=\$(%s)" "echo \"\$(%s)\"" "bash <<'EOF'${NL}%s${NL}EOF"; do
    # shellcheck disable=SC2059
    run "$CHAIN" "$WORK" "$(printf "$w" "$DEPLOY")"
    assert_contains "$OUT" "MAINNET (from command flag)" "asks like the bare deploy: $w"
    # shellcheck disable=SC2059
    run "$CHAIN" "$WORK" "$(printf "$w" "$FINAL")"
    assert_eq "2" "$RC" "blocks like the bare --final: $w"
  done
  for c in "solana program  deploy p.so --url mainnet-beta" "solana  program"$'\t'"deploy p.so -um"; do
    run "$CHAIN" "$WORK" "$c"
    assert_contains "$OUT" "MAINNET (from command flag)" "extra whitespace still asks: ${c//$NL/\\n}"
  done
  # Still open on #138, because both need the verb located by argument position rather
  # than by an anchored regex: `solana -um program deploy p.so` (a global flag between
  # the binary and the subcommand) and `solana "program" deploy p.so -um` (a quoted
  # subcommand) are both silent. Normalising statements does not reach either.

  # Text that only mentions a gated command is not a command (#111). The on-chain gate
  # gets this right wherever the verb sits mid-statement.
  for c in "gh issue create --title 'Gate: --final bypass' --body \"env ${FINAL}\"" \
           "git commit -m \"fix: gate ${FINAL}\"" "echo \"${FINAL}\"" "grep -rn -e '--final' docs/" \
           "rg -- '--bypass-warning' ." "echo \$((1+2)) # ${FINAL}"; do
    run "$CHAIN" "$WORK/mainnet" "$c"
    assert_eq "0|" "$RC|$OUT$ERR" "a mention is not blocked: ${c//$NL/\\n}"
  done
  run "$CHAIN" "$WORK" "cat <<EOF${NL}\$(${DEPLOY})${NL}EOF"
  assert_contains "$OUT" '"permissionDecision":"ask"' "an unquoted heredoc still runs its \$(...), so that asks"
  # Still open on #138: a heredoc BODY line that begins with a gated verb is matched as
  # though it were a statement, because the gate anchors on ^ and never learns where the
  # body starts. `cat > notes.md <<'EOF' ... --final ... EOF` is a hard exit 2 — writing a
  # document is blocked — and a quoted delimiter's $(...) is asked about even though a
  # quoted heredoc never expands it. Both need the body skipped, which is heredoc
  # tracking, not statement normalisation.

  # Credential reads stay blocked however they are wrapped; mentions in data do not block.
  for c in "env FOO=1 cat ~/.ssh/id_rsa" "sh -c 'cat ~/.config/solana/id.json'" "cat \"\$HOME/.ssh/id_ed25519\"" \
           "tar czf k.tgz ~/.config/solana/id.json" "xargs cat < ~/.ssh/id_rsa" "echo x > ~/.ssh/authorized_keys" \
           "echo \"\$(cat ~/.config/solana/id.json)\"" "grep -f ~/.ssh/id_rsa x" "gh auth status --show-token" \
           "gh issue create --title t --body-file ~/.ssh/id_rsa"; do
    run "$SECRETS" "$WORK" "$c"
    assert_eq "2" "$RC" "secrets gate blocks: ${c//$NL/\\n}"
  done
  # Still open, and a miss rather than a false positive: a heredoc body whose delimiter is
  # QUOTED is dropped as data even when the heredoc feeds an interpreter or a shell, so
  # `python3 - <<'EOF' print(open('~/.ssh/id_rsa').read()) EOF` and
  # `cat <<EOF | sh ... EOF` both pass. The body does execute in both. The head-command
  # test looks at the head of the line, not at what the pipeline feeds.
  for c in "grep -rn '.config/solana/id.json' README.md .claude/" "rg -n '\\.ssh/' tests/" \
           "git commit -m 'docs: never cat ~/.ssh/id_rsa'" "gh issue create --title x --body 'gh auth token leaks'" \
           "cat > doc.md <<'EOF'${NL}Do not cat ~/.config/solana/id.json${NL}EOF" "echo 'keys live in ~/.config/solana/id.json'"; do
    run "$SECRETS" "$WORK" "$c"
    assert_eq "0|" "$RC|$OUT$ERR" "secrets gate is silent for a mention: ${c//$NL/\\n}"
  done
  # Still open, as a false positive: `git grep -n '.ssh/' -- tests` is blocked. `git grep`
  # is a pattern tool, but the gate only treats grep/rg/sed/awk/jq as such and reads
  # git's first positional as a path.

  # Without jq the gates read the payload with awk and decode the JSON escapes themselves.
  HOOK_PATH="$WORK/nojq"
  run "$CHAIN" "$WORK" "env $DEPLOY"
  assert_contains "$OUT" "MAINNET (from command flag)" "without jq: a wrapped deploy still asks"
  run "$SECRETS" "$WORK" "cat \"\$HOME/.ssh/id_rsa\""
  assert_eq "2" "$RC" "without jq: a credential read is blocked"
  unset HOOK_PATH
  # Still open on #138: a command too nested to parse has no fail-closed path. The gates
  # match what they can see and stay silent otherwise, rather than asking.

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
if command -v jq >/dev/null 2>&1; then
  assert_contains "$OUT" '"systemMessage"' "the banner goes to the user as a systemMessage, not into context"
fi
OUT="$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" sh -c "$SESSION")"
# The property is that a compact re-adds the context line and NOT the banner; the line
# itself grew a firewall-tier clause, so match on shape rather than pinning it verbatim.
assert_contains "$OUT" "Solana CLI: RPC https://api.devnet.solana.com, wallet 11111111111111111111111111111111." "after /compact or /clear the context line is re-added"
assert_eq "no" "$(printf '%s' "$OUT" | grep -q 'SOLANA\|systemMessage' && echo yes || echo no)" "after /compact or /clear the banner is not re-sent"
PLUGIN_SESSION="$(hook "$REPO_ROOT/plugin/hooks/hooks.json" SessionStart 'SessionStart')"
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
