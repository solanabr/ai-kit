#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SETTINGS="$REPO_ROOT/.claude/settings.json"

echo "[test_settings_deep] Deep validation of settings.json structure"
echo ""

# Helper: query JSON with python3
json_get() {
  python3 -c "
import json, sys
data = json.load(open('$SETTINGS'))
try:
    result = eval('data$1')
    if isinstance(result, bool):
        print(str(result).lower())
    elif isinstance(result, (list, dict)):
        print(json.dumps(result))
    else:
        print(result)
except (KeyError, IndexError, TypeError):
    print('__MISSING__')
" 2>/dev/null
}

json_len() {
  python3 -c "
import json
data = json.load(open('$SETTINGS'))
try:
    result = eval('data$1')
    print(len(result))
except (KeyError, IndexError, TypeError):
    print('0')
" 2>/dev/null
}

json_contains() {
  python3 -c "
import json, sys
data = json.load(open('$SETTINGS'))
try:
    result = eval('data$1')
    if isinstance(result, list):
        sys.exit(0 if '$2' in result else 1)
    elif isinstance(result, dict):
        sys.exit(0 if '$2' in result else 1)
    elif isinstance(result, str):
        sys.exit(0 if '$2' in result else 1)
    else:
        sys.exit(1)
except (KeyError, IndexError, TypeError):
    sys.exit(1)
" 2>/dev/null
}

# --- Environment variables ---
echo "[env]"
# Deliberately unset: the effort env var overrides /effort for every user, coordinator
# mode strips the main agent's own tools (every action becomes a subagent), agent teams
# are experimental and turn subagents Claude names into teammates, and the two output
# caps only restated Claude Code's defaults. Users opt in via .claude/settings.local.json.
for var in CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_COORDINATOR_MODE CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
           BASH_MAX_OUTPUT_LENGTH MAX_MCP_OUTPUT_TOKENS; do
  assert_eq "__MISSING__" "$(json_get "[\"env\"][\"$var\"]")" "env.$var not set"
done

# --- Sandbox ---
echo "[sandbox]"
assert_eq "true" "$(json_get '["sandbox"]["enabled"]')" "sandbox.enabled == true"

# Check denyWrite contains critical paths
DENY_WRITE="$(json_get '["sandbox"]["filesystem"]["denyWrite"]')"
assert_contains "$DENY_WRITE" "~/.ssh" "sandbox.filesystem.denyWrite contains ~/.ssh"
assert_contains "$DENY_WRITE" "~/.gnupg" "sandbox.filesystem.denyWrite contains ~/.gnupg"
assert_contains "$DENY_WRITE" "~/.aws" "sandbox.filesystem.denyWrite contains ~/.aws"
assert_contains "$DENY_WRITE" "~/.config/solana/id.json" "sandbox.filesystem.denyWrite contains solana key"

# macOS Seatbelt blocks listening sockets by default, so solana-test-validator, Surfpool
# (anchor test) and dev servers need local binding.
assert_eq "true" "$(json_get '["sandbox"]["network"]["allowLocalBinding"]')" "sandbox.network.allowLocalBinding == true"
# SSH remotes need direct network and ~/.ssh, gh needs its config and keychain: neither
# works inside the sandbox, so these run outside it (still behind the secrets hook and permissions).
EXCLUDED="$(json_get '["sandbox"]["excludedCommands"]')"
for c in "git push *" "git pull *" "git fetch *" "gh pr *" "gh run *"; do
  assert_contains "$EXCLUDED" "\"$c\"" "sandbox.excludedCommands has '$c'"
done

# --- Plugins, MCP approval, attribution ---
echo "[user choices]"
# LSP plugins need their own language server binary; Claude Code offers the matching
# plugin once the binary is on PATH. Project MCP servers get Claude Code's approval prompt.
LSP_ON="$(python3 -c "
import json
d = json.load(open('$SETTINGS')).get('enabledPlugins') or {}
print(' '.join(p for p in d if p.split('@')[0] in ('rust-analyzer-lsp', 'typescript-lsp', 'csharp-lsp')))
" 2>/dev/null)"
assert_eq "" "$LSP_ON" "no LSP plugins force-enabled (per-user opt-in)"
assert_eq "__MISSING__" "$(json_get '["enableAllProjectMcpServers"]')" "no enableAllProjectMcpServers (keep the MCP approval prompt)"
assert_eq "__MISSING__" "$(json_get '["defaultMode"]')" "no top-level defaultMode (not a setting; permissions.defaultMode is)"
assert_eq '{"commit": "", "pr": ""}' "$(json_get '["attribution"]')" "attribution hides the commit trailer and PR text"

