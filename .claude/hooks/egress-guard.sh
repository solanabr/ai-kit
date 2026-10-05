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

# ---- denied domains, for MCP payloads only.
#
# For a Bash command this is already enforced one layer down, at the syscall, by
# sandbox.network.deniedDomains — the hook has nothing to add and checking here
# would only risk a false positive on a hostname that appears in prose.  A local
# MCP server runs outside that sandbox, so for an MCP payload this hook is the
# only thing between the agent and a host the tier says is blocked.
#
# Tier parity is automatic and not re-stated here: the list comes from the
# generated settings.json, which carries the base sinks from Relaxed up, the bot
# and free-compute hosts from Medium up, the PaaS wildcards at High, and nothing
# at Off (where this hook has already exited).
if [ -n "${KIT_MCP-}" ]; then
  MCP_HOST=$(printf '%s\n' "$KIT_CMD" |
    KIT_DENIED="$(kit_denied_domains)" awk '
    function host(u,   h) {
      h = u
      sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", h)   # scheme
      sub(/[\/?#].*$/, "", h)                        # path, query, fragment
      sub(/^[^@]*@/, "", h)                          # userinfo
      sub(/:[0-9]+$/, "", h)                         # port
      return tolower(h)
    }
    function denied(h,   i, p, suf) {
      for (i = 1; i <= np; i++) {
        p = PAT[i]
        if (p == "") continue
        if (p == h) return p
        if (substr(p, 1, 2) == "*.") {
          suf = substr(p, 2)                         # ".example.com"
          # The apex too, not just subdomains.  The kit always ships both forms, so
          # this changes nothing for its own list; it covers a user who added only
          # the wildcard to their own deniedDomains and meant the host as well.
          if (h == substr(suf, 2)) return p
          if (length(h) > length(suf) && substr(h, length(h) - length(suf) + 1) == suf) return p
        }
      }
      return ""
    }
    BEGIN { np = split(ENVIRON["KIT_DENIED"], PAT, "\n") }
    {
      s = $0
      while (match(s, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^[:space:]"'\''`<>]+/)) {
        u = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        h = host(u)
        if (h == "") continue
        d = denied(h)
        if (d != "") { print h " " d; exit }
      }
    }' 2>/dev/null) || MCP_HOST=
  if [ -n "$MCP_HOST" ]; then
    kit_deny "reaches ${MCP_HOST%% *}, which the $TIER firewall tier denies (matched ${MCP_HOST#* }). That host is on the kit's exfil denylist — request bins, tunnels, paste sites and file drops. A local MCP server runs outside the OS sandbox, so this hook is the only thing enforcing that list here."
  fi
fi

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

[ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/egress-guard.awk" ] || exit 0

VERDICT=$(printf '%s\n' "$KIT_CMD" |
  KIT_SECRET_RE="$(kit_secret_re)" KIT_MAXCLASS="$TIERN" \
  awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/egress-guard.awk" 2>/dev/null) || exit 0
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
