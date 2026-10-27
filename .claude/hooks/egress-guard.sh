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
# And `git config` writes to the keys that make git execute a command later —
# alias.*, core.pager, core.editor, core.hooksPath, sequence.editor,
# credential.helper, diff.external — plus `git config --edit`.  Denied at every
# tier.  The pattern lives in egress-guard.awk (GITEXEC); the long rationale,
# including why a permission glob cannot express the case-insensitive key match,
# is in that file's own header.
#
# And the destructive git subcommands — clean, restore, checkout -- <path>,
# reset --hard, reflog expire/delete/drop, prune, gc --prune, push --mirror, and
# the transport overrides — when they are reached behind a git-LEVEL option,
# where every deny rule is anchored on the bare subcommand and therefore cannot
# see them.  That pass (GITDESTRUCT) mirrors the rules and changes no tier's
# policy: it fires only on the prefixed spelling, bare form included.  GITCFG
# does the same for `--config-env` behind another git-level option, and is the
# whole gate for `git -c` in any position, at every tier, Off included: it lets
# `core.fsmonitor=false` and `core.hooksPath=/dev/null` through and denies every
# other value.  Same file, same headers.
#
# And `gh api` writes (PUT/POST/PATCH, explicit or implied by -f/-F/--input) to
# the endpoints the `gh secret set` / `gh variable set` denies cover — denied at
# every active tier — and to workflow dispatches, deployments and environments,
# which ask at Relaxed and deny at Medium and High.  GHSECRET and GHACTION in
# egress-guard.awk; the rationale is above ghapi_scan there.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked, stdout JSON = ask.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
kit_parse
[ -n "$KIT_CMD" ] || exit 0

# ---- destructive-system pass: catastrophic `rm -rf` and process kills.
#
# Run BEFORE the Off early-exit, so it holds at every tier.  These are not egress,
# but they live here because egress-guard is the one guard with an Off early-exit
# to run ahead of, and because a permission rule matches an `rm` target only as
# typed (another flag spelling or a variable passes it) and the kill rules sit at
# Medium+High.  The classifier (KIT_RMKILL in egress-guard.awk) denies a
# catastrophic rm target in any spelling, `kill` of PID -1, and pkill/killall of a
# peer agent; ordinary cleanup and killing one's own workers pass.  Prefiltered so
# a command naming none of these never pays for the awk.  A $'…' word can spell
# any name in escapes (`$'\x72m'` is rm), so it reaches the awk too (#301).
case $KIT_CMD in
  *"\$'"* | *rm\ * | *rm$KIT_NL* | *kill* | *pkill* | *killall*)
    if [ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/egress-guard.awk" ]; then
      RMK=$(printf '%s\n' "$KIT_CMD" | KIT_RMKILL=1 KIT_CWD="${KIT_CWD:-$PWD}" \
        awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/egress-guard.awk" 2>/dev/null) || RMK=
      case $RMK in
        RM\ *) kit_deny "This command ${RMK#RM } — denied at every tier. Remove a specific path, not a home/root/project target or an unquoted variable that could be empty. Ordinary cleanup (./build dirs, a scratch subpath) is unaffected." ;;
        KILL\ *) kit_deny "This command ${RMK#KILL } — denied at every tier. Signal a specific PID, or a worker by name that is not a peer agent (node, vitest). If you must, the user runs it." ;;
      esac
    fi
    ;;
esac