# --- Permissions ---
echo "[permissions]"
ALLOW_LEN="$(json_len '["permissions"]["allow"]')"
TOTAL=$((TOTAL + 1))
if [ "$ALLOW_LEN" -gt 20 ]; then
  echo "  PASS: permissions.allow length > 20 (got $ALLOW_LEN)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: permissions.allow length > 20 (got $ALLOW_LEN)"
  FAIL=$((FAIL + 1))
fi

# assert_rule <allow|ask|deny> <rule> <yes|no> <message>: exact membership in a permissions list
assert_rule() {
  local got=no
  if json_contains "[\"permissions\"][\"$1\"]" "$2"; then got=yes; fi
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$3" ]; then
    echo "  PASS: $4"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $4"
    FAIL=$((FAIL + 1))
  fi
}

# Agents install the extension packs they link into without a prompt (#96), but only through
# list and add: prune, select and uninstalled still ask.
assert_rule allow "Bash(bash .claude/bin/skills.sh list)" yes "permissions.allow has skills.sh list"
assert_rule allow "Bash(bash .claude/bin/skills.sh add *)" yes "permissions.allow has skills.sh add"
SKILLS_ALLOW="$(python3 -c "
import fnmatch, json
allow = [r[5:-1] for r in json.load(open('$SETTINGS'))['permissions']['allow'] if r.startswith('Bash(')]
for c in ('list', 'add sendai', 'prune', 'select a b', 'uninstalled'):
    print(c.split()[0] + '=' + ('yes' if any(fnmatch.fnmatchcase('bash .claude/bin/skills.sh ' + c, r) for r in allow) else 'no'))
" 2>/dev/null | tr '\n' ' ')"
assert_eq "list=yes add=yes prune=no select=no uninstalled=no " "$SKILLS_ALLOW" "only skills.sh list and add run without a prompt"

# Secret access and irreversible on-chain actions are hard blocks.
for r in "Read(~/.ssh/**)" "Read(~/.config/solana/id.json)" "Bash(cat *keypair*.json)" "Bash(gh auth token *)" \
         "Bash(solana program set-upgrade-authority *--final*)" "Bash(solana program close *--bypass-warning*)"; do
  assert_rule deny "$r" yes "permissions.deny has $r"
done
# Destructive filesystem and git commands stay hard blocks. "mkfs*" also catches mkfs.ext4,
# which "mkfs *" misses, and deny wins over the "git clean *" ask rule for -fdx and -fX.
for r in "Bash(mkfs*)" "Bash(rm -rf ~)" "Bash(rm -rf ~/*)" "Bash(rm -rf .git)" "Bash(rm -rf .git/*)" \
         "Bash(git clean -fdx*)" "Bash(git clean -fX*)"; do
  assert_rule deny "$r" yes "permissions.deny has $r"
done
# Deny rules for subcommands the Solana CLIs don't have are gone (their real counterparts ask),
# and so are the blanket program-authority denies that also blocked reclaiming buffer SOL.
for r in "Bash(spl-token set-authority *)" "Bash(solana withdraw-from-stake-account *)" \
         "Bash(solana program set-upgrade-authority *)" "Bash(solana program close *)"; do
  assert_rule deny "$r" no "permissions.deny drops $r"
done
# Program deploys, upgrades, buffer writes, closes and authority changes ask on every cluster.
for r in "Bash(solana program deploy *)" "Bash(solana program write-buffer *)" "Bash(solana program upgrade *)" \
         "Bash(solana program set-upgrade-authority *)" "Bash(solana program close *)" "Bash(anchor deploy *)" \
         "Bash(anchor upgrade *)" "Bash(spl-token transfer *)" "Bash(git push --force*)" "Bash(git clean *)"; do
  assert_rule ask "$r" yes "permissions.ask has $r"
