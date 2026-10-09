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
# Every excludedCommands entry lifts the OS sandbox for the ENTIRE command line, not just
# the matched program: `git push -h >/dev/null 2>&1; <read of a denied path>` exited 0 where
# the bare read got EPERM. So every entry is a hole and the list stays short and justified.
#
# Surfpool cannot run inside the sandbox at all (it panics instantly on macOS
# SystemConfiguration and takes `anchor test` with it). git/gh cannot authenticate inside
# it either: the ssh-agent socket and the gh token are both read-denied. The bypass the
# git/gh entries re-open is covered one layer up -- the secrets guard segments a command
# on ; && || | and newline and inspects each statement, so the read in
# `git push -h; cat <secret>` is still blocked. Belt and braces, not either/or.
#
# What must never appear here is a general-purpose interpreter or shell.
EXCLUDED_LIST="$(python3 -c "
import json
print('\n'.join(json.load(open('$SETTINGS')).get('sandbox', {}).get('excludedCommands') or []))" 2>/dev/null)"
assert_eq "anchor test*
gh issue *
gh pr *
gh run *
git fetch *
git pull *
git push *
surfpool *" "$(printf '%s\n' "$EXCLUDED_LIST" | LC_ALL=C sort)" \
  "sandbox.excludedCommands is exactly the justified set (surfpool, anchor test, git, gh)"
# The real invariant: no entry may be a shell or interpreter, which would exempt anything.
SHELL_EXCLUDED="$(printf '%s\n' "$EXCLUDED_LIST" | grep -E '^(sh|bash|zsh|env|python[0-9.]*|node|perl|ruby|make|just|xargs|eval)( |\*|$)' || true)"
assert_eq "" "$SHELL_EXCLUDED" "no shell or interpreter in excludedCommands (it would exempt every command)"

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
# Destructive filesystem commands stay hard blocks. "mkfs*" also catches mkfs.ext4,
# which "mkfs *" misses.
for r in "Bash(mkfs*)" "Bash(rm -rf ~)" "Bash(rm -rf ~/*)" "Bash(rm -rf .git)" "Bash(rm -rf .git/*)"; do
  assert_rule deny "$r" yes "permissions.deny has $r"
done
# Deny rules for subcommands the Solana CLIs don't have are gone (their real counterparts ask),
# and so are the blanket program-authority denies that also blocked reclaiming buffer SOL.
for r in "Bash(spl-token set-authority *)" "Bash(solana withdraw-from-stake-account *)" \
         "Bash(solana program set-upgrade-authority *)" "Bash(solana program close *)"; do
  assert_rule deny "$r" no "permissions.deny drops $r"
done
# Clobbering the working tree with git clean -x is unrecoverable (it also removes ignored
# files, .env included), so it stays denied however the rule is spelled. Checked by command
# coverage, not by pattern string: the generator owns the spelling.
# deny_covers <command> -> yes|no
deny_covers() {
  python3 -c "
import fnmatch, json, sys
deny = json.load(open('$SETTINGS'))['permissions']['deny']
cmd = sys.argv[1]
print('yes' if any(fnmatch.fnmatchcase(cmd, r[5:-1]) for r in deny
                   if r.startswith('Bash(') and r.endswith(')')) else 'no')" "$1" 2>/dev/null
}
for c in "git clean -fdx" "git clean -fX" "git clean -xdf" "git clean -dfx"; do
  assert_eq "yes" "$(deny_covers "$c")" "permissions.deny covers: $c"
done
# A git alias defeats every rule above it: `git config alias.z '!git clean -fdx'` is an
# ordinary config write and the destruction happens later in `git z`, where the glob has
# no verb to match. Checked here against the SHIPPED settings.json as well as against
# generated output in test_firewall.sh, since this file is what install.sh copies.
# `gh repo delete` is the other half of the pair `gh issue delete` already covers.
for c in "git config alias.z '!git clean -fdx'" "git config --global alias.z '!x'" \
         "git config --local alias.co checkout" "git config set alias.z '!x'" \
         "gh repo delete owner/repo --yes" "gh repo delete"; do
  assert_eq "yes" "$(deny_covers "$c")" "permissions.deny covers: $c"