# ---- `git -c`: GITCFG, also run before the Off early-exit.
#
# Through rule set 12 a `Bash(git -c *)` deny held this at every tier, Off included.
# Rule set 13 dropped it (#311): a deny rule beats every allow and every hook, and no
# glob can tell `-c core.fsmonitor=false`, which an auditor adds so a hostile checkout's
# fsmonitor hook cannot run, from `-c core.fsmonitor=/tmp/x.sh`, which runs a program.
# This pass took the rule's place, so it runs where the rule did.  It lets
# `core.fsmonitor=false` and `core.hooksPath=/dev/null` through and denies every other
# value, in any position; the subcommand after them is judged as it would be bare.
kit_deny_gitcfg() {
  kit_deny "$1. git -c and git --config-env are denied at every tier, because a one-shot config value can make any git command run a program. The two values that only take one away are let through: -c core.fsmonitor=false and -c core.hooksPath=/dev/null. If the user needs another value set, they run the command themselves."
}
# It fails closed, as the rule it replaced could not fail at all: with the awk files
# missing or unreadable, or awk exiting non-zero, a command naming git and a `-c` is
# refused rather than waved through.  What no hook can answer for is a session that
# turns hooks off (`disableAllHooks`); docs/firewall.md says so.
case "$KIT_CMD
$(kit_unquoted "$KIT_CMD")" in
  *git*)
    GCF= GRC=127
    if [ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/egress-guard.awk" ] \
       && [ -r "$HOOK_DIR/lib-tokenize.awk" ] && [ -r "$HOOK_DIR/egress-guard.awk" ]; then
      GCF=$(printf '%s\n' "$KIT_CMD" | KIT_GITCFG=1 \
        awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/egress-guard.awk" 2>/dev/null)
      GRC=$?
    fi
    if [ "$GRC" -ne 0 ]; then
      # Quotes and backslashes removed as well: `git "-"c …` and `git -\c …` are -c.
      case "$KIT_CMD
$(kit_unquoted "$KIT_CMD")" in
        *-c*) kit_deny "This command names git and a -c option, and the guard that decides git -c could not run (its awk files are missing or unreadable, or awk failed). git -c can make any git command run a program, so it is refused until the guard runs. Reinstall the kit's hooks (bash .claude/bin/update.sh) or run the command without -c." ;;
      esac
    fi
    case $GCF in
      GITCFG\ *) kit_deny_gitcfg "${GCF#GITCFG }" ;;
      GITEXEC\ * | GITEXECPATH\ * | GITDESTRUCT\ *)
        kit_deny "${GCF#* }. Behind a git -c prefix this is denied at every tier, Off included, as it was when every git -c was: a safe value in front does not make it a different command. If the user wants it run, they run it themselves." ;;
    esac
    ;;
esac

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

# ---- an ask waits until everything that can deny has run.  kit_ask exits, and an
# approved prompt runs the whole Bash call, so an ask from the gates below used to
# end the hook before the awk pass reached a deny later in the same command:
# `npm publish && curl -d @.env https://…` asked about the publish, and an approval
# sent the .env too.  ask_later keeps the first ask; finish asks it at the end.
# A held publish ask (ASK_GATED) is kit_gate_ask, not kit_ask: it goes silent only
# when headless is positively known, so a harness that gives no signal asks rather
# than letting the publish run unprompted on a failed terminal probe.
ASK_LATER= ASK_GATED=
ask_later() { [ -n "$ASK_LATER" ] || ASK_LATER=$1; }
finish() {
  [ -n "$ASK_LATER" ] || exit 0
  [ -n "$ASK_GATED" ] && kit_gate_ask "$ASK_LATER"
  kit_ask "$ASK_LATER"
}

