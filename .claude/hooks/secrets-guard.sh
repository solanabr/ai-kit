#!/bin/sh
# secrets-guard.sh — PreToolUse(Bash): block reads of credential stores, key
# material and wallet vaults.  Active at every tier, including Off, because the
# never-allowed set does not vary by tier.
#
# The invariant, and the whole reason this file replaced an inline grep:
#
#   a rule may match only a path in ARGUMENT POSITION of a command that would
#   touch that path — never the command's prose.
#
# Writing documentation, a commit message, an issue body or a test corpus that
# names a protected path is not access to it and must never be blocked.  The
# inline predecessor grepped the whole command string and produced five
# independent false positives in one session (a diagnostic `ls -l` on a wallet,
# a `gh issue create` body, the firewall spec itself, two test corpora), to the
# point where two shipped commands documented workarounds.
#
# Decisions come from an awk pass that quote-aware splits the command into
# statements and pipeline stages, strips heredoc bodies, finds each stage's real
# command word past env assignments and wrappers, and only then looks at that
# command's arguments.  The splitter now lives in lib-tokenize.awk, shared with
# the other guards (issue #138); the decision logic is secrets-guard.awk.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
kit_parse
[ -n "$KIT_CMD" ] || exit 0

[ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/secrets-guard.awk" ] || exit 0

# The regex travels in the environment, not through -v: awk processes escape
# sequences in -v assignments, which mangles \. and \( differently per awk.
VERDICT=$(printf '%s\n' "$KIT_CMD" | KIT_VAULT_RE="$(kit_vault_re)" KIT_LANG="${KIT_LANG-}" \
  awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/secrets-guard.awk" 2>/dev/null) || exit 0

case $VERDICT in
  WIPE*)
    # Destroying key material, not reading it, so the "use solana address instead"
    # trailer would be nonsense here. The route around is the flag, not the command.
    kit_deny "${VERDICT#WIPE } overwrites the default wallet keypair at ~/.config/solana/id.json, and a Solana keypair cannot be recovered without its seed phrase. Drop --force to keep the existing wallet (solana-keygen refuses to overwrite one without it, so the command works unchanged where no wallet exists yet), or pass -o <path> to write somewhere else. If the user really means to replace their default wallet, they run it themselves."
    ;;
  DENY*)
    kit_deny "${VERDICT#DENY } — reading private keys, wallet vaults or credentials is not allowed. Use \`solana address\` for the pubkey; ask the user to run anything that needs the secret."
    ;;
esac
exit 0
