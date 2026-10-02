#!/bin/sh
# egress-guard.sh — PreToolUse(Bash): gate commands that carry data off the
# machine.  Tier-aware; disabled at Off.
#
# Tier mapping (spec section 4):
#   Relaxed  gates only the @file / --upload-file / --post-file forms, and
#            denies outright when a secret is the thing being sent.
#   Medium   adds an ask on inline request bodies.
#   High     denies inline request bodies, and asks when an expansion rides in
#            a request with no body at all (a GET-smuggled payload).
#
# Deliberately NOT gated at Relaxed: `curl -X POST -d '{"jsonrpc":...}'
# https://api.devnet.solana.com`.  That is the most common curl in Solana work;
# prompting on it would prompt constantly and would break this repo's own
# shipped claude.yml Action.
#
# Denied at every active tier:
#   - a secret path as a request body or upload
#   - a secret path as an argument to any network command (scp, rsync, gh, dig…)
#   - a reader piping a secret into a network sink in the same statement
#   - a secret path named in inline python -c / node -e code
# .env.example and other template suffixes are not secrets: this repo ships one.
#
# Also gates npm / cargo / yarn / pnpm / bun publish, which is the one egress
# path whose destination is legitimately allowlisted and therefore cannot be
# stopped by a domain layer.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked, stdout JSON = ask.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
kit_parse
[ -n "$KIT_CMD" ] || exit 0

TIER=$(kit_tier)
[ "$TIER" = "off" ] && exit 0
TIERN=$(kit_tier_num "$TIER")

# ---- publish: irreversible, and the registry is always an allowed domain.
PUB='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?(npm|yarn|pnpm|bun|cargo)[[:space:]]+publish([[:space:]][^;&|]*)?([;&|)]|$)'
PSEG=$(printf '%s\n' "$KIT_CMD" | grep -oE "$PUB") || PSEG=
if [ -n "$PSEG" ] && ! printf '%s\n' "$PSEG" | grep -q -- '--dry-run'; then
  REASON='publishes this package to a public registry. A published version cannot be unpublished or replaced.'
  # Relaxed excludes the obvious footguns, not a deliberate release step a human
  # triggers, so publishing is simply allowed there. Medium and High refuse it, and
  # the refusal holds in a headless run: a pipeline must not publish unprompted.
  if [ "$TIERN" -ge 2 ]; then
    kit_deny "$REASON At the $TIER firewall tier publishing is denied; the user publishes releases themselves."
  fi
fi

[ -f "$HOOK_DIR/egress-guard.awk" ] || exit 0

VERDICT=$(printf '%s\n' "$KIT_CMD" |
  KIT_SECRET_RE="$(kit_secret_re)" KIT_MAXCLASS="$TIERN" \
  awk -f "$HOOK_DIR/egress-guard.awk" 2>/dev/null) || exit 0
[ -n "$VERDICT" ] || exit 0

CLASS=${VERDICT%% *}
WHY=${VERDICT#* }

case $CLASS in
  DENY)
    kit_deny "$WHY. Sending credentials or key material off the machine is not allowed at any tier. If the user needs this uploaded, they do it themselves."
    ;;
  ASK1)
    kit_ask "This command $WHY. Confirm the destination and the contents before approving."
    ;;
  ASK2)
    if [ "$TIERN" -ge 3 ]; then
      kit_deny "the command $WHY, which the High firewall tier denies. Drop to Medium if this request is intended."
    fi
    kit_ask "This command $WHY. Confirm the destination and the contents before approving."
    ;;
  ASK3)
    kit_ask "This request carries no body, but $WHY. Check what the expansion contains before approving."
    ;;
esac
exit 0