# ---- the text the two position-anchored patterns below read.  The shell deletes
# a backslash-newline before it splits words, and a reserved word is never the
# command, so `git push \<newline>--force` and `if true; then npm publish; fi` are
# the force push and the publish they run.  Read raw, both walked past these
# gates at High.  kit_shell_text joins the one and drops the other, and leaves
# quoted strings and heredoc bodies alone: `git commit -m "…; then npm publish"`
# stays the prose it is.  A string another program runs as shell code — `sh -c`,
# `eval`, `watch`, `flock -c`, `env -S`, `git submodule foreach`, `git rebase
# --exec` — follows on lines of its own, so a statement starts at its head.
KIT_CMDJ=$KIT_CMD
# The words are looked for with quotes and backslashes removed as well: bash runs
# `npm pub"l"ish` as npm publish (#297).
case "$KIT_CMD
$(kit_unquoted "$KIT_CMD")" in
  # Neither pattern can match a text naming none of these, and only a
  # continuation could assemble one, so the awk pass is skipped there.  Nor can
  # a $'…' word, which spells a name in escapes (`$'\x67it'` is git, #301).
  *"\$'"* | *publish* | *git* | *gh* | *"\\$KIT_NL"*)
    if [ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/egress-guard.awk" ]; then
      KIT_CMDJ=$(printf '%s\n' "$KIT_CMD" | KIT_SHELL_TEXT=1 \
        awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/egress-guard.awk" 2>/dev/null) || KIT_CMDJ=
      [ -n "$KIT_CMDJ" ] || KIT_CMDJ=$KIT_CMD
    fi
    ;;
esac

# lacks <segments> <ERE> — some matched segment, one per line, does not match ERE.
# An exemption (--dry-run, --continue) holds for the segment carrying it and no
# other.  Read as one, a code string's own line lent its exemption to the command
# beside it, so `npm publish; sh -c 'npm publish --dry-run'` passed as a dry run.
lacks() { printf '%s\n' "$1" | grep -qvE -- "$2"; }

# ---- publish: irreversible, and the registry is always an allowed domain.
PUB='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?(npm|yarn|pnpm|bun|cargo)[[:space:]]+publish([[:space:]][^;&|]*)?([;&|)]|$)'
PSEG=$(printf '%s\n' "$KIT_CMDJ" | grep -oE "$PUB") || PSEG=
if [ -n "$PSEG" ] && lacks "$PSEG" '--dry-run'; then
  REASON='publishes this package to a public registry. A published version cannot be unpublished or replaced.'
  # Medium and High refuse it, and the refusal holds in a headless run: a pipeline must
  # not publish unprompted.
  if [ "$TIERN" -ge 2 ]; then
    kit_deny "$REASON At the $TIER firewall tier publishing is denied; the user publishes releases themselves."
  fi
  # Relaxed asks.  An earlier version of this hook allowed it outright, reasoning that
  # publishing is "a deliberate release step a human triggers" — but the human is not
  # the one running it here, the agent is, and the spec's tier matrix says ask.
  # Headless, the ask would go silent and the publish would run unprompted, so it takes
  # the irreversible set's path instead: denied unless CONFIRM_PUBLISH=1 (#307).  The
  # deny is immediate (a deny stops the whole call, so nothing later can be skipped);
  # a confirmed run returns here and still reaches the denies below, which is why this
  # is kit_confirm and not kit_gate.
  kit_confirm publish "This command $REASON"
  ASK_GATED=1
  ask_later "This command $REASON Confirm the package, the version and the registry before approving."
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
# GOPT — the git-level options that may stand between git and its subcommand:
# `git -P push --force` and `git --no-pager rebase -i` are the push and the rewrite
# they run, and read as `git[[:space:]]+push` they walked past the Medium and High
# gates.  An option and its value (-C dir, -c key=value, --git-dir dir) or one token.
GOPT='([[:space:]]+(-[cC][[:space:]]+[^[:space:];&|()]+|--(git-dir|work-tree|namespace|attr-source|super-prefix|config-env|shallow-file)[[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*|-[^[:space:];&|()]+))*'
git_seg() { # git_seg <subcommand-alternation> -> the matching statement, or empty
  printf '%s\n' "$KIT_CMDJ" | grep -oE "(^|[;&|(]|\\\$\\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?($1)([[:space:]][^;&|]*)?([;&|)]|\$)" || true
}

# gate <reason> — the shared ladder.  Relaxed is silent by returning.
gate_remote() {
  [ "$TIERN" -ge 2 ] || return 0
  [ "$TIERN" -ge 3 ] && kit_deny "$1 The High firewall tier denies it; drop to Medium if this is intended."
  ask_later "$1 Confirm the branch and the remote before approving."
}

PUSH=$(git_seg "git$GOPT[[:space:]]+push")
if [ -n "$PUSH" ]; then
  # --force / --force-with-lease / --force-if-includes, a clustered or standalone -f,
  # or a leading + on a refspec.  --force-with-lease is gated alongside the rest on
  # purpose: the lease protects against overwriting a commit that arrived while you
  # were working, not against discarding history you already knew about.
  set -f
  FORCED=
  # Segment by segment, for the reason lacks() gives.
  while IFS= read -r seg; do
    F= DRYRUN=
    for w in $seg; do
      # A dry run contacts the remote and writes nothing, so it is exempt — the same
      # carve-out the publish gate above makes for `npm publish --dry-run`.
      case $w in
        -n | --dry-run) DRYRUN=1 ;;
      esac
      case $w in
        --force | --force=* | --force-with-lease* | --force-if-includes*) F=1 ;;
        +*) F=1 ;;                          # a force refspec: git push origin +main
        --*) ;;                             # must precede the -f test: --follow-tags
        -f | -*f | -f*) F=1 ;;              # -f, -uf, -fu
      esac
    done
    [ -n "$F" ] && [ -z "$DRYRUN" ] && FORCED=1
  done <<EOF
