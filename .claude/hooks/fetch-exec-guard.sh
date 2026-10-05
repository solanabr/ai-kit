#!/bin/sh
# fetch-exec-guard.sh — PreToolUse(Bash): gate "download a package from the
# internet and execute it" when that package is not already a project
# dependency.  Tier-aware; disabled at Off.
#
#   npx -y create-solana-dapp        downloads a stranger and runs it
#   npx tsc --noEmit                 runs the typescript this project installed
#
# Both are `Bash(npx *)`, which is in permissions.allow.  A permission rule
# cannot tell them apart: it sees a glob, not a package.json, and it cannot vary
# by tier.  Worse, `deny Bash(npx *)` would be close to decorative — `npm exec`,
# `npm x`, `pnpm dlx`, `yarn dlx`, `bunx`, `bun x`, `uvx` and
# `/opt/homebrew/bin/npx` are all different command words.  A hook sees the whole
# command, reads the manifests, and decides per tier.
#
# Tier mapping:
#   Off      silent.
#   Relaxed  reports and passes.  Nothing is blocked; the note is there so the
#            fetch is visible in the transcript rather than invisible.
#   Medium   UNDECIDED — currently the same as Relaxed.  See the branch below.
#   High     denied (exit 2).
#
# This is also the only implementation route for the standing decision to gate
# `cargo install` at High: `Bash(cargo install *)` sits in permissions.allow at
# every tier, and a `deny` rule cannot vary by tier.  It does not need to leave
# that allow list, because a PreToolUse hook decides BEFORE the permission layer
# and over it — the same mechanism by which this kit already denies
# `npm publish` at Medium while `Bash(npm *)` is allowed.
#
# stdin: PreToolUse JSON.  Exit 0 = silent or a note, exit 2 = blocked.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
# Cheap pre-filter, before kit_parse spawns jq (~25 ms) on every Bash call.  A
# superset of the runner spellings below; correctness comes from the awk.
#
# The three narrowed branches are two INDEPENDENT substring tests rather than one
# adjacency test, so `cargo  install` and `go<tab>run` still match — a pre-filter
# that cared about the whitespace between the two words would turn a formatting
# quirk into a silent miss.  They buy a lot: `cargo build/test/clippy/fmt`,
# `go build`, `go test` and `git status` all leave here without paying for jq,
# a tier read or an awk pass — measured at ~10 ms of marginal cost against a
# no-op hook, where a call that reaches the detector costs ~26 ms and one that
# gates ~55 ms.
#
# The broad branch comes first on purpose.  Ordered the other way, a command
# naming two ecosystems (`npm exec -y cargo-foo`) would be judged by the cargo
# test alone, find no "install", and bail — a miss.
case $KIT_INPUT in
  *npx* | *dlx* | *bunx* | *uvx* | *pipx* | *npm* | *bun* | *yarn* | *pnpm*) ;;
  *cargo*) case $KIT_INPUT in *install*) ;; *) exit 0 ;; esac ;;
  *uv*) case $KIT_INPUT in *run* | *tool*) ;; *) exit 0 ;; esac ;;
  *go*) case $KIT_INPUT in *install* | *run*) ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac

kit_parse
[ -n "$KIT_CMD" ] || exit 0

[ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/fetch-exec-guard.awk" ] || exit 0

VERDICT=$(printf '%s\n' "$KIT_CMD" |
  KIT_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${KIT_CWD:-.}}" \
  awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/fetch-exec-guard.awk" 2>/dev/null) || exit 0
[ -n "$VERDICT" ] || exit 0

# The tier is read only once there is something to decide, which keeps a whole
# process off every call that passed the detector — `npx tsc` in a project that
# installed typescript is the common case, and it never needs to know the tier.
TIER=$(kit_tier)
[ "$TIER" = "off" ] && exit 0

# GATE|<ecosystem>|<runner>|<package>
case $VERDICT in GATE\|*) ;; *) exit 0 ;; esac
_r=${VERDICT#GATE|}
ECO=${_r%%|*}
_r=${_r#*|}
RUNNER=${_r%%|*}
PKG=${_r#*|}

case $ECO in
  node) MANIFEST="package.json dependencies or node_modules/.bin" ;;
  python) MANIFEST="pyproject.toml, requirements.txt or uv.lock" ;;
  rust) MANIFEST="Cargo.toml or Cargo.lock" ;;
  go) MANIFEST="go.mod" ;;
  *) MANIFEST="dependency manifest" ;;
esac

REASON="\`$RUNNER\` downloads $PKG from the internet and executes it, and $PKG is not in this project's $MANIFEST. Code that is not a declared dependency is not pinned, not in a lockfile and not reviewed. If it is wanted, add it as a dependency first, or have the user run it."

# kit_note — report without deciding.  stdout at exit 0 is transcript output,
# never a decision (a decision has to be the JSON kit_ask/kit_deny emit), so
# this cannot block and cannot hard-fail a headless run.  It deliberately is
# NOT kit_ask: `permissions.ask` is empty at every tier, so a hook ask is the
# only ask that can fire, and an ask is a hard failure under `claude -p`.
kit_note() {
  printf 'solana-ai-kit firewall (%s tier, not blocked): %s\n' "$TIER" "$(_kit_reason "$1")"
  exit 0
}

case $TIER in
  relaxed)
    # Relaxed is the CI-safe default and emits no asks. Reporting keeps the
    # fetch visible without changing what runs.
    kit_note "$REASON"
    ;;
  medium)
    # ╔═══════════════════════════════════════════════════════════════════════╗
    # ║ MEDIUM IS UNDECIDED.  This is the one place to fill in.               ║
    # ╚═══════════════════════════════════════════════════════════════════════╝
    # The open question is whether `permissionDecision: "ask"` actually prompts
    # in default (non-bypass) mode — docs/firewall.md records that an ask has
    # been observed NOT to prompt for a permission rule, and no interactive test
    # of a hook ask has been run. Until someone runs that test, Medium behaves
    # exactly as Relaxed: it reports and passes.
    #
    # That is the deliberate placeholder, not an accident, for two reasons.
    # Medium's advertised contract is "Relaxed plus" a specific enumerated list,
    # and this guard is not on that list yet — under-promising keeps README,
    # security.json and docs/firewall.md honest. And deny here would silently
    # collapse Medium into High, erasing the tier distinction the maintainer
    # still wants to choose.
    #
    # To make Medium ask once that test is done, replace this line with:
    #   kit_ask "$REASON"
    # kit_ask already goes silent when there is no interactive user, so Medium
    # stays CI-safe either way.
    kit_note "$REASON"
    ;;
  high)
    kit_deny "$REASON At the High firewall tier fetching and running an undeclared package is denied; drop to Medium or run it yourself."
    ;;
esac
exit 0