done
# Deny wins over ask, so a rule in both lists never prompts.
OVERLAP="$(python3 -c "
import json
p = json.load(open('$SETTINGS'))['permissions']
print(' '.join(sorted(set(p.get('ask', [])) & set(p['deny']))) or 'none')
" 2>/dev/null)"
assert_eq "none" "$OVERLAP" "no rule sits in both permissions.ask and permissions.deny"
# Mainnet deploys ask like every other cluster. A deny glob on mainnet blocked /deploy's
# "solana program deploy ... --url mainnet-beta" step instead of prompting.
MAINNET_DENY="$(python3 -c "
import fnmatch, json
deny = json.load(open('$SETTINGS'))['permissions']['deny']
cmd = 'solana program deploy target/verifiable/p.so --url mainnet-beta --use-rpc'
print(' '.join(r for r in deny if 'mainnet' in r or (r.startswith('Bash(') and fnmatch.fnmatchcase(cmd, r[5:-1]))) or 'none')
" 2>/dev/null)"
assert_eq "none" "$MAINNET_DENY" "no permissions.deny rule targets mainnet or blocks /deploy's --url mainnet-beta step"
# solana-keygen new/recover default to ~/.config/solana/id.json. The sandbox blocks that write,
# but a retry outside it (or a machine without the sandbox) runs under the Bash(solana-keygen *)
# allow rule, so --force/-f must ask. A different -o path without --force stays prompt-free.
# ask_matches <command>: does any Bash(...) ask rule match it (* matches any text)?
ask_matches() {
  python3 -c "
import fnmatch, json, sys
ask = json.load(open('$SETTINGS'))['permissions'].get('ask', [])
cmd = sys.argv[1]
print('yes' if any(fnmatch.fnmatchcase(cmd, r[5:-1]) for r in ask if r.startswith('Bash(') and r.endswith(')')) else 'no')
" "$1" 2>/dev/null
}
for c in "solana-keygen new --force" "solana-keygen new -f" "solana-keygen new --no-bip39-passphrase -f" \
         "solana-keygen new -o target/deploy/x-keypair.json --force" "solana-keygen recover --force" \
         "solana-keygen recover -f" "solana-keygen recover ASK --force"; do
  assert_eq "yes" "$(ask_matches "$c")" "an ask rule covers: $c"
done
assert_eq "no" "$(ask_matches "solana-keygen new --no-bip39-passphrase -o target/deploy/x-keypair.json")" "a new keypair at another path without --force doesn't ask"

# --- Hooks ---
echo "[hooks]"
HOOKS="$(json_get '["hooks"]')"
HOOK_EVENTS="$(python3 -c "import json; print(' '.join(sorted(json.load(open('$SETTINGS'))['hooks'])))" 2>/dev/null)"
# Nothing formats files, runs builds or echoes after a tool call, a turn or a subagent.
assert_eq "PreToolUse SessionStart" "$HOOK_EVENTS" "hooks are only SessionStart and PreToolUse"

# Hook contract: matchers only match tool names (no undocumented "when" key),
# the payload is read from stdin JSON, and only exit 2 blocks a tool call.
NO_WHEN="$(python3 -c "
import json
d = json.load(open('$SETTINGS'))
print('true' if all('when' not in e for evs in d['hooks'].values() for e in evs) else 'false')
" 2>/dev/null)"
assert_eq "true" "$NO_WHEN" "no hook entry has a 'when' key (matchers only match tool names)"
GATE_CMD="$(python3 -c "
import json
d = json.load(open('$SETTINGS'))
cmds = [h['command'] for e in d['hooks']['PreToolUse'] for h in e['hooks']]
print(next((c for c in cmds if 'Blocked: reading private keys' in c), '__MISSING__'))
" 2>/dev/null)"
assert_contains "$GATE_CMD" "exit 2" "secrets-gate PreToolUse hook blocks with exit 2"
assert_contains "$GATE_CMD" "tool_input.command" "secrets-gate hook reads the command from stdin JSON"
assert_contains "$HOOKS" 'permissionDecision\":\"ask' "on-chain write hook asks for approval through permissionDecision"
# The model could add an env prefix itself; approval has to come from the user.
assert_file_not_contains "$SETTINGS" "CONFIRM_MAINNET" "no CONFIRM_MAINNET env-prefix confirmation"
assert_file_not_contains "$SETTINGS" "pre-commit checks" "no hook runs builds or tests on git commit"
for legacy in command_matches CLAUDE_FILE_PATH CLAUDE_TOOL_EXIT_CODE CLAUDE_SUBAGENT_NAME "read -r"; do
  assert_file_not_contains "$SETTINGS" "$legacy" "hooks do not rely on unsupported '$legacy'"
done

# --- Model routing ---
# modelDefaults is not a Claude Code setting (silently ignored); routing lives in the
# agent/command `model:` frontmatter, checked by test_model_routing.sh
echo "[model routing]"
assert_eq "__MISSING__" "$(json_get '["modelDefaults"]')" "no modelDefaults key (not a Claude Code setting)"

# --- safe-ai-skill (core security plugin) ---
# A full install registers the kit's stbr marketplace and enables safe-ai-skill for the
# project; Claude Code applies both after the folder is trusted.
echo "[safe-ai-skill]"
assert_eq "true" "$(json_get '["enabledPlugins"]["safe-ai-skill@stbr"]')" "enabledPlugins enables safe-ai-skill@stbr"
assert_eq "https://github.com/solanabr/ai-kit.git" "$(json_get '["extraKnownMarketplaces"]["stbr"]["source"]["url"]')" "extraKnownMarketplaces.stbr points at the kit marketplace"

print_summary
