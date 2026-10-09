#!/bin/sh
# egress-guard.sh — PreToolUse(Bash): gate the commands whose effect you cannot
# get back by re-running them.  Three kinds, all of them off-machine or
# off-branch: data leaving the host, a published package version, and a
# rewritten git remote or git history.  Tier-aware; disabled at Off.
#
# Tier mapping (spec section 4):
#   Relaxed  gates only the @file / --upload-file / --post-file forms, and
#            denies outright when a secret is the thing being sent.
#   Medium   adds an ask on inline request bodies.
#   High     denies inline request bodies, and asks when an expansion rides in
#            a request with no body at all (a GET-smuggled payload).
#
# Why the git and gh gates live in this file rather than one of their own: the
# three guards registered in settings.json are the whole hook surface, and
# settings.json is effectively write-once (install.sh copies it only when it is
# absent).  A fourth script would reach fresh installs and nothing else, which
# is worse than no gate, because it looks like one.  hooks/ is copied wholesale
# by update.sh, so a branch added here reaches every install that updates.
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
  # Medium and High refuse it, and the refusal holds in a headless run: a pipeline must
  # not publish unprompted.
  if [ "$TIERN" -ge 2 ]; then
    kit_deny "$REASON At the $TIER firewall tier publishing is denied; the user publishes releases themselves."
  fi
  # Relaxed asks.  An earlier version of this hook allowed it outright, reasoning that
  # publishing is "a deliberate release step a human triggers" — but the human is not
  # the one running it here, the agent is, and the spec's tier matrix says ask.  kit_ask
  # is what makes that safe to ship at the CI tier: it goes silent when there is no
  # interactive user, so the prompt costs a headless run nothing.
  kit_ask "This command $REASON Confirm the package, the version and the registry before approving."
fi

# ---- git and gh operations that rewrite a remote, or rewrite history.
#
# Ladder: silent at Relaxed, ask at Medium, deny at High.  That is the spec's own
# matrix (force push: allow / hook-ask / deny; recoverable git: allow / allow /
# hook-ask), and it is why these are hooks and not rules.  Two reasons a glob cannot do
# this job:
#
#   * The decision varies by tier, and permissions.deny cannot — lists merge across
#     settings sources and a deny from any scope wins, with no un-deny primitive.
#   * A glob cannot express a force refspec at all.  `git push origin +main` and
#     `git push origin +refs/heads/main:refs/heads/main` force-push with no flag to
#     match, which is how they walked past every --force rule the kit used to ship.
#
# Position-anchored, like the publish pattern above: the verb has to start a statement,
# optionally behind env assignments and a path prefix.  Matching `git push` anywhere in
# the string is what makes a hook fire on a commit message that mentions it.
git_seg() { # git_seg <subcommand-alternation> -> the matching statement, or empty
  printf '%s\n' "$KIT_CMD" | grep -oE "(^|[;&|(]|\\\$\\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?($1)([[:space:]][^;&|]*)?([;&|)]|\$)" || true
}

# gate <reason> — the shared ladder.  Relaxed is silent by returning.
gate_remote() {
  [ "$TIERN" -ge 2 ] || return 0
  [ "$TIERN" -ge 3 ] && kit_deny "$1 The High firewall tier denies it; drop to Medium if this is intended."
  kit_ask "$1 Confirm the branch and the remote before approving."
}

PUSH=$(git_seg 'git[[:space:]]+push')
if [ -n "$PUSH" ]; then
  # --force / --force-with-lease / --force-if-includes, a clustered or standalone -f,
  # or a leading + on a refspec.  --force-with-lease is gated alongside the rest on
  # purpose: the lease protects against overwriting a commit that arrived while you
  # were working, not against discarding history you already knew about.
  set -f
  FORCED= DRYRUN=
  for w in $PUSH; do
    # A dry run contacts the remote and writes nothing, so it is exempt — the same
    # carve-out the publish gate above makes for `npm publish --dry-run`.
    case $w in
      -n | --dry-run) DRYRUN=1 ;;
    esac
    case $w in
      --force | --force=* | --force-with-lease* | --force-if-includes*) FORCED=1 ;;
      +*) FORCED=1 ;;                       # a force refspec: git push origin +main
      --*) ;;                               # must precede the -f test: --follow-tags
      -f | -*f | -f*) FORCED=1 ;;           # -f, -uf, -fu
    esac
  done
  set +f
  [ -n "$FORCED" ] && [ -z "$DRYRUN" ] && gate_remote "This force-pushes, which discards commits on the remote branch and cannot be undone from here."
fi

MERGE=$(git_seg 'gh[[:space:]]+pr[[:space:]]+merge')
[ -n "$MERGE" ] && gate_remote "This merges a pull request, landing the branch and closing the PR for everyone."

# ---- High only: history rewrites that ARE recoverable, from the reflog.
#
# Named one by one rather than matched broadly, so the claim in the docs is checkable.
# `git reset --hard` and its `--ha` abbreviation, `git clean`, `git restore` and
# `git branch -D`/`--delete` are absent because they are already denied at every tier;
# a bare `git reset` only unstages and is left alone.
REWRITE_WHY='This rewrites local git history. It is recoverable from the reflog, but the High firewall tier asks first.'
if [ "$TIERN" -ge 3 ]; then
  REWRITE=$(git_seg 'git[[:space:]]+(rebase|filter-branch|filter-repo)|git[[:space:]]+commit[[:space:]][^;&|]*--amend|git[[:space:]]+stash[[:space:]]+(drop|clear)')
  # `git rebase --abort|--continue|--skip|--quit|--edit-todo` finishes or undoes a
  # rebase already in progress; gating those would prompt in the middle of resolving a
  # conflict the agent was told to resolve.
  if [ -n "$REWRITE" ] && ! printf '%s\n' "$REWRITE" | grep -qE -- '--(abort|continue|skip|quit|edit-todo|show-current-patch)'; then
    kit_ask "$REWRITE_WHY"
  fi
  # Deleting a branch or a tag, scanned by word rather than by regex.  "-d as a whole
  # word" has no portable ERE spelling (BSD grep wants [[:<:]], GNU wants \b), and the
  # obvious `[^;&|]*-d` matched `git branch --sort=-date`.  `git branch -D` and
  # `--delete` are absent here because they are already denied at every tier; for a tag
  # both spellings are open, so both are listed.
  DEL=$(git_seg 'git[[:space:]]+(branch|tag)')
  if [ -n "$DEL" ]; then
    set -f
    for w in $DEL; do
      case $w in
        -d | --delete | --delete=*) set +f; kit_ask "$REWRITE_WHY" ;;
      esac
    done
    set +f
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