$PUSH
EOF
  set +f
  [ -n "$FORCED" ] && gate_remote "This force-pushes, which discards commits on the remote branch and cannot be undone from here."
fi

MERGE=$(git_seg 'gh[[:space:]]+pr[[:space:]]+merge')
[ -n "$MERGE" ] && gate_remote "This merges a pull request, landing the branch and closing the PR for everyone."

# ---- High only: history rewrites that ARE recoverable, from the reflog.
#
# Named one by one rather than matched broadly, so the claim in the docs is checkable.
# `git reset --hard` and its `--ha` abbreviation, `git clean` and `git restore` are
# absent because they are already denied at every tier; `git branch -D`/`-f` left that
# set in rule set 10 and are asked for below.  A bare `git reset` only unstages and is
# left alone.
REWRITE_WHY='This rewrites local git history. It is recoverable from the reflog, but the High firewall tier asks first.'
if [ "$TIERN" -ge 3 ]; then
  REWRITE=$(git_seg "git$GOPT[[:space:]]+(rebase|filter-branch|filter-repo)|git$GOPT[[:space:]]+commit[[:space:]][^;&|]*--amend|git$GOPT[[:space:]]+stash[[:space:]]+(drop|clear)")
  # `git rebase --abort|--continue|--skip|--quit|--edit-todo` finishes or undoes a
  # rebase already in progress; gating those would prompt in the middle of resolving a
  # conflict the agent was told to resolve.
  if [ -n "$REWRITE" ] && lacks "$REWRITE" '--(abort|continue|skip|quit|edit-todo|show-current-patch)'; then
    ask_later "$REWRITE_WHY"
  fi
  # Deleting a branch or a tag, scanned by word rather than by regex.  "-d as a whole
  # word" has no portable ERE spelling (BSD grep wants [[:<:]], GNU wants \b), and the
  # obvious `[^;&|]*-d` matched `git branch --sort=-date`.  The safe delete -d and
  # --delete are asked for branch and tag alike.
  DEL=$(git_seg "git$GOPT[[:space:]]+(branch|tag)")
  if [ -n "$DEL" ]; then
    set -f
    for w in $DEL; do
      case $w in
        -d | --delete | --delete=*) ask_later "$REWRITE_WHY" ;;
      esac
    done
    set +f
  fi
  # `git branch -D`/`-f`/`--force` — the force delete and the force reset of a branch.
  # These were denied at every tier; since the firewall drops them from the every-tier
  # set (they are reflog-recoverable, FIREWALL-SPEC's recoverable-git matrix), High asks
  # instead and the lower tiers allow.  -D/-f are matched on the branch segment only, so
  # `git tag -f` (force-create a tag) is untouched; `-a`, `-m`, `--sort=-date` carry no
  # D or f and do not fire.
  BR=$(git_seg "git$GOPT[[:space:]]+branch")
  if [ -n "$BR" ]; then
    set -f
    for w in $BR; do
      case $w in
        -D | -f | --force) ask_later "$REWRITE_WHY" ;;
        --*) ;;                                       # a long option: never a short -D/-f cluster
        -[A-Za-z]*) case $w in *[Df]*) ask_later "$REWRITE_WHY" ;; esac ;;   # -Df, -fd clusters
      esac
    done
    set +f
  fi
fi

[ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/egress-guard.awk" ] || finish

VERDICT=$(printf '%s\n' "$KIT_CMD" |
  KIT_SECRET_RE="$(kit_secret_re)" KIT_MAXCLASS="$TIERN" KIT_CWD="$KIT_CWD" \
  awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/egress-guard.awk" 2>/dev/null) || finish
[ -n "$VERDICT" ] || finish

CLASS=${VERDICT%% *}
WHY=${VERDICT#* }

case $CLASS in
  KITDEEP)
    # Fail closed, like kit_size_cap: a command whose code strings nest deeper than
    # the hooks can read in time is refused rather than read in part, which would
    # miss a publish, force push or secret upload in the unread inner code.  It
    # overrides an ask held by ask_later, since a deny stops the whole call.
    kit_deny_deep
    ;;
  GITEXEC)
    # Deny at every active tier, matching the two glob rules this backs up and the
    # `git -c` gate (GITCFG) beside it.  It does not ladder like the push and
    # history gates above, because the thing being stopped is not a destructive act
    # whose blast radius a tier can scale — it is a key that makes git execute an
    # attacker-chosen command at some later, unrelated moment, in a session that may
    # not be this one.  There is no legitimate agent workflow that needs
    # core.hooksPath or an alias set on the user's behalf, so there is nothing for a
    # lower tier to buy back.  Off still disables the hook, like every other gate.
    kit_deny "$WHY. Denied at every tier: a config key naming a program git runs later is the one evasion that outlives the command that set it, so neither this hook nor any rule sees a dangerous verb when it fires. Reading config is not gated — use git config --get or --list. If the user wants the key set, they set it themselves."
    ;;
  GITDESTRUCT)
    # The command itself is already denied at every tier by a permission rule; what this
    # verdict adds is that the rule is anchored on the bare subcommand, so a git-level
    # option in front of it walked past.  Same policy, one more spelling — see gd_scan's
    # header for why it mirrors the rules instead of widening them.
    kit_deny "$WHY. That command is denied at every tier by a permission rule anchored on the bare subcommand, and a git-level option in front of it is not a different command — this hook is what makes the rule mean what it says. If the user wants it run, they run it themselves."
    ;;
  GITCFG)
    # Normally decided ahead of the Off early-exit, above; this is the same verdict
    # from pass 0, kept so the class has one meaning wherever it is printed.  See
    # gcfg_scan's header.
    kit_deny_gitcfg "$WHY"
    ;;
  GITEXECPATH)
    # The same every-tier deny as git -c: the directory git searches for its own
    # helpers decides what runs, and nothing an agent does needs it moved.
    kit_deny "$WHY. Denied at every tier, like git -c: no agent workflow needs git to look for its helpers somewhere else. A bare git --exec-path, which only prints the path, is not gated. If the user needs it, they run the command themselves."
    ;;
  GITENV)
    kit_deny "$WHY. Denied at every tier, like git -c and git --exec-path=, which it is by another name. If the user needs it set, they set it themselves."
    ;;
  GITENVASK)
    # High only: a deploy key's ssh command is ordinary work below it.
    kit_ask "This command $WHY. Confirm the program before approving."
    ;;
  GHSECRET)
    # Every active tier, headless included, because the rules this backs up —
    # `Bash(gh secret set *)` and `Bash(gh variable set *)` — deny at every tier and
    # the REST call is the same write by another spelling.  A ladder here would make
    # Relaxed's copy of those two rules decorative: the agent would use the API.
    kit_deny "This command $WHY. Both of those are denied at every tier, and the REST endpoint is the same write — a stored secret or variable is read by every later workflow run. Reading is not gated (GET, gh secret list, gh variable list). If the user wants the value set, they set it themselves."
    ;;
  GHACTION)
    # Medium and High already deny the bare command with `Bash(gh api *)`; a
    # wrapper in front of it (`command gh api`, `sh -c`, `timeout 5`) is not a
    # different command, so the hook gives it the rule's answer.  Relaxed has no
    # such rule and `gh workflow run` itself is open there, so a deny would be
    # stricter than the subcommand: it asks instead, which kit_ask makes silent in
    # a headless run — the publish gate's shape, and CI-safe for the same reason.
    if [ "$TIERN" -ge 2 ]; then
      kit_deny "This command $WHY. The $TIER firewall tier denies gh api outright, and a wrapper in front of it is not a different command. Drop to Relaxed if this is intended."
    fi
    kit_ask "This command $WHY. It starts a run or a deploy, or changes the rules that gate one — confirm the repository, the workflow or environment and the ref before approving."
    ;;
  DENY)
    # Not "at any tier": Off returns before the classifier runs (TIER check above).
    kit_deny "$WHY. Sending credentials or key material off the machine is denied at every tier except Off, which turns this guard off. If the user needs this uploaded, they do it themselves."
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
finish