done
# ...and the alias rules are narrow: an ordinary config key is not an alias.
for c in "git config user.email dev@example.com" "git config --global user.name dev" \
         "git config core.autocrlf false"; do
  assert_eq "no" "$(deny_covers "$c")" "permissions.deny leaves ordinary git config alone: $c"
done
# permissions.ask is not a reliable control: verified in-session, `git clean -n` matched an
# ask rule and ran with no prompt while a deny rule blocked `sudo -n true`, with the sandbox
# on. So every prompt is a hook returning permissionDecision "ask" (see test_hooks.sh), and
# Relaxed emits no ask rules at all, which is what keeps it usable headless and in CI.
ASK_LEN="$(json_len '["permissions"]["ask"]')"
if [ "$ASK_LEN" = "0" ]; then
  echo "  PASS: permissions.ask is empty; prompts come from hooks (tier is CI-safe)"
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
else
  # A tier that does emit asks must not pretend to gate what the hook already gates.
  for r in "Bash(solana program deploy *)" "Bash(anchor deploy *)"; do
    assert_rule ask "$r" yes "permissions.ask has $r"
  done
fi
# Deny wins over ask, so a rule in both lists never prompts.
OVERLAP="$(python3 -c "
import json
p = json.load(open('$SETTINGS'))['permissions']
print(' '.join(sorted(set(p.get('ask', [])) & set(p['deny']))) or 'none')
" 2>/dev/null)"
assert_eq "none" "$OVERLAP" "no rule sits in both permissions.ask and permissions.deny"
# A wrapper in front of a gated command (env, xargs, sh -c, an absolute path...) must not turn
# an ask or deny into a silent allow (issue #110). Run each ask/deny Bash rule's command through
# the wrappers: whenever an allow rule matches the wrapped form, an ask or deny rule must match too.
SHADOWED="$(python3 -c "
import fnmatch, json
p = json.load(open('$SETTINGS'))['permissions']
globs = lambda k: [r[5:-1] for r in p.get(k, []) if r.startswith('Bash(') and r.endswith(')')]
allow, gated = globs('allow'), globs('ask') + globs('deny')
cmds = [g.replace('*', 'X').strip() for g in gated if g.split()[0] in ('solana', 'anchor', 'spl-token')]
wraps = ['env {}', 'env FOO=1 {}', 'env -u HOME {}', 'xargs {}', 'xargs -I{{}} {}', 'sh -c \'{}\'', 'bash -c \'{}\'',
         '/usr/local/bin/{}', 'nohup {}', 'command {}', 'time {}', 'nice {}', 'timeout 60 {}']
hit = lambda c, rules: any(fnmatch.fnmatchcase(c, r) for r in rules)
bad = sorted({w.format(c) for c in cmds for w in wraps if hit(w.format(c), allow) and not hit(w.format(c), gated)})
print(' | '.join(bad) or 'none')
" 2>/dev/null)"
assert_eq "none" "$SHADOWED" "no allow rule turns a wrapped ask/deny command (env, xargs, sh -c, absolute path) into a silent allow"
for r in "Bash(env *)" "Bash(xargs *)" "Bash(command *)"; do
  assert_rule allow "$r" no "permissions.allow drops the wrapper glob $r"
done
for r in "Bash(command -v *)" "Bash(xargs grep *)"; do
  assert_rule allow "$r" yes "permissions.allow keeps the read-only form $r"
done
# `env` is not narrowed to a bare-`env` allow but denied as a whole binary (spec §2 lists it
# as a matcher-evading wrapper). That subsumes the narrowing, so re-adding Bash(env) to allow
# would be dead config: deny wins over allow.
assert_rule deny "Bash(env *)" yes "permissions.deny covers the env wrapper outright"

# Mainnet writes are a hook ask below High and a hard deny at High, so whether a deny rule
# may match /deploy's mainnet step depends on the tier in .claude/security.json. What holds
# at EVERY tier: the deny anchors to the write verb, never to the cluster string, so
# read-only commands that merely name mainnet keep working.
TIER="$(python3 -c "
import json
try: print(json.load(open('$REPO_ROOT/.claude/security.json')).get('tier', 'relaxed'))
except Exception: print('relaxed')" 2>/dev/null)"
# deny_hits <command> -> the deny rules that match it, or 'none'
deny_hits() {
  python3 -c "
import fnmatch, json, sys
deny = json.load(open('$SETTINGS'))['permissions']['deny']
cmd = sys.argv[1]
print(' '.join(r for r in deny if r.startswith('Bash(') and r.endswith(')')
               and fnmatch.fnmatchcase(cmd, r[5:-1])) or 'none')" "$1" 2>/dev/null
}
DEPLOY_MAINNET='solana program deploy target/verifiable/p.so --url mainnet-beta --use-rpc'
if [ "$TIER" = "high" ]; then
  TOTAL=$((TOTAL + 1))
  if [ "$(deny_hits "$DEPLOY_MAINNET")" != "none" ]; then
    echo "  PASS: tier high denies a mainnet deploy outright"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: tier high must deny a mainnet deploy, but no deny rule matches it"
    FAIL=$((FAIL + 1))
  fi
else
  assert_eq "none" "$(deny_hits "$DEPLOY_MAINNET")" \
    "tier $TIER: no permissions.deny rule blocks /deploy's --url mainnet-beta step (the hook asks)"
fi
# True at every tier: these two are read-only and must never be caught by a cluster-string glob.
for c in "anchor verify --provider.cluster mainnet" "solana program dump PID out.so --url mainnet-beta"; do
  assert_eq "none" "$(deny_hits "$c")" "read-only command is not denied: $c"
done
# solana-keygen new/recover default to ~/.config/solana/id.json. The sandbox blocks that
# write, but a retry outside it (or a machine without the sandbox) runs under the
# Bash(solana-keygen *) allow rule, so every --force/-f spelling has to be gated — including
# the zero-gap forms, since a mid-pattern * does not match an empty string (`solana-keygen
# new -f` escaped `Bash(solana-keygen new * -f*)`). The gate is a rule when the tier emits
# asks and the secrets hook otherwise (test_hooks.sh checks the hook side).
# gated <command> -> yes|no: covered by an ask rule, or by a deny rule
gated() {
  python3 -c "
import fnmatch, json, sys
p = json.load(open('$SETTINGS'))['permissions']
rules = (p.get('ask') or []) + (p.get('deny') or [])
cmd = sys.argv[1]
print('yes' if any(fnmatch.fnmatchcase(cmd, r[5:-1]) for r in rules
                   if r.startswith('Bash(') and r.endswith(')')) else 'no')" "$1" 2>/dev/null
}
KEYGEN_FORCE="solana-keygen new --force
solana-keygen new -f
solana-keygen new --no-bip39-passphrase -f
solana-keygen new -o target/deploy/x-keypair.json --force
solana-keygen recover --force
solana-keygen recover -f
solana-keygen recover ASK --force"
# permissions.ask is empty at every tier (firewall.sh:1125 — the --force rules were retired
# into LEGACY_RULE_IDS so Relaxed could stay CI-safe), so ASK_LEN is 0 unconditionally and
# the corpus above used to sit in an unreachable else. The if-branch printed
#   "no ask rules at this tier; solana-keygen --force is gated by the secrets hook"
# which is a claim this suite never tested AND is not true: replaying all three shipped
# PreToolUse guards against `solana-keygen new --force`, `recover -f` and the -o form
# returns exit 0 from each. Replacing the whole corpus with nonsense left the output
# byte-identical, which is what made it worth finding.
#
# What is asserted instead is the drift property that holds at any tier and encodes no
# policy: the rule surface treats every --force spelling the same way. A partial gate is
# the real bug class — `solana-keygen new -f` escaping `Bash(solana-keygen new * -f*)`
# because a mid-pattern * does not match an empty string is exactly how it shows up — and
# this goes red the moment one spelling is covered and another is not, whether the rules
# arrive in `ask` or in `deny`.
KEYGEN_VERDICTS=""
KEYGEN_FORMS=0
while IFS= read -r c; do
  [ -z "$c" ] && continue
  KEYGEN_FORMS=$((KEYGEN_FORMS + 1))
  KEYGEN_VERDICTS="$KEYGEN_VERDICTS$(gated "$c")
"
done <<< "$KEYGEN_FORCE"
assert_eq "7" "$KEYGEN_FORMS" "every --force spelling in the corpus was evaluated"
assert_eq "1" "$(printf '%s' "$KEYGEN_VERDICTS" | sort -u | awk 'NF' | wc -l | tr -d ' ')" \
  "the rule surface treats every solana-keygen --force spelling alike (all $(printf '%s' "$KEYGEN_VERDICTS" | sort -u | awk 'NF' | tr -d '\n'), $KEYGEN_FORMS forms)"
if [ "$ASK_LEN" = "0" ]; then
  # No ask rules at this tier, so the gate has to be the secrets hook — and until rule
  # set 5 it was not: this branch printed an unconditional PASS for a gate that did not
  # exist. Assert the hook actually carries it. The behaviour (every force spelling
  # denied, every -o spelling silent) is exercised in test_hooks.sh; this only checks
  # that the mechanism the message names is present, which is what makes that PASS mean
  # something when read here.
  # The detector lives wherever the secrets guard keeps its awk: inline in the .sh
  # before the shared-tokenizer refactor, in secrets-guard.awk after it. Look in both,
  # so moving the awk cannot read as removing the gate.
  if grep -qh 'c0 == "solana-keygen"' "$REPO_ROOT/.claude/hooks/secrets-guard.sh" \
       "$REPO_ROOT/.claude/hooks/secrets-guard.awk" 2>/dev/null; then
    echo "  PASS: no ask rules at this tier, and the secrets guard carries the solana-keygen --force gate"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: no ask rules at this tier and the secrets guard has no solana-keygen gate — --force is unguarded"
    FAIL=$((FAIL + 1))
  fi
  TOTAL=$((TOTAL + 1))
else
  assert_eq "no" "$(gated "solana-keygen new --no-bip39-passphrase -o target/deploy/x-keypair.json")" \
    "a new keypair at another path without --force stays prompt-free"
fi

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
# The hook bodies live in .claude/hooks/*.sh now, not inline in settings.json: three
# guards sharing one headless helper were unmaintainable as embedded one-liners. So the
# contract is asserted against the referenced scripts, and settings.json is only checked
# for referencing them.
HOOK_SCRIPTS="$(python3 -c "
import json, re
d = json.load(open('$SETTINGS'))
cmds = [h['command'] for e in d['hooks']['PreToolUse'] for h in e['hooks']]
print('\n'.join(sorted({m.group(1) for c in cmds for m in re.finditer(r'([A-Za-z0-9_./-]*\.claude/hooks/[A-Za-z0-9_-]+\.sh)', c)})))
" 2>/dev/null)"
assert_cmd_success "[ -n '$HOOK_SCRIPTS' ]" "PreToolUse hooks reference scripts under .claude/hooks/"
SECRETS_SH="$REPO_ROOT/.claude/hooks/secrets-guard.sh"
ONCHAIN_SH="$REPO_ROOT/.claude/hooks/onchain-guard.sh"
assert_cmd_success "[ -r '$SECRETS_SH' ]" "secrets guard script exists"
assert_cmd_success "[ -r '$ONCHAIN_SH' ]" "on-chain guard script exists"
assert_file_contains "$SECRETS_SH" "exit 2" "secrets guard blocks with exit 2"
# Both payload shapes: Grok Build sends camelCase toolInput and is fail-open on malformed
# output, so a guard that reads only tool_input silently permits everything there.
LIB_SH="$REPO_ROOT/.claude/hooks/lib-headless.sh"
# Parsing and decision emission are the shared helper's job -- three guards duplicating a
# JSON reader is how the two payload shapes drift apart. So assert the contract there, and
# assert each guard actually sources it.
assert_file_contains "$LIB_SH" "tool_input" "the shared helper reads the command from stdin JSON"
assert_file_contains "$LIB_SH" "toolInput" "the shared helper also reads Grok's camelCase payload"
assert_file_contains "$LIB_SH" "permissionDecision" "the shared helper emits permissionDecision"
assert_file_contains "$SECRETS_SH" "lib-headless.sh" "secrets guard sources the shared helper"
assert_file_contains "$ONCHAIN_SH" "lib-headless.sh" "on-chain guard sources the shared helper"
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
